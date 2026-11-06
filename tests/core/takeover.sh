#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Takeover / rollback tests against a fake `uci`.
#
# This is the only code path in dnswatchd that rewrites someone's dnsmasq
# configuration, so it gets its own suite: what must hold is that takeover
# leaves a working, backed-up, reversible state, and that rollback restores
# exactly the values that were there before.
#
#   sh tests/core/takeover.sh

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENTRY="$ROOT/dnswatchd/files/dnswatchd"
LIB="$ROOT/dnswatchd/files/lib"
SHIM="$ROOT/tests/core/shim"

TMP=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

store_get() {
	"$SHIM/uci" -q get "$1" 2>/dev/null
}

store_has() {
	"$SHIM/uci" -q get "$1" >/dev/null 2>&1 && echo 1 || echo 0
}

mkdir -p "$TMP/run" "$TMP/etc" "$TMP/bin"

cat > "$TMP/bin/dnsmasq-init" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(date +%s)" "$1" >> "${RELOAD_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$TMP/bin/dnsmasq-init"

export PATH="$SHIM:$PATH"
export UCI_SHIM_STORE="$TMP/uci.json"
export DNSWATCHD_LIB="$LIB"
export DNSWATCHD_STATE_DIR="$TMP/run"
export DNSWATCHD_ETC_DIR="$TMP/etc"
export DNSWATCHD_PROBE="$TMP/bin/true"
export DNSWATCHD_DNSMASQ_INIT="$TMP/bin/dnsmasq-init"
export DNSWATCHD_RESOLV_AUTO="$TMP/resolv.conf.auto"
export DNSWATCHD_FUNCTIONS="$SHIM/functions.sh"
export DNSWATCHD_TEST_CONFIG="$TMP/etc/config"
export RELOAD_LOG="$TMP/reloads.log"

SERVERS="$TMP/etc/servers"

cat > "$DNSWATCHD_TEST_CONFIG" <<EOF
config dnswatchd 'main'
	option enabled '0'
	option servers_file '$SERVERS'
	option syslog '0'
EOF

seed() {
	rm -rf "$TMP/etc" "$TMP/run"
	mkdir -p "$TMP/etc" "$TMP/run"
	: > "$RELOAD_LOG"
	cat > "$UCI_SHIM_STORE" <<'EOF'
{
 "dhcp.@dnsmasq[0].server": ["192.168.10.2", "223.5.5.5"],
 "dnswatchd.main.enabled": "0"
}
EOF
}

dsw() { sh "$ENTRY" "$@"; }

# ---------------------------------------------------------------- takeover

seed
dsw takeover >"$TMP/out.txt" 2>&1
rc=$?

assert_eq "takeover succeeds" "0" "$rc"
assert_eq "servers-file is seeded with the first configured upstream" \
	"192.168.10.2" "$(sed -n 's/^server=//p' "$SERVERS" 2>/dev/null)"
assert_eq "only one server line is written" "1" "$(grep -c '^server=' "$SERVERS")"
assert_eq "dhcp server list is cleared" "0" "$(store_has dhcp.@dnsmasq[0].server)"
assert_eq "serversfile points at ours" "$SERVERS" "$(store_get dhcp.@dnsmasq[0].serversfile)"
assert_eq "resolv.conf is no longer consulted" "1" "$(store_get dhcp.@dnsmasq[0].noresolv)"
assert_eq "isp fallback upstream is created" "resolv" "$(store_get dnswatchd.isp.source)"
assert_eq "isp fallback is lowest priority" "90" "$(store_get dnswatchd.isp.priority)"
assert_eq "watchdog is enabled" "1" "$(store_get dnswatchd.main.enabled)"
assert_eq "marker is written" "1" "$([ -f "$TMP/etc/takenover" ] && echo 1 || echo 0)"
assert_eq "dnsmasq was reloaded" "1" "$(grep -c reload "$RELOAD_LOG")"

BACKUPS=$(ls -1 "$TMP/etc/backup" 2>/dev/null | wc -l)
assert_eq "one backup directory exists" "1" "$BACKUPS"
BAK=$(ls -1 "$TMP/etc/backup" | head -1)
assert_eq "backup keeps the original servers" "2" \
	"$(grep -c . "$TMP/etc/backup/$BAK/servers.list")"
assert_eq "backup records that noresolv was unset" "0" \
	"$(sed -n 's/^noresolv_set=//p' "$TMP/etc/backup/$BAK/meta")"

# ---------------------------------------------------------------- idempotent

dsw takeover >"$TMP/out2.txt" 2>&1
assert_eq "second takeover is a no-op" "0" "$?"
assert_eq "it does not create another backup" "1" "$(ls -1 "$TMP/etc/backup" | wc -l)"
assert_eq "it says it is already managing" "1" \
	"$(grep -c 'already managing' "$TMP/out2.txt")"

# ---------------------------------------------------------------- rollback

dsw rollback >"$TMP/out3.txt" 2>&1
rc=$?

assert_eq "rollback succeeds" "0" "$rc"
assert_eq "original upstreams are restored verbatim" \
	"192.168.10.2 223.5.5.5" "$(store_get dhcp.@dnsmasq[0].server)"
assert_eq "serversfile is removed again" "0" "$(store_has dhcp.@dnsmasq[0].serversfile)"
assert_eq "noresolv is removed again" "0" "$(store_has dhcp.@dnsmasq[0].noresolv)"
assert_eq "watchdog is disabled" "0" "$(store_get dnswatchd.main.enabled)"
assert_eq "marker is gone" "0" "$([ -f "$TMP/etc/takenover" ] && echo 1 || echo 0)"
assert_eq "dnsmasq was reloaded again" "2" "$(grep -c reload "$RELOAD_LOG")"

# ---------------------------------------------------------------- conflict

seed
printf '%s' "$SERVERS" >/dev/null
cat > "$UCI_SHIM_STORE" <<'EOF'
{
 "dhcp.@dnsmasq[0].server": ["192.168.10.2"],
 "dhcp.@dnsmasq[0].serversfile": "/tmp/somebody-elses.servers"
}
EOF

dsw takeover >"$TMP/out4.txt" 2>&1
rc=$?

assert_eq "takeover refuses a servers-file owned by someone else" "1" "$rc"
assert_eq "the message names the conflict" "2" "$(grep -c 'refusing to take over' "$TMP/out4.txt")"
assert_eq "the original server list is untouched" "192.168.10.2" \
	"$(store_get dhcp.@dnsmasq[0].server)"
assert_eq "their serversfile is untouched" "/tmp/somebody-elses.servers" \
	"$(store_get dhcp.@dnsmasq[0].serversfile)"
assert_eq "no marker is written" "0" "$([ -f "$TMP/etc/takenover" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------- 127.0.0.1

seed
cat > "$UCI_SHIM_STORE" <<'EOF'
{
 "dhcp.@dnsmasq[0].server": ["127.0.0.1", "223.5.5.5"]
}
EOF
printf 'nameserver 9.9.9.9\n' > "$DNSWATCHD_RESOLV_AUTO"

dsw takeover >"$TMP/out5.txt" 2>&1
assert_eq "a loopback upstream is not carried over" "server=223.5.5.5" \
	"$(sed -n 's/^server=/server=/p' "$SERVERS" 2>/dev/null)"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
