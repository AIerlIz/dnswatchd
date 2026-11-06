# dnswatchd

[简体中文](README.zh-CN.md) | **English**

A DNS upstream watchdog for OpenWrt. It probes the upstream, checks what comes
back, and switches when the answers stop being correct.

![license](https://img.shields.io/badge/license-MIT-blue)

---

## The problem

A common setup:

```
clients -> main router dnsmasq -> side router (clash, fake-ip transparent proxy) -> upstream DNS
```

When the side router dies (VM shutdown, clash crash, PVE reboot), dnsmasq keeps
sending queries to an address that no longer answers. The whole network loses DNS.

Configuring two upstreams does not fix this:

> dnsmasq queries all upstreams **concurrently and takes whichever answers first**.
>
> A proxy upstream returns `198.18.x.x` (fake-ip). A direct upstream returns a
> real IP. Fastest wins, so the answer changes from query to query: proxying
> works intermittently and is very hard to diagnose.

---

## What dnswatchd does instead

It validates the answer rather than just checking whether a reply arrived, and
it writes exactly one `server=` line when switching, never several.

The `--servers-file` always holds a single line. dnsmasq reloads it on `SIGHUP`,
so the switch does not restart the process.

---

## Why checking the answer matters

A side router fails in two different ways:

| Failure | What dnsmasq sees | Timeout-only watchdog |
|---|---|---|
| VM off / link down | query times out | detects it |
| **clash crashed, dnsmasq still alive** | **returns a wrong answer immediately** | **cannot detect it** |

In the second case the port is still open and `nslookup` exits 0, but the reply
is a direct answer with a real IP. Proxying has silently stopped working.

The check:

```
proxy upstream:  probe www.google.com -> answer must fall inside 198.18.0.0/16
direct upstream: probe www.baidu.com  -> answer must fall outside 198.18.0.0/16
```

A wrong answer means the upstream is unhealthy, whether or not the port responds.

---

## Install

### From the feed

```sh
wget -O /etc/opkg/dnswatchd.conf https://AIerlIz.github.io/dnswatchd/dnswatchd.conf
opkg update
opkg install dnswatchd
opkg install luci-app-dnswatchd   # optional web UI
```

### From source

```sh
# inside your OpenWrt SDK
echo "src-git dnswatchd https://github.com/AIerlIz/dnswatchd.git" >> feeds.conf.default
./scripts/feeds update dnswatchd
./scripts/feeds install -a -p dnswatchd
make package/dnswatchd/compile V=s
```

The package lands in `bin/packages/<arch>/dnswatchd/`. `PKGARCH:=all`, so it is
architecture independent.

---

## Prerequisites

Check both before configuring. Without them the switch either does nothing or
fights with UCI:

```sh
# 1. dnsmasq must have servers-file enabled (the install script sets this;
#    recheck after an upgrade)
uci get dhcp.@dnsmasq[0].serversfile
# expected: /tmp/dnsmasq.servers

# 2. the UCI server list must be empty, or dnsmasq queries both sources
uci get dhcp.@dnsmasq[0].server
# expected: an error, or empty
```

---

## Getting started

The install script (`/etc/uci-defaults/90-dnswatchd`) does four things:

1. backs up the existing `dhcp.@dnsmasq[0].server` to `/etc/dnswatchd.servers.bak`
2. seeds `/tmp/dnsmasq.servers` with the first address from that backup
3. clears the UCI `server` list so `--servers-file` takes over
4. copies that first address into `dnswatchd.primary.address`

**`enabled` defaults to `0`, so nothing runs after install.** Observe in dry-run
for a day first:

```sh
uci set dnswatchd.main.dry_run='1'
uci set dnswatchd.main.enabled='1'
uci set dnswatchd.main.interval='30'
uci commit dnswatchd
/etc/init.d/dnswatchd restart

# watch the decisions without applying them
logread -f -e dnswatchd
```

Once the verdicts look right, turn dry-run off:

```sh
uci set dnswatchd.main.dry_run='0'
uci commit dnswatchd
/etc/init.d/dnswatchd restart
```

---

## Configuration

`/etc/config/dnswatchd`:

```uci
config dnswatchd 'main'
	option enabled '1'                 # master switch
	option interval '30'               # probe interval in seconds, minimum 5
	option timeout '1'                 # per-probe timeout in seconds
	option fail_threshold '2'          # consecutive failures before DOWN
	option recover_threshold '2'       # consecutive successes before UP
	option servers_file '/tmp/dnsmasq.servers'
	option selection 'priority'        # priority | latency
	option latency_samples '3'         # latency only: ping samples
	option latency_margin '20'         # latency only: required speedup, percent
	option latency_switch_after '2'    # latency only: consecutive wins needed
	option dry_run '0'                 # log decisions, do not apply
	option syslog '1'
	option verbose '0'

config upstream 'primary'
	option enabled '1'
	option type 'proxy'                # proxy | direct, informational only
	option address '192.168.10.2'
	option port '53'
	option probe_domain 'www.google.com'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'in'            # in | not-in
	option priority '10'               # lower wins

config upstream 'fallback'
	option enabled '1'
	option type 'direct'
	option address '223.5.5.5'
	option port '53'
	option probe_domain 'www.baidu.com'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'not-in'
	option priority '20'
```

Add as many `upstream` sections as you need.

---

## Selection modes

### `priority` (default)

Walk the upstreams in ascending `priority` order and take the first healthy one:

```
proxy(10) healthy     -> use it
proxy(10) down        -> try aliyun(20)  -> use if healthy
aliyun(20) down too   -> try tencent(30) -> use if healthy
all unhealthy         -> leave servers-file untouched
```

### `latency`

Probe every upstream, keep the healthy ones, measure ping RTT to each, and pick
the fastest:

```
healthy:  proxy(10) 49ms, aliyun(20) 28ms, tencent(30) 0.6ms
chosen:   tencent, despite having the highest priority number
```

Three anti-flap guards, all configurable:

| Option | Default | Effect |
|---|---|---|
| `latency_margin` | 20 | a new candidate must be at least this much faster before it is considered |
| `latency_switch_after` | 2 | it must then win this many consecutive rounds |
| `latency_samples` | 3 | ping samples averaged per measurement |

When the current upstream stops being healthy, the first two guards are skipped
and the switch happens immediately.

### Two constraints on `latency`

1. **The upstream must answer ICMP.** `1.1.1.1`, `223.5.5.5` and `119.29.29.29`
   do. Some corporate resolvers and anything behind a firewall will not. Such an
   upstream is not excluded (it still resolves DNS), but its RTT is recorded as
   `99999` and it sorts last.
2. **The probe point must reach the upstream directly.** Inside an environment
   that hijacks all UDP/53 (the side router itself, for example), the
   "can it resolve" test and the RTT both become meaningless.

### Why ping and not DNS response time

busybox `date +%s%N` returns whole seconds on OpenWrt (measured: `1793954264`),
so shell cannot time a DNS round trip that takes tens of milliseconds.

Ping RTT is the only latency signal available. It measures network round-trip
time, which tracks DNS response time closely; the difference is server-side
processing, usually a few milliseconds.

### Which mode to use

| Situation | Use |
|---|---|
| side router plus one or two fallbacks | `priority`: side router first, fall back when it dies |
| several public resolvers, want the fastest | `latency`: pick among them automatically |
| unstable latency, frequent flapping | `priority`: avoids repeated switching |

---

## Command line

```sh
# one pass, for debugging
/usr/sbin/dnswatchd once

# current state
/usr/sbin/dnswatchd status
# active: primary
# servers-file: /tmp/dnsmasq.servers
#   # managed by dnswatchd - do not edit
#   server=192.168.10.2
# --- primary ---
#   fails=0
#   oks=7
#   status=up
# --- fallback ---
#   fails=6
#   oks=0
#   status=down

# probe one upstream by hand
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in
# OK
```

---

## How it works

```
every interval seconds:

  walk upstreams in priority order

  probe(addr, domain, cidr, mode)
    nslookup -type=A -timeout=T -retry=1 <domain> <addr>
    take the last Address line, check whether it falls inside or outside cidr

  state machine with hysteresis
    ok   -> oks++,  fails=0; oks  >= recover_threshold -> status=up
    fail -> fails++, oks=0;  fails >= fail_threshold   -> status=down

  first upstream with status=up wins

  when it differs from the active one:
    echo "server=<addr>" > /tmp/dnsmasq.servers
    kill -HUP $(pidof dnsmasq)
    echo "<section>" > /var/run/dnswatchd/active
```

**Why `--servers-file` instead of UCI**: `uci set` plus a service reload restarts
dnsmasq and drops DNS for 1-2 seconds. `--servers-file` with `SIGHUP` is the
mechanism dnsmasq provides for changing upstreams at runtime, and it leaves
`/etc/config/dhcp` untouched.

**Why only one `server=` line**: dnsmasq merges entries from `--server` and
`--servers-file`. Writing two puts you back on the concurrent-query path that
breaks fake-ip.

---

## Comparison

| | dnswatchd | felipecrs/dns-watchdog | watchcat | dnsdist | smartdns |
|---|---|---|---|---|---|
| Validates the answer | yes | no, timeout only | no, ICMP only | `mustResolve` only | no |
| Single-server switching | yes | yes | - | yes | no, concurrent queries |
| No DNS interruption | yes, SIGHUP | no, `service network reload` | - | yes | yes |
| LuCI interface | yes | no | yes | no | yes |
| Standard opkg package | yes | no, install script | yes | yes | yes |
| Size | ~20 KB | ~5 KB | ~30 KB | 2.4 MB | 4 MB |

---

## Troubleshooting

**Logs keep showing `no healthy upstream`**

```sh
# run one probe by hand and read the output
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in

# see what dnsmasq actually receives
nslookup www.google.com 192.168.10.2
```

If the manual `nslookup` returns a real IP instead of `198.18.x.x`, either
clash's fake-ip is not active or a rule sends that domain DIRECT. Change
`probe_domain`.

**It switched but DNS still fails**

```sh
# confirm dnsmasq really loaded servers-file
ps w | grep [d]nsmasq
# the command line should include --servers-file=/tmp/dnsmasq.servers

# confirm the UCI server list is empty
uci show dhcp.@dnsmasq[0].server
```

**It flaps between upstreams**

Raise `fail_threshold` and `recover_threshold`, or shorten `interval` so the
verdict responds faster.

---

## License

MIT
