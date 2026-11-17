# 架构

## 总体

厂商系统是封闭的，OpenWrt 以 Docker 容器形式叠加在上面，共享原厂内核。

```
┌─────────────────────────────────────────────────────────┐
│ 原厂系统 (rootfs, 只读挂载)                              │
│   ├── Luban 中间件 (PyInstaller + Go)  ← 网络栈私有实现   │
│   ├── HWM.EXE  ← mmap 直操 Marvell 芯片                  │
│   └── ice_sw 0.15.0_rc5_33  ← Intel E800 驱动, 21 netdev │
│                                                          │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Docker: openwrt (--network none)                  │  │
│  │   ├── br-lan  ← eth18 / eth19 (面板口)            │  │
│  │   ├── mv-ow   ← macvlan (LMT 管理口)              │  │
│  │   ├── veth-ow-c ← 控制通道到宿主                  │  │
│  │   ├── eth16.16  ← WAN (宿主创建, 移入)            │  │
│  │   ├── tun0    ← 内核转发终点                      │  │
│  │   └── natd    ← 用户态 NAT                        │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## 为什么容器要 `--network none`

直接给容器 `--network host` 会与厂商中间件抢网络栈。用 `--network none` + 手动移入接口，隔离干净：

- 容器重启后 netns 销毁，物理口自动退回宿主 → watchdog 重新移入
- 宿主持有 LMT 管理 IP 不受影响

## 数据面

### 出向 (LAN → WAN)

```
LAN 客户端
  │ 以太网帧
  ▼
br-lan (10.x.x.1/24)
  │ 内核 ip_forward
  ▼
tun0 (169.254.255.1/30)
  │ natd 从 tun0 读 (AF_PACKET)
  ▼
改写: 源 IP → WAN_IP, 源端口 → 分配端口
      更新 IP/TCP/UDP 校验和
  │
  ▼
eth16.16 (AF_PACKET 注入, 802.1Q tag 16)
  │
  ▼
上游网关
```

### 入向 (WAN → LAN)

```
上游网关
  │
  ▼
eth16.16
  │ AF_PACKET 在 ip_rcv 之前旁路复制
  ├──→ natd 收: 查连接表, 还原目的地址
  │       │
  │       ▼
  │    tun0 注入 → 内核投递 → br-lan → LAN 客户端
  │
  └──→ 内核 ip_rcv 也收到一份
          │ rp_filter=1 + /32 地址
          ▼
        丢弃（无 connected 路由, 判为不可达源）
```

**关键**：内核那份被 `rp_filter` 丢掉是**设计如此**。若地址配成 `/24`，`rp_filter` 会通过，内核回 RST，NAT 就崩了。

## 控制面

| 路径 | 用途 |
|---|---|
| `veth-ow` ↔ `veth-ow-c` | 容器 ↔ 宿主（容器 `--network none`，唯一通路） |
| `mv-ow` macvlan | LMT 管理口，容器直接拿到 `192.254.1.x` |

## 持久化

容器内 `/data` 映射到宿主 Docker volume：

```
/var/lib/docker/volumes/openwrt-data/_data/
├── bin/          nat-up.sh, natd, nat.py, watchdog.sh ...
├── etc/          dnsmasq-lan.conf, v9200.env
├── logs/         nat.log, dnsmasq.log, watchdog.log
└── etc/dnsmasq.leases
```

容器重建不丢配置。

## 容器内没有 procd

OpenWrt 容器是**裸 rootfs**，没有 init 系统。所以：

- 不能 `service dnsmasq start`
- 所有服务必须 `nohup ... &` 裸启动
- 重启容器后需要 watchdog 重新拉起

这也解释 `nat-up.sh` 里为什么用 `mkdir -p` + `nohup` 而不是 service 管理。

## 为什么不用 iptables

```
$ docker exec openwrt iptables -t nat -L
iptables: No chain/target/match by that name.
```

内核 `CONFIG_NETFILTER is not set`。所有 NAT 必须在用户态完成。这是整个项目的出发点。

## 组件职责

| 组件 | 职责 | 不能做什么 |
|---|---|---|
| 内核 | `ip_forward`、包投递 | NAT、防火墙、连接跟踪 |
| `natd` | NAT 改写、连接表、校验和 | 应答上游 ARP request |
| `dnsmasq` | DHCP、DNS | 路由 |
| `watchdog.sh` | 幂等收敛 | 不能判断"是否需要"，只能无脑重放 |
| 宿主脚本 | VLAN、netns、sysctl | 容器内不能做 |
