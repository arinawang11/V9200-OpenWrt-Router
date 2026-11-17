# 故障排查

## 判定矩阵

先定位在哪一层出问题，别瞎试。

```sh
# 层 1: WAN 口有没有地址
docker exec openwrt ip addr show eth16.16
# 无 inet → 步骤 1/3 没做或失败

# 层 2: 地址是不是 /32
# 不是 /32 → rp_filter 会放行，内核回 RST

# 层 3: 路由对不对
docker exec openwrt ip route
# 期望有: default dev tun0
# 若出现: <WAN>/24 dev eth16.16 → 致命，改 /32

# 层 4: natd 活着没
docker exec openwrt cat /data/logs/nat.pid
docker exec openwrt kill -0 $(cat /data/logs/nat.pid) && echo alive
```

## 症状 → 原因

### LAN 能通几分钟，然后全部超时

**原因**：WAN 用了 `/24`。

`/24` 生成 connected 路由 → `rp_filter` 对网关放行 → 内核收到回流包回 RST。

```sh
# 确认
docker exec openwrt ip route | grep eth16
# 若看到 "<WAN>/24 dev eth16.16 proto kernel scope link" → 就是这个

# 修
docker exec openwrt ip addr del "$WAN_IP/24" dev eth16.16
docker exec openwrt ip addr add "$WAN_IP/32" dev eth16.16
nsenter --net=/proc/$(docker inspect -f '{{.State.Pid}}' openwrt)/ns/net \
    sh -c "echo 1 > /proc/sys/net/ipv4/conf/eth16.16/rp_filter"
```

### `nslookup` 完全没响应，但 `ip a` 显示有地址

**原因**：natd 缺 `--static-ip`，走 DHCP 模式拿不到地址 → `wan_ip==0` → 所有 LAN 方向包被丢弃。

```sh
# 确认
ps aux | grep natd
# 若命令行没有 --static-ip → 就是这个

# 看日志
tail -20 $DATA/logs/nat.log
# 找 "wan_ip=0"
```

### 入向完全不通，出向正常

**原因**：没发 GARP。上游网关 ARP 缓存指向旧设备。

```sh
arping -U -c 3 -I eth16.16 -s "$WAN_IP" "$WAN_GW"

# 确认上游能回
tcpdump -i eth16.16 arp
```

### 出向 `TX_BCST=0`，但 `nat.log` 有 `lan_tx` 增长

**原因**：natd 从 `eth16` 而不是 `eth16.16` 发。裸帧被 CPU 口 `pvid=100` 归入 VLAN 100，端口 50 不接收。

```sh
# 确认
ethtool -S eth16 | grep -E 'tx_(bcst|mcst|ucst)'
# 全 0 → 确认

# 修
# natd 启动参数 --wan 必须是 eth16.16
```

### `容器内无 eth16.16`

```sh
# 宿主侧确认
ip link show eth16.16
# 不存在 → 宿主编
ip link add link eth16 name eth16.16 type vlan id 16
ip link set eth16.16 up

# 存在但容器内没有 → 没移入
ip link set eth16.16 netns $(docker inspect -f '{{.State.Pid}}' openwrt)
```

### 容器重启后全部失效

正常现象。netns 销毁，物理口退回宿主。跑一次：

```sh
sh setup-host.sh && sh nat-up.sh
```

或者让 watchdog 跑着。

### SSH 到 LAN 客户端失联

**原因**：宿主机没有到 LAN 网段的回程路由。

```sh
ip route add <LAN_CIDR> dev eth0
```

### `iptables` 报 `No chain/target/match by that name`

不是故障。内核没编译 netfilter，这是预期的。所有 NAT 走 natd。

### `ip link add type vlan` 报错

在容器内执行了。容器内是 BusyBox `ip`，不支持。到宿主执行。

## 抓包位置

| 想看什么 | 抓哪 |
|---|---|
| LAN 客户端发包了没 | `br-lan` |
| 内核转发做了没 | `tun0` |
| natd 收到没 | `tun0` |
| 发出去了没 | `eth16.16` |
| 上游回了没 | `eth16.16` |

```sh
# 逐层对照
tcpdump -i tun0 -n icmp &
tcpdump -i eth16.16 -n icmp &
# 然后 ping
```

## 日志

```sh
tail -f $DATA/logs/nat.log          # NAT 主循环
tail -f $DATA/logs/watchdog.log     # 守护动作
tail -f $DATA/logs/dnsmasq.log      # DHCP/DNS
```

## 应急回滚

```sh
kill $(cat $DATA/logs/nat.pid) 2>/dev/null
docker exec openwrt ip addr del "$WAN_IP/32" dev eth16.16 2>/dev/null
ip link del eth16.16 2>/dev/null
```

然后让原设备接管。
