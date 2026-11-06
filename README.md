# dnswatchd

[简体中文](README.zh-CN.md) | **English**

Watches dnsmasq's upstream and switches when the answers go wrong.

![license](https://img.shields.io/badge/license-MIT-blue)

## Why this exists

```
clients -> router dnsmasq -> a VM running clash in fake-ip mode -> upstream
```

Reboot that VM for a kernel update and dnsmasq keeps querying an address that
no longer answers. DNS dies network-wide until you notice and fix it by hand.

Adding a second upstream makes it worse. dnsmasq sends to all upstreams at once
and uses whichever replies first. One returns fake-ip addresses, the other
returns real ones. Whichever wins the race decides whether proxying works for
that lookup, so it breaks about half the time and looks like flaky networking.

## What it does

It checks where the answer lands, not just whether a reply arrived. And when it
switches, it writes exactly one `server=` line into dnsmasq's servers-file.

dnsmasq reloads that file on `SIGHUP`. No process restart, no DNS gap.

## The check

A side router fails in two ways that look nothing alike:

| Failure | What dnsmasq sees | A timeout-only watchdog |
|---|---|---|
| VM down, or the link is gone | nothing, query times out | catches it |
| clash crashed, dnsmasq still up | a wrong answer, immediately | catches nothing |

The second one is the annoying case. Port is open, `nslookup` exits 0, and the
reply is a real IP because proxying quietly stopped. Nothing looks broken.

The probe therefore reads the answer:

```
proxy upstream:  ask www.google.com -> answer must land inside 198.18.0.0/16
direct upstream: ask www.baidu.com  -> answer must land outside 198.18.0.0/16
```

Wrong range, unhealthy upstream, regardless of whether the port answers.

## Install

From the feed:

```sh
wget -O /etc/opkg/dnswatchd.conf https://AIerlIz.github.io/dnswatchd/dnswatchd.conf
opkg update
opkg install dnswatchd
opkg install luci-app-dnswatchd   # optional web UI
```

From source, inside your SDK:

```sh
echo "src-git dnswatchd https://github.com/AIerlIz/dnswatchd.git" >> feeds.conf.default
./scripts/feeds update dnswatchd
./scripts/feeds install -a -p dnswatchd
make package/dnswatchd/compile V=s
```

The ipk lands in `bin/packages/<arch>/dnswatchd/`. `PKGARCH:=all`, so the
architecture does not matter.

## Setup

Check these two first. Without them the switch does nothing, or fights with UCI:

```sh
uci get dhcp.@dnsmasq[0].serversfile
# want: /tmp/dnsmasq.servers

uci get dhcp.@dnsmasq[0].server
# want: an error, or empty
```

The install script fills in both. On upgrade, check them again.

Then leave it in dry-run for a day:

```sh
uci set dnswatchd.main.dry_run='1'
uci set dnswatchd.main.enabled='1'
uci set dnswatchd.main.interval='30'
uci commit dnswatchd
/etc/init.d/dnswatchd restart

logread -f -e dnswatchd
```

`enabled` defaults to `0`, so nothing runs until you set it.

The script backs up your old `dhcp.@dnsmasq[0].server` to
`/etc/dnswatchd.servers.bak`, seeds `/tmp/dnsmasq.servers` from the first entry,
clears the UCI list, and copies that address into `dnswatchd.primary.address`.

Once the verdicts look sane:

```sh
uci set dnswatchd.main.dry_run='0'
uci commit dnswatchd
/etc/init.d/dnswatchd restart
```

## Config

`/etc/config/dnswatchd`:

```uci
config dnswatchd 'main'
	option enabled '1'                 # master switch
	option interval '30'               # seconds, minimum 5
	option timeout '1'                 # per-probe timeout
	option fail_threshold '2'          # consecutive fails before DOWN
	option recover_threshold '2'       # consecutive oks before UP
	option servers_file '/tmp/dnsmasq.servers'
	option selection 'priority'        # priority | latency
	option latency_samples '3'         # latency: ping samples
	option latency_margin '20'         # latency: required speedup, percent
	option latency_switch_after '2'    # latency: consecutive wins
	option dry_run '0'
	option syslog '1'
	option verbose '0'

config upstream 'primary'
	option enabled '1'
	option type 'proxy'                # proxy | direct, label only
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

Add as many `upstream` sections as you want.

## Picking an upstream

`priority` walks the list in ascending order and takes the first healthy one.

```
proxy(10) healthy     -> use it
proxy(10) down        -> aliyun(20) healthy? use it
aliyun(20) down too   -> tencent(30) healthy? use it
nothing healthy       -> leave the servers-file alone
```

`latency` probes everything, keeps the healthy ones, pings each, takes the
fastest.

```
healthy:  proxy(10) 49ms, aliyun(20) 28ms, tencent(30) 0.6ms
chosen:   tencent
```

It will not switch over every small win. A challenger has to beat the incumbent
by `latency_margin` percent, and then keep winning for `latency_switch_after`
rounds.

| Option | Default | Meaning |
|---|---|---|
| `latency_margin` | 20 | required speedup, in percent |
| `latency_switch_after` | 2 | consecutive rounds the challenger must win |

Neither applies once the incumbent has gone unhealthy, since there is then
nothing to protect.

`latency` mode needs the upstream to answer ICMP. `1.1.1.1`, `223.5.5.5` and
`119.29.29.29` do. Some corporate resolvers do not; those are not dropped, just
ranked last with a fake RTT of `99999`.

It also needs the probe to reach the upstream directly. Run it inside something
that hijacks UDP/53 and both the resolve test and the RTT become fiction.

### Why ping

busybox `date +%s%N` returns whole seconds on OpenWrt (I measured `1793954264`),
so there is no way to time a DNS round trip in shell.

Ping RTT is what is left. It is the network leg of the round trip; the server
adds a few milliseconds on top.

### Which mode

- Side router plus a fallback or two: `priority`. You want the side router and
  nothing else.
- Several public resolvers, no strong preference: `latency`.
- Latency keeps moving around: `priority`. Less switching.

## CLI

```sh
/usr/sbin/dnswatchd once      # one pass
/usr/sbin/dnswatchd status    # where it thinks it is
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in
```

`status` output:

```
active: primary
servers-file: /tmp/dnsmasq.servers
  # managed by dnswatchd - do not edit
  server=192.168.10.2
--- primary ---
  fails=0
  oks=7
  status=up
--- fallback ---
  fails=6
  oks=0
  status=down
```

## Internals

```
every interval seconds:

  walk upstreams in priority order

  probe(addr, domain, cidr, mode)
    nslookup -type=A -timeout=T -retry=1 <domain> <addr>
    take the last Address line, check it against cidr

  hysteresis
    ok   -> oks++,  fails=0; oks  >= recover_threshold -> up
    fail -> fails++, oks=0;  fails >= fail_threshold   -> down

  first upstream marked up wins

  if it differs from the active one:
    echo "server=<addr>" > /tmp/dnsmasq.servers
    kill -HUP $(pidof dnsmasq)
    echo "<section>" > /var/run/dnswatchd/active
```

`--servers-file` instead of `uci set` because a service reload restarts dnsmasq
and drops DNS for a second or two. `SIGHUP` is the hook dnsmasq provides for
exactly this, and it leaves `/etc/config/dhcp` alone.

One line only, because dnsmasq merges `--server` with `--servers-file`. Two
entries puts you back on the concurrent path that breaks fake-ip.

## Compared to other tools

| | dnswatchd | felipecrs/dns-watchdog | watchcat | dnsdist | smartdns |
|---|---|---|---|---|---|
| Checks the answer | yes | no, timeout only | no, ICMP only | `mustResolve` only | no |
| Switches to one server | yes | yes | - | yes | no, queries in parallel |
| No DNS gap | yes, SIGHUP | no, `service network reload` | - | yes | yes |
| LuCI | yes | no | yes | no | yes |
| opkg package | yes | no, install script | yes | yes | yes |
| Size | ~20 KB | ~5 KB | ~30 KB | 2.4 MB | 4 MB |

## When it breaks

**`no healthy upstream` forever**

```sh
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in
nslookup www.google.com 192.168.10.2
```

If the manual lookup gives a real IP instead of `198.18.x.x`, fake-ip is off or
a rule sends that domain DIRECT. Change `probe_domain`.

**It switched, DNS still dead**

```sh
ps w | grep [d]nsmasq     # should show --servers-file=/tmp/dnsmasq.servers
uci show dhcp.@dnsmasq[0].server   # should be empty
```

**It flips back and forth**

Raise `fail_threshold` and `recover_threshold`. Shortening `interval` also
helps, up to a point.

## License

MIT
