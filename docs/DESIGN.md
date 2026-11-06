# Design

This document records the decisions that are easy to undo by accident. If you
are about to change one of them, the reason it exists is below.

## The three invariants

1. **dnsmasq's upstream pool contains exactly one entry, and dnswatchd wrote it.**
   No `list server`, `noresolv=1`, one `server=` line in the servers-file.
2. **dnsmasq is never handed a value we did not just read back.** The file is
   written to a temporary name, `mv`'d into place, re-read, and only then is
   dnsmasq told to reload.
3. **Installing the package changes nothing.** Handing dnsmasq over is an
   explicit `takeover` with a backup, and `rollback` reverses it exactly.

Everything below is a consequence of one of those three.

## Why exactly one server line

The obvious-looking design — write both the proxy resolver and a fallback into
the servers-file and let dnsmasq sort it out — is the bug.

dnsmasq picks between configured upstreams itself. It is not a "try the first,
fall back to the second" list you control from outside. With a fake-ip proxy in
the pool, "whichever one answers" is precisely the thing that must not happen:
a real address from the ISP resolver for a domain the proxy was supposed to
fake breaks every rule downstream that was written against the fake one.

So dnswatchd owns the choice, and dnsmasq is given one option.

### The second upstream nobody configured

`--servers-file` is not the only source of upstreams. OpenWrt's dnsmasq init
script adds a resolv-file as well:

```
dnsmasq.init:1107   config_get_bool noresolv "$cfg" noresolv 0
dnsmasq.init:1108   if [ "$noresolv" != "1" ]; then
dnsmasq.init:1110       config_get resolvfile "$cfg" resolvfile /tmp/resolv.conf.d/resolv.conf.auto
dnsmasq.init:1112       xappend "--resolv-file=$resolvfile"
```

`noresolv` defaults to **0**, so the ISP resolvers netifd wrote into
`resolv.conf.auto` are always in the pool unless you turn them off. Version
0.1.x set `serversfile` but never touched `noresolv`, which means its headline
promise — "there is only ever one upstream" — was never true on a stock system.

`takeover` sets `noresolv=1` and then adds the ISP resolvers back as an explicit
upstream (`source=resolv`, priority 90). They stay available; they just stop
being invisible and stop outranking anything.

While we are here: `--all-servers` is also opt-in (`dnsmasq.init:1015`). Without
it dnsmasq queries one server and retries others on failure — it does not
broadcast. The danger was never "concurrent queries"; it was "we do not control
which one gets asked".

## Why a compiled probe

The 0.1.x probe was `nslookup` plus `sed | awk | grep | tail`. Measured against
busybox:

- `-timeout=1` does not bound the wall clock: a blackholed server took ~5 s,
  because busybox retries on its own. Five dead upstreams filled a 30 s interval.
- With several A records, every consumer ended up taking the last `Address:`
  line and silently dropping the rest, so a mixed answer (one fake-ip, one real)
  could pass.
- A NODATA reply exits **0** with no answer lines at all — the same exit code as
  success, and an empty result that looks like a parser bug.
- The only latency proxy available was ICMP ping, which is a different quantity
  and unusable against resolvers that drop ICMP.

`dnswatch-probe` is ~560 lines of C with no dependencies. It speaks UDP, retries
over TCP when the response is truncated, enforces a hard deadline with `poll()`,
reports the real DNS round-trip, collects **all** A records, and classifies the
outcome. It never calls the libc resolver, which is why a static musl binary is
safe on a 5.15 kernel.

Classes (`timeout` / `no-answer` / `wrong-answer`) exist for observability only.
The threshold is one counter: three classes with three thresholds is a
configuration surface nobody can tune correctly.

## State

- **`/etc/dnswatchd/servers` is the truth.** The active upstream is derived from
  it; there is no separate `active` file to drift out of sync.
- It lives in `/etc`, not `/tmp`, because dnsmasq starts at `START=19` and
  dnswatchd at `START=95`. A servers-file in `/tmp` is gone after a reboot, so
  with `noresolv=1` dnsmasq would come up with no upstream at all for the ~76
  init steps before the watchdog runs.
- Counters live in `/var/run/dnswatchd` and are deliberately lossy: they are
  debounce state, not history.
- State files are parsed line by line against a whitelist and are never
  sourced — a file in `/var/run` must not be able to execute shell.
- A round takes a `mkdir` lock. `once` from LuCI and the daemon loop can overlap,
  and two writers of the same servers-file is exactly the race that produces a
  half-applied switch. `mkdir` rather than `flock` because busybox does not
  reliably ship `flock`.

## Applying

`/etc/init.d/dnsmasq reload`, never `kill -HUP $(pidof dnsmasq)`.

OpenWrt's `reload_service` runs `start_service` first, which regenerates
`/var/etc/dnsmasq.conf.$cfg`; procd hashes that file and restarts the instance
when it changes, and only afterwards forwards the signal. An external HUP can
therefore land on a PID that is being replaced, and `pidof` can return two PIDs
during the overlap. The init script's own path does not have that window.

SIGHUP is enough on its own: dnsmasq re-reads `--servers-file` on reload
(`dnsmasq.c:1492` → `read_servers_file()` in `option.c`), reopening it by path,
so the `mv`-into-place is picked up and a missing file leaves the old list
intact.

## Control plane

LuCI does not get `/bin/sh` exec. It talks to an rpcd object with seven methods,
each of which re-validates its arguments before they reach the CLI. Version
0.1.x granted a shell and then built a command line by string concatenation,
which is how the same upstream ended up inserted twice: once through the `uci`
module, once through the shell.

The LuCI form itself only writes UCI through the `uci` module; applying goes
through `dnswatchd apply` (`uci commit` + service reload), so there is exactly
one write path.

## Packaging and the 25.12 split

OpenWrt 24.10 and earlier consume `ipk` through `opkg`; 25.12 ships `apk`. The
feed is built on the 24.10 SDK and publishes `ipk`, so it serves 23.05 and
24.10. The package itself builds unchanged on 25.12 — nothing in it depends on
the package manager — but installing there needs an `apk` index, which is not
published. Saying "supports 25.12" without that caveat would be the same kind of
claim as the old "only ever one upstream".

## What was deliberately not built

- **DoH / DoT.** A different problem with a different failure mode, and it would
  double the surface.
- **IPv6.** Every answer check is an IPv4 range check. Half-supporting IPv6
  would mean probing AAAA and validating against something, and "something" is
  not obvious for a fake-ip setup.
- **Several simultaneous upstreams.** That is the thing being prevented.
- **Per-class thresholds.** See above.
- **Splitting the probe into its own package.** It is an implementation detail;
  a separate package would only create a version pairing to get wrong.
