# dnswatchd

An OpenWrt DNS upstream watchdog.

It probes the upstream resolvers dnsmasq uses and checks that the answers land
where they should — inside a Clash fake-ip pool for a proxy upstream, outside it
for a direct one. When the preferred upstream stops answering correctly it
rewrites dnsmasq's `servers-file` to the next candidate and reloads it. When the
preferred one recovers, it goes back.

Installing the package **changes nothing about your DNS**. Handing dnsmasq over
is a separate, explicit, reversible step.

## Why it exists

A fake-ip proxy and a plain ISP resolver in the same dnsmasq means you no longer
control which one answers. One slow moment from the proxy and a real address
leaks into a domain that was supposed to stay fake — and everything built on
those addresses (routing rules, firewall marks) quietly stops matching.

dnsmasq has no notion of "this upstream is lying to me". dnswatchd adds one, and
keeps exactly one server in the pool so the choice is never ambiguous.

## Requirements

- OpenWrt 23.05, 24.10 or 25.12
- `dnsmasq` or `dnsmasq-full`
- An architecture the feed publishes (see below), or build it yourself

## Install

```sh
# pick your architecture
opkg print-architecture

wget -O /etc/opkg/dnswatchd.conf \
  https://AIerlIz.github.io/dnswatchd/dnswatchd-aarch64_cortex-a53.conf

opkg update
opkg install dnswatchd
opkg install luci-app-dnswatchd      # optional web UI
```

The feed currently publishes `x86_64`, `aarch64_generic`,
`aarch64_cortex-a53`, `arm_cortex-a7_neon-vfpv4`, `mipsel_24kc` and
`mips_24kc`. Anything else: see [Building from source](#building-from-source).

## First run

Nothing happens on install. dnsmasq keeps doing exactly what it did before.

**Web UI** — *Services → DNS Watchdog*. The Status panel shows what dnsmasq
currently uses; **Take over DNS** performs the migration. Read the dialog: it
lists exactly what is about to change. **Give DNS back** undoes it.

**Command line**, same thing:

```sh
dnswatchd takeover     # back up, point dnsmasq at us, disable resolv.conf
dnswatchd status       # what is going on
dnswatchd rollback     # put it all back
```

`takeover` will refuse if `dhcp.@dnsmasq[0].serversfile` already points at
something that is not ours — it does not overwrite another tool's setup.

### What takeover actually changes

1. Copies the dnsmasq UCI config and the exact values it is about to touch into
   `/etc/dnswatchd/backup/<timestamp>/`.
2. Writes the servers-file with the first upstream dnsmasq already had.
3. Clears `dhcp.@dnsmasq[0].server`.
4. Sets `dhcp.@dnsmasq[0].serversfile` to `/etc/dnswatchd/servers`.
5. Sets `dhcp.@dnsmasq[0].noresolv=1`.
6. Adds an `isp` upstream (`source=resolv`) so the ISP resolvers remain
   available as a real, lowest-priority candidate.
7. Reloads dnsmasq and enables the service.

Step 5 is the whole point and the easiest to get wrong: with `noresolv=0`,
dnsmasq keeps `/tmp/resolv.conf.d/resolv.conf.auto` in its pool, so the ISP
resolver is always a second upstream whether you configured it or not.

## Configuration

`/etc/config/dnswatchd`. Everything below is also in the web UI.

```uci
config dnswatchd 'main'
	option enabled '0'              # master switch; takeover turns it on
	option interval '30'            # seconds between rounds, minimum 5
	option probe_deadline '2000'    # milliseconds per DNS query, hard limit
	option fail_threshold '2'       # consecutive failures before DOWN
	option recover_threshold '2'    # consecutive successes before UP again
	option servers_file '/etc/dnswatchd/servers'
	option selection 'priority'     # priority | latency
	option latency_margin '20'      # percent; latency selection only
	option latency_switch_after '2' # rounds in a row; latency selection only
	option round_budget '80'        # percent of interval a round may spend
	option dry_run '0'              # log decisions, never write the file
	option syslog '1'
	option verbose '0'
```

Each upstream:

```uci
config upstream 'primary'
	option enabled '1'
	option source 'static'          # static | resolv
	option address '192.168.10.2'
	option port '53'
	option probe_domain 'www.google.com'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'in'         # in | not-in | any
	option priority '10'
```

`source='resolv'` ignores `address` and expands the IPv4 nameservers in
`/tmp/resolv.conf.d/resolv.conf.auto` instead — up to two entries, numbered
`<section>_1`, `<section>_2`.

### How a round works

Every enabled upstream is probed every round (no early exit — that is what makes
the status page honest). Then:

- `selection='priority'` — the lowest `priority` that is up wins.
- `selection='latency'` — the smallest measured DNS round-trip wins, but only if
  it is at least `latency_margin` percent faster than the incumbent, for
  `latency_switch_after` rounds in a row.

A round that runs past `round_budget` percent of `interval` stops probing and
decides with what it has.

## Commands

```
dnswatchd                       run the watch loop (procd starts this)
dnswatchd once [--json]         run a single round
dnswatchd status [--json]       show what is going on
dnswatchd probe <addr> <domain> [cidr] [mode] [port]
dnswatchd switch <section>      force one upstream, bypassing the selection
dnswatchd takeover              take dnsmasq over
dnswatchd rollback              give it back
dnswatchd apply                 commit staged UCI and restart (used by LuCI)
```

`status --json` is the machine-readable form: what is active, every upstream's
counters and last measured round-trip, and what dnsmasq itself is configured
with.

## Limitations

- IPv4 only. `AAAA` records are not consulted and not validated.
- dnsmasq only. smartdns, mosdns and friends manage their own upstreams.
- One upstream at a time, by design. If you want several answering, this is the
  wrong tool.
- The probe is a compiled, statically linked binary, so the package is
  architecture specific.

## Building from source

```sh
echo "src-git dnswatchd https://github.com/AIerlIz/dnswatchd.git" >> feeds.conf.default
./scripts/feeds update dnswatchd
./scripts/feeds install -a -p dnswatchd
make package/dnswatchd/compile V=s
make package/luci-app-dnswatchd/compile V=s
```

## Tests

No OpenWrt needed:

```sh
gcc -O2 -o /tmp/dnswatch-probe dnswatchd/files/dnswatch-probe.c
sh tests/probe/run.sh /tmp/dnswatch-probe
sh tests/core/run.sh
sh tests/core/takeover.sh
```

## More

- [docs/DESIGN.md](docs/DESIGN.md) — the invariants and why they exist
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — when it misbehaves
- [README.zh.md](README.zh.md) — 中文说明

## License

MIT
