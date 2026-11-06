#!/bin/sh
# SPDX-License-Identifier: MIT
#
# End-to-end tests for the dnswatchd core: real entry point, real probe binary,
# real state files, against the canned DNS fixture. Only uci and the dnsmasq
# init script are shimmed.
#
#   sh tests/core/run.sh

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENTRY="$ROOT/dnswatchd/files/dnswatchd"
LIB="$ROOT/dnswatchd/files/lib"
SRC="$ROOT/dnswatchd/files/dnswatch-probe.c"
FIXTURE="$ROOT/tests/probe/fixture_dns.py"

TMP=$(mktemp -d)
PORT=${CORE_PORT:-5399}
PORT2=$((PORT + 1))
PASS=0
FAIL=0
FIX_A=""
FIX_B=""

cleanup() {
	[ -n "$FIX_A" ] && kill "$FIX_A" 2>/dev/null
	[ -n "$FIX_B" ] && kill "$FIX_B" 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

ok() {
	PASS=$((PASS + 1))
	printf 'ok   %s\n' "$1"
}

bad() {
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n     %s\n' "$1" "$2"
}

assert_contains() {
	if grep -qF "$2" "$3" 2>/dev/null; then
		ok "$1"
	else
		bad "$1" "expected '$2' in $(basename "$3"), got: $(head -3 "$3" 2>/dev/null | tr '\n' ' ')"
	fi
}

assert_eq() {
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		bad "$1" "expected '$3', got '$2'"
	fi
}

# ---------------------------------------------------------------- environment

mkdir -p "$TMP/run" "$TMP/etc" "$TMP/bin"

cat > "$TMP/bin/dnsmasq-init" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(date +%s)" "$1" >> "${RELOAD_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$TMP/bin/dnsmasq-init"

printf 'nameserver 9.9.9.9\nnameserver 1.2.3.4\n' > "$TMP/resolv.conf.auto"

if ! gcc -O1 -o "$TMP/bin/probe" "$SRC" 2>"$TMP/build.log"; then
	echo "cannot build probe:" >&2
	cat "$TMP/build.log" >&2
	exit 2
fi

python3 "$FIXTURE" "$PORT" >/dev/null 2>&1 &
FIX_A=$!
python3 "$FIXTURE" "$PORT2" >/dev/null 2>&1 &
FIX_B=$!

i=0
while [ "$i" -lt 40 ]; do
	"$TMP/bin/probe" -s 127.0.0.1 -p "$PORT" -d ok.test -t 300 >/dev/null 2>&1 &&
		"$TMP/bin/probe" -s 127.0.0.1 -p "$PORT2" -d ok.test -t 300 >/dev/null 2>&1 && break
	i=$((i + 1))
	sleep 0.1
done

export DNSWATCHD_LIB="$LIB"
export DNSWATCHD_STATE_DIR="$TMP/run"
export DNSWATCHD_ETC_DIR="$TMP/etc"
export DNSWATCHD_PROBE="$TMP/bin/probe"
export DNSWATCHD_DNSMASQ_INIT="$TMP/bin/dnsmasq-init"
export DNSWATCHD_RESOLV_AUTO="$TMP/resolv.conf.auto"
export DNSWATCHD_FUNCTIONS="$ROOT/tests/core/shim/functions.sh"
export DNSWATCHD_TEST_CONFIG="$TMP/etc/config"
export RELOAD_LOG="$TMP/reloads.log"

SERVERS="$TMP/etc/servers"
PRIMARY_TARGET="server=127.0.0.1#$PORT"
FALLBACK_TARGET="server=127.0.0.1#$PORT2"

reset_state() {
	rm -rf "$TMP/run" "$TMP/etc"
	mkdir -p "$TMP/run" "$TMP/etc"
	: > "$RELOAD_LOG"
}

# write_config <primary-domain> <primary-mode> <primary-cidr> [extra-main-option]
write_config() {
	_pdom=$1
	_pmode=$2
	_pcidr=$3
	_extra=${4:-}

	cat > "$DNSWATCHD_TEST_CONFIG" <<EOF
config dnswatchd 'main'
	option enabled '1'
	option interval '5'
	option probe_deadline '800'
	option fail_threshold '2'
	option recover_threshold '2'
	option servers_file '$SERVERS'
	option selection 'priority'
	option syslog '0'
	option verbose '0'
	$_extra

config upstream 'primary'
	option enabled '1'
	option source 'static'
	option address '127.0.0.1'
	option port '$PORT'
	option probe_domain '$_pdom'
	option expect_cidr '$_pcidr'
	option expect_mode '$_pmode'
	option priority '10'

config upstream 'fallback'
	option enabled '1'
	option source 'static'
	option address '127.0.0.1'
	option port '$PORT2'
	option probe_domain 'ok.test'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'in'
	option priority '20'
EOF
}

dsw() {
	sh "$ENTRY" "$@"
}

# ---------------------------------------------------------------- 1. healthy priority

reset_state
write_config ok.test in 198.18.0.0/16
dsw once >"$TMP/out1.txt" 2>&1

assert_contains "healthy primary is applied" "$PRIMARY_TARGET" "$SERVERS"
assert_contains "port survives into the servers-file" "#$PORT" "$SERVERS"
assert_contains "state file records the success" "oks=1" "$TMP/run/primary.state"
assert_contains "dnsmasq reloaded through the init script" " reload" "$RELOAD_LOG"
assert_eq "exactly one server line" "1" "$(grep -c '^server=' "$SERVERS")"

# ---------------------------------------------------------------- 2. demotion

reset_state
write_config nx.test any ""
dsw once >"$TMP/out2a.txt" 2>&1

assert_contains "first failure is counted, not acted on" "fails=1" "$TMP/run/primary.state"
assert_contains "an unhealthy primary falls through immediately" "$FALLBACK_TARGET" "$SERVERS"

dsw once >"$TMP/out2b.txt" 2>&1
assert_contains "fail_threshold reached demotes the upstream" "status=down" "$TMP/run/primary.state"

# ---------------------------------------------------------------- 3. recovery is debounced

write_config ok.test in 198.18.0.0/16
dsw once >/dev/null 2>&1
assert_contains "one success is not enough to switch back" "$FALLBACK_TARGET" "$SERVERS"

dsw once >/dev/null 2>&1
assert_contains "recover_threshold reached switches back" "$PRIMARY_TARGET" "$SERVERS"

# ---------------------------------------------------------------- 4. dry run

reset_state
write_config ok.test in 198.18.0.0/16 "option dry_run '1'"
dsw once >/dev/null 2>&1
if [ -f "$SERVERS" ]; then
	bad "dry_run leaves the servers-file alone" "servers-file was created"
else
	ok "dry_run leaves the servers-file alone"
fi

# ---------------------------------------------------------------- 5. bad upstream is skipped

reset_state
write_config ok.test in "not-a-cidr"
dsw once >"$TMP/out5.txt" 2>&1
assert_contains "invalid cidr is reported on stderr" "not a CIDR" "$TMP/out5.txt"
assert_contains "the valid upstream still wins" "$FALLBACK_TARGET" "$SERVERS"

# ---------------------------------------------------------------- 6. status json

reset_state
write_config ok.test in 198.18.0.0/16
dsw once >/dev/null 2>&1
dsw once >/dev/null 2>&1
dsw status --json > "$TMP/status.json" 2>"$TMP/status.err"

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/status.json" 2>/dev/null; then
	ok "status --json is valid JSON"
else
	bad "status --json is valid JSON" "$(head -3 "$TMP/status.json")"
fi

assert_contains "status names the active section" '"section":"primary"' "$TMP/status.json"
assert_contains "status reports the debounced state" '"status":"up"' "$TMP/status.json"
assert_contains "status carries the measured rtt" '"rtt":"' "$TMP/status.json"

# ------------------------------------------------- 6b. status table (regression)
# 0.1.x shipped `done < "$(sort ...)"`, which treats the sort output as a
# filename. It must never come back.
dsw status > "$TMP/status.txt" 2>&1

assert_contains "status renders the upstream row" "primary" "$TMP/status.txt"
if grep -q 'cannot open' "$TMP/status.txt"; then
	bad "status does not treat sort output as a filename" "$(grep 'cannot open' "$TMP/status.txt")"
else
	ok "status does not treat sort output as a filename"
fi

# ---------------------------------------------------------------- 7. resolv expansion

reset_state
cat > "$DNSWATCHD_TEST_CONFIG" <<EOF
config dnswatchd 'main'
	option enabled '1'
	option servers_file '$SERVERS'
	option syslog '0'

config upstream 'isp'
	option enabled '1'
	option source 'resolv'
	option probe_domain 'ok.test'
	option expect_mode 'any'
	option priority '90'
EOF

(
	export DNSWATCHD_LIB
	# shellcheck source=/dev/null
	. "$ROOT/tests/core/shim/functions.sh"
	# shellcheck source=/dev/null
	. "$LIB/config.sh"
	collect_upstreams "$TMP/resolv.list" >/dev/null
)

assert_contains "source=resolv numbers the first nameserver" "|isp_1|9.9.9.9|" "$TMP/resolv.list"
assert_contains "source=resolv numbers the second nameserver" "|isp_2|1.2.3.4|" "$TMP/resolv.list"
assert_eq "resolv upstreams all use port 53" "2" "$(grep -c '|53|' "$TMP/resolv.list")"

# ---------------------------------------------------------------- 8. latency comparison

(
	# shellcheck source=/dev/null
	. "$LIB/select.sh"
	_faster_enough 50 100
)

if [ $? -eq 0 ]; then
	ok "latency: 50ms beats 100ms by more than the margin"
else
	bad "latency: 50ms beats 100ms by more than the margin" "returned false"
fi

(
	# shellcheck source=/dev/null
	. "$LIB/select.sh"
	_faster_enough 90 100
)

if [ $? -eq 0 ]; then
	bad "latency: 90ms does not beat 100ms by the margin" "returned true"
else
	ok "latency: 90ms does not beat 100ms by the margin"
fi

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
