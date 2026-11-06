#!/bin/sh
# Probe behaviour tests against tests/probe/fixture_dns.py.
#
#   sh tests/probe/run.sh [path-to-dnswatch-probe]
#
# Exits non-zero on the first mismatch. POSIX sh only: this also runs in CI.

set -u

PROBE=${1:-./dnswatch-probe}
PORT=${PROBE_PORT:-5353}
PYTHON=${PYTHON:-python3}

pass=0
fail=0
fixture_pid=""

cleanup() {
	[ -n "$fixture_pid" ] && kill "$fixture_pid" 2>/dev/null
	wait "$fixture_pid" 2>/dev/null
}
trap cleanup EXIT INT TERM

if [ ! -x "$PROBE" ]; then
	echo "probe binary not executable: $PROBE" >&2
	exit 2
fi

$PYTHON "$(dirname "$0")/fixture_dns.py" "$PORT" >/dev/null 2>&1 &
fixture_pid=$!

# Wait for the socket to answer, up to ~3s.
i=0
while [ "$i" -lt 30 ]; do
	if "$PROBE" -s 127.0.0.1 -p "$PORT" -d ok.test -t 300 >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	sleep 0.1
done

check() {
	desc="$1"
	want_rc="$2"
	want="$3"
	shift 3

	out=$("$PROBE" "$@" 2>&1)
	rc=$?

	if [ "$rc" -eq "$want_rc" ] && echo "$out" | grep -q "$want"; then
		pass=$((pass + 1))
		printf 'ok   %s\n' "$desc"
	else
		fail=$((fail + 1))
		printf 'FAIL %s\n     want rc=%s containing %s\n     got  rc=%s %s\n' \
			"$desc" "$want_rc" "$want" "$rc" "$out"
	fi
}

check "plain A answer"            0 '"ok":true'      -s 127.0.0.1 -p "$PORT" -d ok.test -t 1000
check "in-range passes"           0 '"ok":true'      -s 127.0.0.1 -p "$PORT" -d ok.test -t 1000 -m in -c 198.18.0.0/16
check "in-range violation fails"  1 '"wrong-answer"' -s 127.0.0.1 -p "$PORT" -d ok.test -t 1000 -m in -c 10.0.0.0/8
check "not-in passes"             0 '"ok":true'      -s 127.0.0.1 -p "$PORT" -d ok.test -t 1000 -m not-in -c 10.0.0.0/8
check "not-in violation fails"    1 '"wrong-answer"' -s 127.0.0.1 -p "$PORT" -d ok.test -t 1000 -m not-in -c 198.18.0.0/16
check "all A records must match"  1 '"wrong-answer"' -s 127.0.0.1 -p "$PORT" -d multi.test -t 1000 -m in -c 198.18.0.0/16
check "all-inside passes"         0 '"ok":true'      -s 127.0.0.1 -p "$PORT" -d multiok.test -t 1000 -m in -c 198.18.0.0/16
check "cname chain tolerated"     0 '"ok":true'      -s 127.0.0.1 -p "$PORT" -d cname.test -t 1000 -m in -c 198.18.0.0/16
check "nxdomain is no-answer"     1 '"no-answer"'    -s 127.0.0.1 -p "$PORT" -d nx.test -t 1000
check "nxdomain rcode"            1 'NXDOMAIN'       -s 127.0.0.1 -p "$PORT" -d nx.test -t 1000
check "nodata is no-answer"       1 '"no-answer"'    -s 127.0.0.1 -p "$PORT" -d nodata.test -t 1000
check "servfail is no-answer"     1 'SERVFAIL'       -s 127.0.0.1 -p "$PORT" -d servfail.test -t 1000
check "refused is no-answer"      1 'REFUSED'        -s 127.0.0.1 -p "$PORT" -d refused.test -t 1000
check "truncated retried over tcp" 0 '"ok":true'     -s 127.0.0.1 -p "$PORT" -d trunc.test -t 1000

# Wall clock must be bounded by the deadline, not by libc defaults.
t0=$(date +%s)
"$PROBE" -s 127.0.0.1 -p "$PORT" -d blackhole.test -t 500 >/dev/null 2>&1
elapsed=$(( $(date +%s) - t0 ))
if [ "$elapsed" -le 2 ]; then
	pass=$((pass + 1))
	printf 'ok   deadline bounded (%ss)\n' "$elapsed"
else
	fail=$((fail + 1))
	printf 'FAIL deadline bounded: took %ss for a 500ms deadline\n' "$elapsed"
fi

# Nothing listening: connection refused must not hang either.
t0=$(date +%s)
"$PROBE" -s 127.0.0.1 -p 9 -d ok.test -t 500 >/dev/null 2>&1
elapsed=$(( $(date +%s) - t0 ))
if [ "$elapsed" -le 2 ]; then
	pass=$((pass + 1))
	printf 'ok   dead port bounded (%ss)\n' "$elapsed"
else
	fail=$((fail + 1))
	printf 'FAIL dead port took %ss\n' "$elapsed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
