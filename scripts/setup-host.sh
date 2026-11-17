#!/bin/sh
# 宿主侧: 为容器重建网络通道 (幂等, 可反复执行)
# 用法: sh setup-host.sh [容器名, 默认 openwrt]
#
# 通道一: veth 控制通道  <VETH_HOST>/30 <-- veth --> <VETH_CONT>/30
#         容器是 --network none, 这是它访问宿主服务的唯一路径
# 通道二: 管理口 macvlan  在 LMT 父口上再挂一个 macvlan 直接送进容器
#         -> 容器多一个管理网口, 宿主管理 IP 不受影响
# 通道三: 面板业务口      移入容器（WAN + LAN）
# 通道四: 宿主到 LAN 网段的回程路由
#
# 环境变量见 configs/v9200.env.example

set -e
NAME=${CONTAINER:-openwrt}
WAN_IF=${WAN_IF:-eth16.16}
WAN_PARENT=${WAN_IF%%.*}          # eth16.16 -> eth16
WAN_VID=${WAN_IF#*.}              # eth16.16 -> 16
LAN_IF_1=${LAN_IF_1:-eth18}
LAN_IF_2=${LAN_IF_2:-eth19}
VETH_HOST=${VETH_HOST:-192.168.99.1}
VETH_CONT=${VETH_CONT:-192.168.99.2}
LMT_PARENT=${LMT_PARENT:-eth1}
LMT_MAC=${LMT_MAC:-40:00:c0:fe:01:11}
LAN_CIDR=${LAN_CIDR:-192.168.10.0/24}
FAIL=0

PID=$(docker inspect -f '{{.State.Pid}}' "$NAME" 2>/dev/null || echo 0)
if [ "$PID" = "0" ] || [ -z "$PID" ]; then
    echo "错误: 容器 $NAME 未运行" >&2
    exit 1
fi

# ---- 通道零: VLAN 子接口必须在宿主建（容器内 BusyBox ip 不支持）----
if ip link show "$WAN_IF" >/dev/null 2>&1; then
    echo "$WAN_IF 已存在"
else
    ip link add link "$WAN_PARENT" name "$WAN_IF" type vlan id "$WAN_VID"
    echo "$WAN_IF 已创建 (父口 $WAN_PARENT, vid $WAN_VID)"
fi
ip link set "$WAN_IF" up

# ---- 通道一: veth (幂等) ----
if ip link show veth-ow >/dev/null 2>&1 && \
   docker exec "$NAME" ip link show veth-ow-c >/dev/null 2>&1; then
    echo "veth 已存在, 跳过"
else
    ip link del veth-ow 2>/dev/null || true
    ip link add veth-ow type veth peer name veth-ow-c
    ip link set veth-ow-c netns "$PID"
    ip addr add "$VETH_HOST/30" dev veth-ow 2>/dev/null || true
    ip link set veth-ow up
    if docker exec "$NAME" sh -c "
        ip link set veth-ow-c up
        ip addr add $VETH_CONT/30 dev veth-ow-c 2>/dev/null || true
    "; then
        echo "veth 就绪: 宿主 $VETH_HOST <-> 容器 $VETH_CONT"
    else
        echo "错误: veth 容器侧配置失败 (容器未就绪?)" >&2
        FAIL=1
    fi
fi

# ---- 通道二: 管理口 macvlan ----
# 容器重启后旧 netns 销毁, mv-ow 一并消失, 这里重建.
# MAC 固定, 避免每次重建后上游 ARP/交换机表变化.
if docker exec "$NAME" ip link show mv-ow >/dev/null 2>&1; then
    # 容器重启后接口会保留但状态可能回落为 DOWN
    docker exec "$NAME" ip link set mv-ow up 2>/dev/null || true
    echo "mv-ow 已存在"
else
    ip link add mv-ow link "$LMT_PARENT" address "$LMT_MAC" type macvlan mode bridge
    ip link set mv-ow netns "$PID"
    docker exec "$NAME" ip link set mv-ow up
    echo "mv-ow 就绪: $LMT_PARENT -> 容器 (MAC $LMT_MAC)"
fi

# ---- 通道三: 面板业务口 ----
# 容器重启/netns 销毁后内核会把物理口退回宿主 netns, 这里重新移入.
for IF in "$LAN_IF_1" "$LAN_IF_2"; do
    if ip link show "$IF" >/dev/null 2>&1; then
        if ip link set "$IF" netns "$PID" 2>/dev/null; then
            echo "$IF 已移入容器"
        else
            echo "警告: $IF 迁移失败" >&2
            FAIL=1
            continue
        fi
    fi
    if docker exec "$NAME" ip link show "$IF" >/dev/null 2>&1; then
        docker exec "$NAME" ip link set "$IF" up 2>/dev/null || true
    else
        echo "警告: 容器内不存在 $IF" >&2
        FAIL=1
    fi
done

# ---- WAN 口 sysctl(方案 A'): 容器内 /proc/sys 只读, 必须由宿主 nsenter 写
nsenter --net=/proc/$PID/ns/net sh -c "
  echo 1 > /proc/sys/net/ipv4/conf/all/arp_ignore
  echo 1 > /proc/sys/net/ipv4/conf/$WAN_IF/arp_ignore
  echo 1 > /proc/sys/net/ipv4/conf/$WAN_IF/rp_filter
  echo 0 > /proc/sys/net/ipv4/conf/$WAN_IF/proxy_arp
  echo 0 > /proc/sys/net/ipv4/conf/$WAN_IF/send_redirects
" 2>/dev/null || true

# ---- 通道四: 宿主到 LAN 网段的回程路由 ----
# LAN 客户端用 LAN_CIDR; 宿主回包默认无此路由,
# 会导致切 DHCP 后 SSH 失联. 经管理口发出, ARP 由容器 proxy_arp 代答.
ip route add "$LAN_CIDR" dev eth0 2>/dev/null || true

exit $FAIL
