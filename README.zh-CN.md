# V9200-OpenWrt-Router

[English](README.md) | **简体中文**

我把一台中兴 V9200 基站改成了路由器，这个仓库是折腾过程的记录，以及最后能跑通的那些脚本。

原厂内核保留，不刷机不改分区。OpenWrt 以 Docker 容器的形式跑在中兴原系统上面。

## 先说说这台机器的硬件，因为它才是折腾的理由

我用的板子是 **VSWD1**，插在 V9200 机框的槽位 1 上。中兴管 V9200 叫 5G BBU，VSW 就是负责交换和控制的那块板。

里面实际是这些东西：

- Intel Atom P5962B（Snow Ridge），**48 线程**
- 16 GB 内存，32 GB SSD，2 GB boot flash
- Intel Snow Ridge IES 交换芯片，底下挂 21 个 netdev
- Intel QAT c4xxx 加速卡，128 个 VF
- 面板上 2×10G SFP、2×QSFP、1×RJ45
- 双路供电：槽位 5 是 220V 交流，槽位 13 是 -48V 直流

说白了就是一台运营商级交换机，上面绑了一颗 48 线程的服务器 CPU，价格是退役 BBU 的价格。J4125 的小盒子 4 核，像样点的 x86 软路由也就 8 到 16 核。这台 48 线程，还是专门为包处理设计的架构，加上真正的交换 ASIC 在那儿做转发，CPU 根本不用管。千兆跑满它连汗都不出。

几个具体的好处：

**交换芯片是真硬件转发。** Intel IES，不是 CPU 模拟。`eth20` 是它到 CPU 的 100G 上联口，开机就是 up 的。里面还有 8 个 10G 的 SoC 内部通道（`eth8`–`eth15`），开机 PTP 同步，面板上没有引出，但确实存在。

**QAT 卡是白送的。** 中兴拿这 128 个 VF 给 5G 做加解密，你用不上。OpenWrt 的 `intel-qat` 包能直接用，IPsec VPN 就有了硬件加速。

**220V 插座直插。** 机框里 220V 交流和 -48V 直流两块电源板都在，家用只要交流那块。直流那块插着不亮灯是正常的，手册里就是这么写的。

**风扇和电源都不用管。** 风扇硬件自控温，重启时 fail-safe 全速，没有软件控制路径。电源板 MCU 自己保护。这两样都不用你在 OpenWrt 里做任何事。

但是有几个雷：

**有个看门狗会把你重启掉。** EPLD 在 `0xFE0BF000`，喂狗是往 `0xC8` 交替写 0/1，每 500 ms 一次，定时器在 `0xC4`（bit0 = armed）。**127 分钟不喂就复位整机。** 中兴自己的 `watchdogfeed` 进程退役了没在跑。你要移植到裸 OpenWrt，得自己喂。

**Marvell 那颗芯片不能碰。** `01:00.0`，`11ab:c81f`。内核没驱动，`HWM.EXE` 通过 DPDK 独占。我有一次拿裸 devmem 读它的 BAR，直接挂了总线，整机复位。只能走 HWM 初始化之后的 mmap。

**串口没找到位置。** UEFI 跑在 `console=ttyS4,115200`，但物理口没引出来。USB-C 是纯 host 口（dmesg 里没有任何 typec/ccg/ucsi 控制器），DBG/LMT 是纯网口（1000BASE-T 占满 8 针）。最可能在板上排针。所以现在进不去 BIOS 设置界面。

**RTC 没电池。** 芯片是好的，断电丢时间，NTP 解决。

**GNSS 得有天线。** `/dev/pps0` 的源其实是交换芯片的 `ptp0`，不是 GNSS 模块。配有源天线加 gpsd 和 chrony 能把授时弄回来。

完整信息在 [docs/hardware.md](docs/hardware.md)。

## 为什么不是"装个 OpenWrt"那么简单

内核编译时就没开 `CONFIG_NETFILTER`。没有 iptables，没有 nftables，没有连接跟踪，没有 NAT。不是被禁用了，也不是缺模块，是压根没编进去。想修得换内核，但没有别的内核可换。

所以 NAT 只能放在用户态。内核负责转发，一个叫 `natd` 的进程负责改包，然后你要花不少时间让这两者配合起来。

其他挡路的东西还有一堆。容器里的 `/proc/sys` 是只读的，sysctl 得从宿主用 `nsenter` 写。容器里只有 BusyBox 版 `ip`，建不了 VLAN 接口。网卡由中兴的中间件管着：`ice_sw` 暴露了 21 个，Marvell 那颗由 `HWM.EXE` 直接 mmap 操作，Linux 根本看不见。LMT 管理口还有一层目的地址白名单，只放行 `192.254.1.16`。

## 最费时间的四件事

### WAN 地址必须是 /32

一开始我按平时装 Linux 的习惯配了 /24。能通，然后几分钟后全崩：长连接断了，DNS 时好时坏，SSH 会话掉了。

原因是 /24 会让内核给整个子网加一条 connected 路由，于是上游网关变成了"直连可达"。natd 改完入向包注入之后，内核自己手里也有一份（从抓包点来的），一看源地址可达，找不到对应 socket，就回了个 RST。

配成 /32 就没有 connected 路由，入向包全部落到 tun0 的默认路由上，`rp_filter=1` 会在本地投递前把内核那份丢掉。而抓包点在此之前就已经拿到了副本，natd 要的正是这个。

