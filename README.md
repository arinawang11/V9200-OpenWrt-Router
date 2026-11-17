# V9200-OpenWrt-Router

**English** | [简体中文](README.zh-CN.md)

Turn a **ZTE V9200 (ZXRAN 5G BBU)** into a home/office software router.

> Keeps the vendor kernel and system intact — no flashing, no repartitioning. OpenWrt runs as a Docker container on top of the vendor stack.

---

## Why this project

The V9200 is carrier-grade radio equipment with a completely closed software stack:

| Constraint | Detail |
|---|---|
| No netfilter in kernel | `CONFIG_NETFILTER is not set` — no iptables/nftables, **no kernel-space NAT** |
| `/proc/sys` read-only in container | sysctls must be written from the host via `nsenter` |
| BusyBox `ip` only | cannot create VLAN sub-interfaces inside the container |
| Private middleware owns the NICs | `ice_sw` exposes 21 netdevs; Marvell chip driven by `HWM.EXE` via mmap |
| LMT port has a destination whitelist | only `192.254.1.16` is reachable — address change, second IP, proxy ARP all fail |

This project documents how to work around all of it: **NAT in userspace, kernel only forwards**.

## Key findings (read this first, saves days)

### 1. WAN address must be `/32` — `/24` is fatal

```sh
ip addr add 203.0.113.10/24 dev eth16   # ✗ WRONG: creates a connected route
ip addr add 203.0.113.10/32 dev eth16   # ✓ CORRECT
```

Why: `/24` creates `203.0.113.0/24 dev eth16` as a connected route, which makes `rp_filter` accept packets sourced from the gateway. The kernel then sees NAT-returning packets as locally deliverable and answers with **RST** — every long-lived connection dies.

With `/32` there is no connected route → inbound packets fall through to `default dev tun0` → `rp_filter=1` drops the kernel's copy before local delivery, while the AF_PACKET tap still sees it.

### 2. natd does not answer ARP requests

It only handles ARP *replies*. At cutover the upstream gateway still caches the old MAC — inbound traffic is black-holed for ~10 minutes. **You must send a GARP at cutover**; do not expect natd to do it.

### 3. Missing `--static-ip` makes natd go fully silent

In DHCP-client mode it never gets an address → `wan_ip==0` → the main loop counts every LAN-bound packet in `st_lan_rx` and drops it. This is the root cause of "not a single DNS query leaves the container".

### 4. Panel business ports cannot be a second LAN port

All four panel ports behave identically and none works. Either add a USB NIC or accept a single LAN + SSH tunnel.

## Architecture

```
LAN clients
   │  br-lan (192.168.10.1)
   ▼
kernel forwarding (no CONFIG_NETFILTER — forward only)
   │  tun0 (169.254.255.1/30)
   ▼
natd (userspace NAT, AF_PACKET tap)
   │  eth16.16 (VLAN 16, /32 address)
   ▼
upstream gateway
```

| Component | Implementation | Notes |
|---|---|---|
| NAT | `natd` (C, 8.3M pkt/s) | default; `nat.py` 39k pkt/s as fallback |
| VLAN sub-if | **host** creates `eth16.16` | container BusyBox `ip` cannot |
| DHCP/DNS | dnsmasq 2.93, single config | no unbound |
| Supervision | `watchdog.sh`, idempotent every 15s | auto-recovers after container rebuild |
| Persistence | Docker volume `openwrt-data/_data` | survives container recreation |

## Quick start

Full guide: [`docs/deployment.md`](docs/deployment.md).

```sh
# 1. Host: create the VLAN sub-interface
ip link add link eth16 name eth16.16 type vlan id 16
ip link set eth16.16 up

# 2. Deploy scripts into the volume
cp scripts/*.sh /var/lib/docker/volumes/openwrt-data/_data/bin/

# 3. Configure your network
cp configs/v9200.env.example configs/v9200.env
vi configs/v9200.env

# 4. Bring it up
set -a; . configs/v9200.env; set +a
sh scripts/setup-host.sh
sh scripts/nat-up.sh
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/hardware.md](docs/hardware.md) | Ports, LEDs, cabling |
| [docs/architecture.md](docs/architecture.md) | Container network stack and data plane |
| [docs/natd-internals.md](docs/natd-internals.md) | natd reverse engineering: `/32` vs `/24`, rp_filter, ARP |
| [docs/deployment.md](docs/deployment.md) | Step-by-step deploy and rollback |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Failure modes and how to diagnose them |

## ⚠️ Security notes

- All IPs, MACs and hostnames in this repo are **examples** — replace them before deploying
- The vendor OS stays in place, so **the vendor keeps remote management capability**. Do not use this if that matters to you
- Back up the original partitions and config first

## Compatibility

- Device: ZTE V9200 (ZXRAN 5G BBU), kernel 4.19.82-rt30, `ice_sw 0.15.0_rc5_33`
- Other firmware versions may use different netdev names or `natd` flags — adapt accordingly

## License

MIT for documents and scripts. No vendor binaries, firmware, or decompilation output included.
