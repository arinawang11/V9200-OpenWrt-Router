#!/bin/sh
# nat-up.sh —— 启动用户态 NAT（内核缺少 CONFIG_NETFILTER 时的替代方案）
#
# 结构: LAN 客户端 -> br-lan -> 内核转发 -> tun0 -> NAT 进程 -> eth16.16(AF_PACKET) -> 上游
#
# 实现选择:
#   natd  C 版静态二进制，8.3M pkt/s
#   py    Python 版 nat.py，39k pkt/s（回退用）
#   覆盖: NAT_IMPL=py nat-up.sh
#
# 幂等: 已在运行直接返回；WAN 口不存在时由 watchdog 重试。
#
# 环境变量见 configs/v9200.env.example

DATA=${DATA:-/var/lib/docker/volumes/openwrt-data/_data}
LOG=${NAT_LOG:-$DATA/logs/nat.log}
PIDF=${NAT_PID:-$DATA/logs/nat.pid}
WAN_IF=${WAN_IF:-eth16.16}
TUN_IF=${TUN_IF:-tun0}
MTU=${NAT_MTU:-1500}
NAT_IMPL=${NAT_IMPL:-natd}
CONTAINER=${CONTAINER:-openwrt}

# 必填
if [ -z "$WAN_IP" ]; then
    echo "错误: 未设置 WAN_IP（见 configs/v9200.env.example）" >&2
    exit 1
fi
if [ -z "$WAN_GW" ]; then
    echo "错误: 未设置 WAN_GW" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null

CPID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null)
if [ -z "$CPID" ] || [ "$CPID" = "0" ]; then
    echo "容器 $CONTAINER 未运行"
    exit 1
fi

NS="nsenter --net=/proc/$CPID/ns/net --"

# ---- WAN 三层 (方案 A'): 必须放在幂等早退之前, 保证 natd 存活时每 15s 仍会重放 ----
if $NS ip link show "$WAN_IF" >/dev/null 2>&1; then
    # /32 而不是 /24: /24 会生成 <WAN>/24 dev eth16.16 的 connected 路由,
    # 使 rp_filter 对同网段源(网关)失效, 内核就会对 NAT 回流包回 RST.
    $NS ip addr replace "$WAN_IP/32" dev "$WAN_IF" 2>/dev/null || true
    # AF_PACKET 是旁路复制, 在 ip_rcv 之前; 内核那份在这里被丢掉.
    $NS sh -c "echo 1 > /proc/sys/net/ipv4/conf/$WAN_IF/rp_filter" 2>/dev/null || true
    # 本机 arp_ignore 默认 2, 且内核取 max(all, iface); /32 下必须降到 1 才会回 ARP.
    $NS sh -c "echo 1 > /proc/sys/net/ipv4/conf/all/arp_ignore" 2>/dev/null || true
    $NS sh -c "echo 1 > /proc/sys/net/ipv4/conf/$WAN_IF/arp_ignore" 2>/dev/null || true
    # eth16.16 继承 default.proxy_arp=1; WAN 口必须关掉, 否则会替 tun0 可达的
    # 任意地址代答 ARP, 把上游流量吸进来.
    $NS sh -c "echo 0 > /proc/sys/net/ipv4/conf/$WAN_IF/proxy_arp" 2>/dev/null || true
    $NS sh -c "echo 0 > /proc/sys/net/ipv4/conf/$WAN_IF/send_redirects" 2>/dev/null || true
fi

# ---- 幂等: 进程存活且 tun0 仍在当前容器的 netns 里
if [ -f "$PIDF" ]; then
    OP=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$OP" ] && kill -0 "$OP" 2>/dev/null; then
        if $NS ip link show "$TUN_IF" >/dev/null 2>&1; then
            exit 0
        fi
        # 容器已重建, 旧进程的 netns 已失效
        kill "$OP" 2>/dev/null
        sleep 0.5
    fi
fi

# ---- WAN 口存在性
if ! $NS ip link show "$WAN_IF" >/dev/null 2>&1; then
    echo "容器内无 $WAN_IF（宿主是否已创建 VLAN 子接口？见 docs/deployment.md）"
    exit 1
fi

# ---- WAN 口 MAC 归一
# 芯片默认 MAC 可能属无效 OUI，上游会当无效帧丢弃；
# natd 启动时经 SIOCGIFHWADDR 取此值作出向源地址，必须在拉起前设好。
# 放在这里而非 startup.sh，是因为 watchdog 的 nat-up.sh 巡检可能先于 startup.sh。
$NS ip link set "$WAN_IF" address "${WAN_MAC:-02:00:00:00:21:10}" 2>/dev/null || true

start_natd() {
    nohup $NS "$DATA/bin/natd" --wan "$WAN_IF" --lan "$TUN_IF" --mtu "$MTU" \
        --static-ip "$WAN_IP" --static-gw "$WAN_GW" \
        >>"$LOG" 2>&1 &
    echo $! >"$PIDF"
}

start_py() {
    nohup $NS /usr/bin/python2 "$DATA/bin/nat.py" --wan "$WAN_IF" --lan "$TUN_IF" --mtu "$MTU" \
        --static-ip "$WAN_IP" --static-gw "$WAN_GW" \
        >>"$LOG" 2>&1 &
    echo $! >"$PIDF"
}

if [ "$NAT_IMPL" = "natd" ] && [ -x "$DATA/bin/natd" ]; then
    start_natd
    sleep 2
    P=$(cat "$PIDF" 2>/dev/null)
    if [ -z "$P" ] || ! kill -0 "$P" 2>/dev/null; then
        echo "natd 启动失败 (见 $LOG), 回退 Python 版"
        rm -f "$PIDF"
        start_py
    fi
else
    start_py
fi

# ---- 等 tun0 出现
i=0
while [ $i -lt 20 ]; do
    $NS ip link show "$TUN_IF" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 0.5
done

if ! $NS ip link show "$TUN_IF" >/dev/null 2>&1; then
    echo "tun0 创建失败, 见 $LOG"
    exit 1
fi

# ---- 配置 tun0（内核只做转发，NAT 在用户态）
$NS ip link set "$TUN_IF" up 2>/dev/null
$NS ip link set "$TUN_IF" mtu "$MTU" 2>/dev/null
$NS ip addr add 169.254.255.1/30 dev "$TUN_IF" 2>/dev/null
$NS ip route replace default dev "$TUN_IF" 2>/dev/null

echo "NAT 已启动 impl=$NAT_IMPL pid=$(cat "$PIDF") wan=$WAN_IF tun=$TUN_IF mtu=$MTU"
