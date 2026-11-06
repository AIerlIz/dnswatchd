# Troubleshooting

Each entry is: what you see, what to check, what it usually means.

## Nothing happened after installing

That is the intended behaviour. Installing changes no DNS setting. Open
*Services → DNS Watchdog* and press **Take over DNS**, or run
`dnswatchd takeover`.

`dnswatchd status` says `managing: no` until you do.

## Takeover refuses to run

```
dhcp.@dnsmasq[0].serversfile is already set to '/tmp/somebody-elses.servers'; refusing to take over
```

Something else already owns dnsmasq's servers-file. dnswatchd will not overwrite
it. Either point that other tool elsewhere, or accept a shared setup by editing
`servers_file` in `/etc/config/dnswatchd` to the same path — but then two
programs are writing one file, which is a bad idea.

## DNS stopped resolving right after takeover

Check the three values that matter:

```sh
uci show dhcp.@dnsmasq[0] | grep -E 'server|serversfile|noresolv'
cat /etc/dnswatchd/servers
pidof dnsmasq
logread | grep -i dnsmasq | tail -20
```

Expected: no `server=` list, `serversfile=/etc/dnswatchd/servers`,
`noresolv=1`, one `server=` line in the file, dnsmasq running.

If the servers-file is empty or missing, the seed step failed — the backup is
intact, so `dnswatchd rollback` gets you back to a working resolver immediately.

## DNS works but it never switches

```sh
dnswatchd status
```

Look at the upstream table:

- `status: up` on the first row and the switch never happens → correct, nothing
  is broken.
- All rows `down`, or `fails` climbing on everything → the probe itself cannot
  reach the network. Try one by hand:
  `dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in`
  If that fails from the shell but works in the browser, the upstream is
  reachable but not answering as configured — check `probe_domain` and
  `expect_cidr` before blaming the watchdog.
- `fails` never moves at all → the service is not running:
  `/etc/init.d/dnswatchd status`, and confirm `enabled` is `1`.
- Everything looks healthy but nothing changes → `dry_run` is on. It logs
  decisions and writes nothing.

## It switches back and forth

Raise `fail_threshold` and `recover_threshold`. In `latency` mode also raise
`latency_margin` and `latency_switch_after` — two upstreams with similar
round-trips will otherwise take turns.

`dnswatchd status --json` shows the measured `rtt` per upstream; if they are
within a few milliseconds of each other, `latency` mode has nothing to decide.

## The ISP resolver still answers

```sh
uci get dhcp.@dnsmasq[0].noresolv     # must be 1
```

If it is not `1`, dnsmasq still reads `/tmp/resolv.conf.d/resolv.conf.auto` and
those servers compete with ours. This is the exact failure the whole design
exists to prevent — re-run `dnswatchd takeover`, or set it by hand and
`/etc/init.d/dnsmasq reload`.

## Changes have no effect until restart

dnsmasq re-reads `--servers-file` on reload, but it does **not** re-read its own
configuration file on SIGHUP. Changing `dhcp` options needs a reload of the init
script (which regenerates the config and lets procd restart the instance), not a
signal. `dnswatchd takeover` and `rollback` do this for you.

## DNS is broken after a reboot

The servers-file lives in `/etc`, so it survives. Check that it is still there
and still readable:

```sh
ls -l /etc/dnswatchd/servers
cat /etc/dnswatchd/servers
```

If the file is fine but dnsmasq started before it existed, dnsmasq logs
`cannot read ...servers` once and keeps going with no upstream. A
`/etc/init.d/dnsmasq reload` fixes it immediately; `dnswatchd takeover` writes
the file at the right moment, which is why hand-editing UCI is discouraged.

## The LuCI page shows nothing

```sh
ubus list dnswatchd
ubus call dnswatchd status
```

If `ubus list` does not show the object, rpcd has not scanned the plugin:
`/etc/init.d/rpcd reload`. If `ubus call` works but the page does not, the
session's ACL is missing the `dnswatchd` object — log out and back in so the ACL
is re-read.

## Rolling back

```sh
dnswatchd rollback              # newest backup
dnswatchd rollback --from 20261106-231502
```

Backups live in `/etc/dnswatchd/backup/<timestamp>/` and are never removed
automatically. Each holds the original `dhcp` export, the exact option values
that were replaced, and the upstream list that was cleared.

## What to include in a bug report

```sh
dnswatchd status --json
dnswatchd probe <your upstream> <probe domain> <cidr> <mode>
logread | grep dnswatchd | tail -50
uci show dnswatchd
uci show dhcp.@dnsmasq[0]
```

That covers the decision, the measurement, and the configuration it was made
against.
