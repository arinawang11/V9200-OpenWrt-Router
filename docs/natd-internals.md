# natd 逆向分析

用户态 NAT 进程 `natd` 是这套方案的核心。本文记录从反汇编与实测中得出的关键结论。

## 1. 为什么需要用户态 NAT

```
# 你的内核配置
$ zcat /proc/config.gz | grep NETFILTER
# CONFIG_NETFILTER is not set
```

没有 `CONFIG_NETFILTER` 意味着：

- 没有 iptables / nftables
- 没有 `nf_conntrack`（无连接跟踪）
- 没有 `MASQUERADE` / `DNAT` / `SNAT`
- `ip_forward=1` 只能做**裸转发**，不能改地址

所以 NAT 必须在用户态做。内核路径只负责 LAN → tun0 的转发。

## 2. 数据流

```
LAN 包 → br-lan → 内核 ip_forward → tun0
                                      │
                                      ▼
                            natd 从 tun0 读 (AF_PACKET)
                                      │  改写源 IP/端口 + 校验和
                                      ▼
                            eth16.16 发出 (AF_PACKET 注入)
                                      │
                                 上游网关
                                      │
                                      ▼
                            eth16.16 收 (AF_PACKET 旁路复制)
                                      │  反查连接表, 还原目的地址
                                      ▼
                            tun0 注入 → 内核投递 → LAN
```

要点：**两个方向都是 AF_PACKET**。入向包在 `ip_rcv` 之前被旁路复制一份，内核那份丢弃。

## 3. `/32` vs `/24` —— 最关键的一条

### 现象

配置 `/24` 时，LAN 能正常上网几分钟，然后**所有长连接被 RST**。DNS 查询间歇性失败。

### 根因

`ip addr add 203.0.113.10/24` 会让内核生成：

```
203.0.113.0/24 dev eth16.16 proto kernel scope link src 203.0.113.10
```

这条 connected 路由意味着**网关 `203.0.113.1` 是"直连可达"的**。于是：

1. natd 从 eth16.16 收到上游回来的包，源地址是 `203.0.113.1`
2. natd 改写后注入 tun0，内核投递到 LAN 客户端
3. 但内核同时也在处理 eth16.16 上的这份包（AF_PACKET 是旁路，内核那份没被拦掉）
4. 内核的 `rp_filter` 检查：源 `203.0.113.1` 在 `203.0.113.0/24` 内且该网段直连 → **通过**
5. 内核发现本地没有对应 socket → **回 RST**

### 修法

```sh
ip addr add 203.0.113.10/32 dev eth16.16     # 不生成 connected 路由
echo 1 > /proc/sys/net/ipv4/conf/eth16.16/rp_filter
echo 1 > /proc/sys/net/ipv4/conf/all/arp_ignore
echo 1 > /proc/sys/net/ipv4/conf/eth16.16/arp_ignore
echo 0 > /proc/sys/net/ipv4/conf/eth16.16/proxy_arp
```

`/32` 下没有 connected 路由，入向包全部落到 `default dev tun0`，`rp_filter=1` 在本地投递前丢弃内核那份。AF_PACKET 已经拿到副本，不影响 natd。

### arp_ignore 为什么要降到 1

内核默认 `arp_ignore=2`（只回源地址落在**同一网段**的 ARP 请求）。`/32` 下地址不属于任何网段，内核不回 ARP。降到 `1`（只要目的地址是本机任一接口地址就回）才正常。

## 4. 出向为什么必须用 VLAN 子接口

CPU 口 800 的成员表是 `[15:tag][16:tag][100:untag]`，`pvid=100`。

- natd 从 `eth16` 发**裸帧** → 被 CPU 口按 `pvid=100` 归入 **VLAN 100**
- 但面板口 50 只属于 **VLAN 16**
- 结果：端口 50 的 `MIB TX_BCST` 恒为 0，**出向完全不通**

建 `eth16.16`（802.1Q id 16）后，帧带 tag 发出，端口 50 是 untag 成员会在出口剥离 → 通了。

判定方法：

```sh
# 接上上游后
ethtool -S eth16 | grep tx        # 硬件计数是否增长
# 若硬件计数涨但 nat.log 的 wan_rx 不涨 → 带 tag
```

## 5. `--static-ip` 缺失导致全哑

natd 启动参数：

```sh
natd --wan eth16.16 --lan tun0 --mtu 1500 \
     --static-ip 203.0.113.10 --static-gw 203.0.113.1
```

**必须带 `--static-ip`**。不带的话 natd 走 DHCP 客户端模式，永远拿不到地址，主循环里 `wan_ip==0`，把所有 LAN 方向包 `st_lan_rx++` 后**丢弃**。

表现：容器内 `nslookup` 一条都发不出去，但 `ip a` 看 WAN 口是有地址的（那是 `ip addr add` 加的，natd 不知道）。

## 6. ARP: 只答 reply，不答 request

natd 的 ARP 处理只针对 **reply**。所以：

- 它不会替 LAN 客户端应答上游的 ARP 请求 → 上游需要静态路由或它自己发 ARP
- 切换瞬间上游网关的 ARP 缓存仍指向旧设备 → **入向黑洞**

**必须手动发 GARP**：

```sh
# 在宿主执行，切换后立刻
arping -U -c 3 -I eth16.16 -s 203.0.113.10 203.0.113.1
```

不要用 `proxy_arp + ip route add <ip>/32 dev lo`，那会把内核拖进入向路径，破坏 `/32` 方案。

## 7. WAN MAC 归一

芯片默认 MAC `00:00:00:00:21:00` 是无效 OUI，上游可能当无效帧丢弃。

```sh
ip link set eth16.16 address 02:00:00:00:21:10
```

**注意两点**：

1. natd 只在**启动时** `SIOCGIFHWADDR` 读一次 MAC。改完必须重启 natd
2. **VLAN 子接口不会继承父接口后改的 MAC**。若用 `eth16.16`，MAC 必须显式设在 `eth16.16` 上（natd 从 `--wan` 指定的接口读）

## 8. LMT 管理口白名单

LMT 口只放行**目的 IP `192.254.1.16`**：

- 改地址 → 不可达
- 加第二 IP → 不可达
- 代理 ARP → 无效
- `eth200` 虚拟口 → 有效但不下发

所以 LMT 只能做**管理面**，不能当 LAN 业务口。要 LMT 也跑 DHCP，得在容器侧用 `mv-ow` macvlan，且 `192.254.1.17` 与 `.16` 同子网会走内核短路（假阳性），实测 `.17` 才能通。

## 9. 性能

| 实现 | 纯处理能力 | 1G 线速余量 |
|---|---|---|
| `natd` (C) | 8.3M pkt/s | ~100x |
| `nat.py` (Python 2) | 39k pkt/s | ~455 Mbps |

Python 版仅作回退，跑满千兆会掉速。
