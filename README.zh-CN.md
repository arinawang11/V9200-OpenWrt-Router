# V9200-OpenWrt-Router

[English](README.md) | **简体中文**

把 **中兴 V9200 (ZXRAN 5G BBU)** 改造成家用/办公软路由。

> 保留原厂内核与系统，不刷机、不改分区；OpenWrt 以 Docker 容器形式跑在厂商系统之上。

---

## 为什么有这个项目

V9200 是运营商级基站设备，软件栈完全封闭，一路都是坑：

| 限制 | 具体表现 |
|---|---|
| 内核无 netfilter | `CONFIG_NETFILTER is not set` —— 没有 iptables/nftables，**内核态 NAT 根本不存在** |
| 容器内 `/proc/sys` 只读 | sysctl 必须从宿主用 `nsenter` 写 |
| 只有 BusyBox 版 `ip` | 容器内**不能**创建 VLAN 子接口 |
| 网络栈由私有中间件接管 | `ice_sw` 产出 21 个 netdev；Marvell 芯片由 `HWM.EXE` 以 mmap 直操 |
| LMT 口有目的 IP 白名单 | 只放行 `192.254.1.16` —— 改地址、加第二 IP、代理 ARP 全部无效 |

这个项目记录了怎么绕开这些：**NAT 放用户态做，内核只负责转发**。

## 核心结论（先看，能省你几天）

### 1. WAN 地址必须是 `/32`，`/24` 必死

```sh
ip addr add 203.0.113.10/24 dev eth16   # ✗ 错：内核生成 connected 路由
ip addr add 203.0.113.10/32 dev eth16   # ✓ 对
```

原因：`/24` 会把 `203.0.113.0/24 dev eth16` 写成 connected 路由，导致 `rp_filter` 对来自网关的包放行。内核看到 NAT 回流包认为"本机可达"，直接回 **RST** —— 所有长连接当场断。

配成 `/32` 就没有 connected 路由 → 入向包全部落到 `default dev tun0` → `rp_filter=1` 在本地投递前丢掉内核那份，AF_PACKET 旁路照收不误。

### 2. natd 不答 ARP request

它只处理 ARP **reply**。切换瞬间上游网关缓存仍指向旧设备的 MAC，入向流量会黑洞十几分钟。**必须在切换当场发 GARP**，别指望 natd。

### 3. 缺 `--static-ip` 会让 natd 变成"全哑"

DHCP 客户端模式下永远拿不到地址 → `wan_ip==0` → 主循环把所有 LAN 方向包计进 `st_lan_rx` 然后丢掉。这就是"容器内一条 DNS 查询都发不出去"的根因。

### 4. 面板业务口不能当第二个 LAN 口

四个面板口实测行为一致，全部不可用。要么加 USB 网卡，要么接受单 LAN + SSH 隧道。

## 架构

```
LAN 客户端
   │  br-lan (192.168.10.1)
   ▼
内核转发（无 CONFIG_NETFILTER，只能转发）
   │  tun0 (169.254.255.1/30)
   ▼
natd（用户态 NAT，AF_PACKET 旁路）
   │  eth16.16（VLAN 16，/32 地址）
   ▼
上游网关
```

| 组件 | 实现 | 说明 |
|---|---|---|
| NAT | `natd`（C，8.3M pkt/s） | 默认；`nat.py` 39k pkt/s 作回退 |
| VLAN 子接口 | **宿主**创建 `eth16.16` | 容器内 BusyBox `ip` 不支持 |
| DHCP/DNS | dnsmasq 2.93 一体配置 | 不引入 unbound |
| 守护 | `watchdog.sh` 每 15s 幂等收敛 | 容器重建后自动恢复 |
| 持久化 | Docker volume `openwrt-data/_data` | 容器重建不丢配置 |

## 快速开始

完整步骤见 [`docs/deployment.md`](docs/deployment.md)。

```sh
# 1. 宿主：建 VLAN 子接口
ip link add link eth16 name eth16.16 type vlan id 16
ip link set eth16.16 up

# 2. 部署脚本到 volume
cp scripts/*.sh /var/lib/docker/volumes/openwrt-data/_data/bin/

# 3. 配置你的网络
cp configs/v9200.env.example configs/v9200.env
vi configs/v9200.env

# 4. 拉起
set -a; . configs/v9200.env; set +a
sh scripts/setup-host.sh
sh scripts/nat-up.sh
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/hardware.md](docs/hardware.md) | 接口、指示灯、线缆制作 |
| [docs/architecture.md](docs/architecture.md) | 容器网络栈与数据面 |
| [docs/natd-internals.md](docs/natd-internals.md) | natd 逆向：`/32` vs `/24`、rp_filter、ARP |
| [docs/deployment.md](docs/deployment.md) | 分步部署与回滚 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 故障模式与判定方法 |

## ⚠️ 安全提示

- 本仓库中的 IP、MAC、主机名**全部是示例**，部署前必须替换成你自己的
- 设备保留原厂系统，**厂商保留远程管理能力**。介意的话别用
- 操作前务必备份原厂分区与配置

## 兼容性

- 设备：中兴 V9200 (ZXRAN 5G BBU)，内核 4.19.82-rt30，`ice_sw 0.15.0_rc5_33`
- 其他固件版本的 netdev 命名、`natd` 参数可能不同，按实际情况调整

## 许可证

文档与脚本采用 MIT。不含任何厂商二进制、固件或反编译产物。