```sh
ip addr add 203.0.113.10/24 dev eth16   # 这条会出问题
ip addr add 203.0.113.10/32 dev eth16   # 这条能用
```

还得把 `arp_ignore` 降到 1。默认值是 2，意思是"只有目标地址落在我的某个子网里才回 ARP"，而 /32 地址不属于任何子网，内核就一声不吭。

### natd 的出向必须走 eth16.16，不是 eth16

从 `eth16` 发看起来完全正常，实际什么都收不到。CPU 口是 `pvid=100`，natd 发出的裸帧会被归进 VLAN 100，而面板口在 VLAN 16，包根本到不了。判断方法：`ethtool -S eth16` 里 `TX_BCST` 一直是 0，但 `nat.log` 显示有包在发。

在宿主上建个 VLAN 子接口，把它作为 WAN 交给 natd，帧带上 tag 出去，面板口会在出口处剥掉。

```sh
ip link add link eth16 name eth16.16 type vlan id 16
```

这步只能在宿主做，容器里的 BusyBox `ip` 不支持。

### 少了 --static-ip，natd 会静默丢光所有包

有一次我漏了这个参数，为 DNS 折腾了一个小时。natd 退回到 DHCP 客户端模式，永远拿不到租约，`wan_ip` 一直是 0。主循环于是把所有 LAN 方向的包累加 `st_lan_rx` 然后扔掉。不报错，日志里也没有特别扎眼的行，而 `ip addr` 里那个手动加的地址还在。

### natd 从不回应 ARP 请求

它只处理 reply。切换那一刻，上游网关缓存里还留着旧设备的 MAC，入向流量就这么没了。我在这上面丢了十几分钟，才意识到是根本没有东西回来。

切换完立刻发一个免费 ARP：

```sh
arping -U -c 3 -I eth16.16 -s 203.0.113.10 203.0.113.1
```

别想着用 proxy_arp 加一条到 lo 的路由解决。那会把内核拖进入向路径，把上面那套 /32 的东西全搞坏。

## 各部分怎么拼起来

```sh
LAN 客户端
   │  br-lan (192.168.10.1)
   ▼
内核转发（没有 netfilter，只能转发）
   │  tun0 (169.254.255.1/30)
   ▼
natd（用户态 NAT，AF_PACKET 抓包）
   │  eth16.16（VLAN 16，/32 地址）
   ▼
上游网关
```

出向是 LAN 上来，内核转到 tun0，natd 从 tun0 读，改源地址和端口，重算校验和，从 eth16.16 发出去。入向反过来：natd 在 eth16.16 上抓，查连接表，还原原始目的地址，注入 tun0。

容器是 `--network none` 起的，网口全靠手工移进去。听着别扭，但这样容器就不会跟中兴的中间件抢网络栈，宿主也能保住自己的管理 IP。

两个接口值得知道：`veth-ow` 和 `veth-ow-c` 是容器跟宿主之间唯一的通路，`mv-ow` 是挂在 LMT 口上的 macvlan，给容器一个管理地址。

容器里没有 procd，就是个裸 rootfs，没有任何 `service` 可以用。所有东西都是 `nohup ... &` 起，容器重建后全得重来。所以才有 `watchdog.sh`，也所以才让它每 15 秒做同样的事而不先检查什么。相关脚本都是幂等的，直接再跑一遍就是最省事的收敛方式。

## 跑起来

完整版在 [docs/deployment.md](docs/deployment.md)。简版：

```sh
# 宿主：建 VLAN 接口
ip link add link eth16 name eth16.16 type vlan id 16
ip link set eth16.16 up

# 脚本拷进 volume
cp scripts/*.sh /var/lib/docker/volumes/openwrt-data/_data/bin/

# 你自己的网络配这里
cp configs/v9200.env.example configs/v9200.env
vi configs/v9200.env

# 拉起
set -a; . configs/v9200.env; set +a
sh scripts/setup-host.sh
sh scripts/nat-up.sh
```

然后记得发 GARP。这个不是可选项。

## 文档

- [docs/hardware.md](docs/hardware.md)：接口、指示灯、线缆
- [docs/architecture.md](docs/architecture.md)：整个栈怎么铺的
- [docs/natd-internals.md](docs/natd-internals.md)：上面那些结论的完整版
- [docs/deployment.md](docs/deployment.md)：一步步来，以及怎么回滚
- [docs/troubleshooting.md](docs/troubleshooting.md)：什么会坏、怎么判断坏在哪

## 部署之前

仓库里所有 IP、MAC、主机名都是占位符，全换成你自己的。

原厂系统还在，还在跑，中兴依然能连到设备。如果这一点你不能接受，那这套方案大概不适合你。

先备份原厂分区。

## 测试环境

中兴 VSWD1 交换板，装在 V9200 机框里（ZXRAN 5G BBU），内核 4.19.82-rt30-CGELV7.01.80B2-intel-axxia-standard，`ice_sw 0.15.0_rc5_33`。

其他板卡修订版或固件版本，接口命名、`natd` 参数、看门狗偏移量都可能不一样。动手前先看 `dmesg` 里的 rename 记录，别信文档里任何一个 eth 名字。

## 许可证

文档和脚本用 MIT。这里面没有中兴的东西，没有厂商二进制，没有固件镜像，也没有反编译产物。
