#!/bin/sh
# SPDX-License-Identifier: MIT
#
# dnswatchd - probe wrapper.
#
# The C probe owns all DNS work and prints a single JSON object; this file only
# lifts the fields out. There is no nslookup fallback on purpose: a silent
# downgrade to a parser that drops A records would be worse than a loud failure.

: "${DNSWATCHD_LIB:=/usr/lib/dnswatchd}"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/common.sh"

# probe_one <addr> <port> <domain> <cidr> <mode>
#   sets P_OK(0|1) P_CLASS P_RCODE P_RTT P_JSON
#   returns 0 when the upstream answered as expected
probe_one() {
	_p_addr=$1
	_p_port=$2
	_p_dom=$3
	_p_cidr=$4
	_p_mode=$5

	P_OK=0
	P_CLASS=""
	P_RCODE=""
	P_RTT=""
	P_JSON=""

	if [ ! -x "$PROBE_BIN" ]; then
		err "probe binary is missing or not executable: $PROBE_BIN"
		P_CLASS="missing"
		return 1
	fi

	set -- -s "$_p_addr" -p "$_p_port" -d "$_p_dom" -m "$_p_mode" -t "$PROBE_DEADLINE"
	[ -n "$_p_cidr" ] && set -- "$@" -c "$_p_cidr"

	P_JSON=$("$PROBE_BIN" "$@" 2>/dev/null)
	_p_rc=$?

	P_CLASS=$(printf '%s' "$P_JSON" | sed -n 's/.*"class":"\([^"]*\)".*/\1/p')
	P_RCODE=$(printf '%s' "$P_JSON" | sed -n 's/.*"rcode":"\([^"]*\)".*/\1/p')
	P_RTT=$(printf '%s' "$P_JSON" | sed -n 's/.*"rtt_ms":\([-0-9.]*\).*/\1/p')

	[ "$_p_rc" -eq 0 ] || return 1
	P_OK=1
	return 0
}
