# V9200-OpenWrt-Router

**English** | [简体中文](README.zh-CN.md)

I turned a ZTE V9200 base station into a router. This repo is what I learned doing it, plus the scripts that ended up working.

The vendor kernel stays. No flashing, no repartitioning. OpenWrt runs in a Docker container on top of whatever ZTE shipped.

## Why it's not just "install OpenWrt"

The kernel is built without `CONFIG_NETFILTER`. That means no iptables, no nftables, no connection tracking, no NAT. Not disabled, not missing a module. Never compiled in. You cannot fix this without a new kernel, and there is no new kernel.

So NAT has to happen in userspace. The kernel forwards packets, a process called `natd` rewrites them, and you spend a while convincing the two to cooperate.

A few other things get in the way. `/proc/sys` is read-only inside the container, so sysctls have to be written from the host through `nsenter`. The container only has BusyBox `ip`, which can't create VLAN interfaces. The network cards are owned by ZTE middleware: `ice_sw` exposes 21 of them, and the Marvell chip is driven by `HWM.EXE` doing mmap directly, so Linux never sees it. And the LMT management port has a destination whitelist that only allows `192.254.1.16`.

## The four things that cost me the most time

### The WAN address has to be /32

I set it to /24 first, like you would on any normal Linux box. It worked, then everything broke after a few minutes: long-lived connections died, DNS went intermittent, SSH sessions dropped.

The reason is that /24 makes the kernel add a connected route for the whole subnet. Now the upstream gateway counts as directly reachable. When natd rewrites an inbound packet and injects it, the kernel also has its own copy from the packet tap, decides the source is reachable, finds no matching socket, and sends an RST.

With /32 there's no connected route, so inbound packets fall through to the default route on tun0 and `rp_filter=1` throws away the kernel's copy before local delivery. The tap still sees it first, which is all natd needs.

```sh
ip addr add 203.0.113.10/24 dev eth16   # this is the one that breaks
ip addr add 203.0.113.10/32 dev eth16   # this is the one that works
```

You also have to drop `arp_ignore` to 1. The default of 2 means "only answer ARP if the target is inside one of my subnets", and a /32 address isn't inside any subnet, so the kernel stays silent.

### natd has to go out through eth16.16, not eth16

Sending from `eth16` looks correct and gets you nothing. The CPU port has `pvid=100`, so any untagged frame natd emits gets classified into VLAN 100. The panel port is in VLAN 16, so the packet never arrives. The tell is that `ethtool -S eth16` shows `TX_BCST` stuck at zero while `nat.log` shows packets being sent.

Create a VLAN subinterface on the host, give natd that as its WAN interface, and the frames carry a tag that the panel port strips on the way out.

```sh
ip link add link eth16 name eth16.16 type vlan id 16
```

This has to happen on the host. The container's BusyBox `ip` doesn't support it.

### Without --static-ip, natd silently drops everything

I left the flag off once and spent an hour on DNS. natd falls back to DHCP client mode, never gets a lease, and ends up with `wan_ip == 0`. The main loop then takes every packet headed for the LAN, increments `st_lan_rx`, and throws it away. No error, no log line that stands out, and `ip addr` still shows the address you added manually.

### natd never answers ARP requests

It handles replies only. At the moment you cut over, the upstream gateway still has the old device's MAC cached, so inbound traffic goes nowhere. I lost about fifteen minutes to this before realising nothing was coming back.

Send a gratuitous ARP right after switching:

```sh
arping -U -c 3 -I eth16.16 -s 203.0.113.10 203.0.113.1
```

Don't try to solve this with proxy_arp and a route to lo. That pulls the kernel into the inbound path and breaks the /32 arrangement above.

## How the pieces fit

```sh
LAN clients
   │  br-lan (192.168.10.1)
   ▼
kernel forwarding (no netfilter, forward only)
   │  tun0 (169.254.255.1/30)
   ▼
natd (userspace NAT, AF_PACKET tap)
   │  eth16.16 (VLAN 16, /32 address)
   ▼
upstream gateway
```

Outbound goes LAN, kernel forwards to tun0, natd reads from tun0, rewrites the source address and port, recomputes checksums, and injects on eth16.16. Inbound is the reverse: natd taps eth16.16, looks up the connection, restores the original destination, injects on tun0.

The container runs with `--network none`. Interfaces are moved in by hand. It sounds awkward but it keeps the container from fighting ZTE's middleware over the network stack, and it means the host keeps its management IP.

Two interfaces worth knowing about: `veth-ow` to `veth-ow-c` is the only path between container and host, and `mv-ow` is a macvlan on the LMT port that gives the container a management address.

The container has no procd. It's a bare rootfs, so there's no `service` anything. Everything is `nohup ... &`, and everything has to be restarted after a container rebuild. That's why `watchdog.sh` exists and why it does the same thing every 15 seconds instead of checking anything first. Every script involved is idempotent, so just running them again is the cheapest way to converge.

## Getting it running

The full version is in [docs/deployment.md](docs/deployment.md). The short version:

```sh
# host: create the VLAN interface
ip link add link eth16 name eth16.16 type vlan id 16
ip link set eth16.16 up

# copy scripts into the volume
cp scripts/*.sh /var/lib/docker/volumes/openwrt-data/_data/bin/

# your network goes here
cp configs/v9200.env.example configs/v9200.env
vi configs/v9200.env

# bring it up
set -a; . configs/v9200.env; set +a
sh scripts/setup-host.sh
sh scripts/nat-up.sh
```

Then send the GARP. I mean it.

## Docs

- [docs/hardware.md](docs/hardware.md): ports, LEDs, cabling
- [docs/architecture.md](docs/architecture.md): how the stack is laid out
- [docs/natd-internals.md](docs/natd-internals.md): the long version of everything above
- [docs/deployment.md](docs/deployment.md): step by step, plus rollback
- [docs/troubleshooting.md](docs/troubleshooting.md): what breaks and how to tell what broke

## Before you deploy

Every IP, MAC and hostname in this repo is a placeholder. Replace them.

The vendor OS is still there and still running. ZTE can still reach the device. If that's a problem for you, this whole approach is probably the wrong one.

Back up the original partitions first.

## Tested on

ZTE V9200 (ZXRAN 5G BBU), kernel 4.19.82-rt30, `ice_sw 0.15.0_rc5_33`. Other firmware versions may name the interfaces differently or take different `natd` arguments.

## License

MIT, for the docs and scripts. Nothing here is ZTE's. There's no vendor binary, no firmware image, and no decompiled output.
