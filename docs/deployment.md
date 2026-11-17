# 部署

## 前置检查

在开始之前确认这几点，不满足就别往下走：

```sh
# 1. 容器在跑
docker ps | grep openwrt

# 2. 容器内没有 netfilter
docker exec openwrt sh -c 'zcat /proc/config.gz 2>/dev/null | grep NETFILTER'
# 期望: CONFIG_NETFILTER is not set

# 3. WAN 父口存在
ip link show eth16

# 4. 备份原配置
cp -a /var/lib/docker/volumes/openwrt-data/_data/etc /root/openwrt-etc.bak
```

## 步骤 1：宿主编 VLAN 子接口

**必须在宿主做**。容器内的 `ip` 是 BusyBox，不支持 `link add type vlan`。

```sh
ip link add link eth16 name eth16.16 type vlan id 16
ip link set eth16.16 up
ip link show eth16.16
```

如果没有 `CONFIG_VLAN_8021Q`，这一步会失败。检查：

```sh
zcat /proc/config.gz | grep VLAN_8021Q
```

## 步骤 2：部署脚本

```sh
DATA=/var/lib/docker/volumes/openwrt-data/_data
cp scripts/*.sh "$DATA/bin/"
cp configs/v9200.env.example "$DATA/etc/v9200.env"
chmod +x "$DATA/bin/"*.sh

# 编辑成你的实际网络
vi "$DATA/etc/v9200.env"
```

## 步骤 3：一次性拉起

```sh
set -a; . "$DATA/etc/v9200.env"; set +a
sh "$DATA/bin/setup-host.sh"
sh "$DATA/bin/nat-up.sh"
```

预期输出：

```
eth16.16 已创建 (父口 eth16, vid 16)
veth 就绪: 宿主 192.168.99.1 <-> 容器 192.168.99.2
mv-ow 就绪: eth1 -> 容器 (MAC 40:00:c0:fe:01:11)
eth18 已移入容器
eth19 已移入容器
NAT 已启动 impl=natd pid=12345 wan=eth16.16 tun=tun0 mtu=1500
```

## 步骤 4：验证

```sh
# 1. WAN 地址是 /32
docker exec openwrt ip addr show eth16.16
# 期望: inet <WAN_IP>/32

# 2. tun0 起来且路由正确
docker exec openwrt ip route
# 期望: default dev tun0

# 3. sysctl 生效
nsenter --net=/proc/$(docker inspect -f '{{.State.Pid}}' openwrt)/ns/net \
    cat /proc/sys/net/ipv4/conf/eth16.16/rp_filter
# 期望: 1

# 4. NAT 进程存活
docker exec openwrt sh -c 'kill -0 $(cat /data/logs/nat.pid) && echo alive'

# 5. 出向通
docker exec openwrt nslookup baidu.com
```

### 步骤 4.5：发 GARP（关键，别跳过）

切换后上游网关的 ARP 缓存仍指向旧设备，入向流量会黑洞十几分钟。**必须**：

```sh
arping -U -c 3 -I eth16.16 -s "$WAN_IP" "$WAN_GW"
```

## 步骤 5：装守护

```sh
# 宿主 crontab
(crontab -l 2>/dev/null; echo "* * * * * set -a; . $DATA/etc/v9200.env; set +a; sh $DATA/bin/watchdog.sh --once") | crontab -
```

或者跑 daemon：

```sh
nohup sh "$DATA/bin/watchdog.sh" >/dev/null 2>&1 &
```

## 回滚

任何一步出问题：

```sh
# 1. 停 NAT
kill "$(cat $DATA/logs/nat.pid)" 2>/dev/null

# 2. 删 WAN 地址
docker exec openwrt ip addr del "$WAN_IP/32" dev eth16.16 2>/dev/null

# 3. 删 VLAN
ip link del eth16.16

# 4. 原设备接管（若还有旧路由器，直接插回）
```

**重要**：回滚前先确认旧设备的 WAN 侧配置仍然存在。切换后部分上游配置可能已被覆盖。

## 常见坑

| 现象 | 原因 | 修法 |
|---|---|---|
| `容器内无 eth16.16` | 宿主没建 VLAN | 步骤 1 |
| `ip link add type vlan` 报错 | 在容器内执行了 | 改到宿主 |
| LAN 通几分钟后全断 | 用了 `/24` | 改 `/32` + `rp_filter=1` |
| 入向完全不通 | 没发 GARP | `arping -U` |
| `nslookup` 无响应但 `ip a` 有地址 | natd 缺 `--static-ip` | 检查启动参数 |
| 上游能 ping 通，出向 `TX_BCST=0` | 从 `eth16` 而非 `eth16.16` 发 | 改 `--wan` |
| 切换后 SSH 失联 | 宿主缺回程路由 | 通道四的 `ip route add` |
