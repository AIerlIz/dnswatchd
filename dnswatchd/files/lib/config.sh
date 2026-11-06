#!/bin/sh
# SPDX-License-Identifier: MIT
#
# dnswatchd - configuration loading and upstream collection.
#
# load_config() is fatal on purpose: a bad global option means we refuse to run,
# and refusing to run is safe because the servers-file is left exactly as it is.
# A bad *individual* upstream is skipped with an error instead, so one typo does
# not take the whole watchdog down.

: "${DNSWATCHD_LIB:=/usr/lib/dnswatchd}"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/common.sh"

load_config() {
	CFG_ENABLED=0

	config_load dnswatchd 2>/dev/null || {
		err "cannot read /etc/config/dnswatchd"
		return 1
	}

	config_get_bool CFG_ENABLED main enabled 0
	[ "$CFG_ENABLED" = "1" ] || return 1

	config_get INTERVAL           main interval            30
	config_get PROBE_DEADLINE     main probe_deadline      2000
	config_get FAIL_TH            main fail_threshold      2
	config_get RECOVER_TH         main recover_threshold   2
	config_get SERVERS_FILE       main servers_file        "$ETC_DIR/servers"
	config_get_bool DRY_RUN       main dry_run             0
	config_get_bool USE_SYSLOG    main syslog              1
	config_get_bool VERBOSE       main verbose             0
	config_get SELECTION          main selection           priority
	config_get LATENCY_MARGIN     main latency_margin      20
	config_get LATENCY_SWITCH_AFTER main latency_switch_after 2
	config_get ROUND_BUDGET_PCT   main round_budget        80

	# 0.1.x used `timeout` in whole seconds; carry it over when the new key is
	# absent so an existing config keeps its intent.
	if [ "$PROBE_DEADLINE" = "2000" ]; then
		config_get _legacy_timeout main timeout ""
		if is_uint "$_legacy_timeout" && [ "$_legacy_timeout" -ge 1 ]; then
			PROBE_DEADLINE=$((_legacy_timeout * 1000))
		fi
	fi

	# ---------------------------------------------------------- global sanity

	if ! is_uint "$INTERVAL"; then
		err "interval '$INTERVAL' is not a number"
		return 1
	fi
	if [ "$INTERVAL" -lt 5 ]; then
		log "interval $INTERVAL is below the 5s floor, clamping"
		INTERVAL=5
	fi

	is_uint "$PROBE_DEADLINE" || { err "probe_deadline '$PROBE_DEADLINE' is not a number"; return 1; }
	if [ "$PROBE_DEADLINE" -lt 100 ] || [ "$PROBE_DEADLINE" -gt 60000 ]; then
		err "probe_deadline must be 100..60000 ms"
		return 1
	fi

	is_uint "$FAIL_TH"    || { err "fail_threshold '$FAIL_TH' is not a number"; return 1; }
	is_uint "$RECOVER_TH" || { err "recover_threshold '$RECOVER_TH' is not a number"; return 1; }
	[ "$FAIL_TH" -ge 1 ]    || FAIL_TH=1
	[ "$RECOVER_TH" -ge 1 ] || RECOVER_TH=1

	case "$SERVERS_FILE" in
		/*) ;;
		*) err "servers_file must be an absolute path"; return 1 ;;
	esac

	case "$SELECTION" in
		priority|latency) ;;
		*)
			err "selection '$SELECTION' is not priority or latency, falling back to priority"
			SELECTION=priority
			;;
	esac

	is_uint "$LATENCY_MARGIN" || LATENCY_MARGIN=20
	[ "$LATENCY_MARGIN" -le 90 ] || { err "latency_margin capped at 90"; LATENCY_MARGIN=90; }

	is_uint "$LATENCY_SWITCH_AFTER" || LATENCY_SWITCH_AFTER=2
	[ "$LATENCY_SWITCH_AFTER" -ge 1 ] || LATENCY_SWITCH_AFTER=1
	[ "$LATENCY_SWITCH_AFTER" -le 10 ] || LATENCY_SWITCH_AFTER=10

	is_uint "$ROUND_BUDGET_PCT" || ROUND_BUDGET_PCT=80
	[ "$ROUND_BUDGET_PCT" -ge 20 ] || ROUND_BUDGET_PCT=20
	[ "$ROUND_BUDGET_PCT" -le 100 ] || ROUND_BUDGET_PCT=100

	return 0
}

# ---------------------------------------------------------------- upstreams

# Reads the IPv4 nameservers netifd wrote for this interface.
# Prints one address per line; prints nothing when the file is absent or empty.
resolv_upstreams() {
	[ -f "$RESOLV_AUTO" ] || return 0

	sed -n 's/^[[:space:]]*nameserver[[:space:]]\([0-9.][0-9.]*\)[[:space:]]*$/\1/p' \
		"$RESOLV_AUTO" 2>/dev/null | awk '!seen[$0]++' | head -2
}

_emit_upstream() {
	_pri=$1 _sec=$2 _addr=$3 _port=$4 _dom=$5 _cidr=$6 _mode=$7
	printf '%s|%s|%s|%s|%s|%s|%s\n' \
		"$_pri" "$_sec" "$_addr" "$_port" "$_dom" "$_cidr" "$_mode" >> "$_LIST"
}

_handle_upstream() {
	local section="$1"
	local enabled source address port domain cidr mode pri

	config_get_bool enabled "$section" enabled 1
	[ "$enabled" = "1" ] || return 0

	is_safe_name "$section" || {
		err "upstream section name '$section' has characters that are not allowed"
		return 0
	}

	config_get source  "$section" source       "static"
	config_get address "$section" address      ""
	config_get port    "$section" port         "53"
	config_get domain  "$section" probe_domain "www.baidu.com"
	config_get cidr    "$section" expect_cidr  ""
	config_get mode    "$section" expect_mode  ""
	config_get pri     "$section" priority     "10"

	is_uint "$pri" || { err "upstream '$section': priority '$pri' is not a number"; return 0; }
	is_port "$port" || { err "upstream '$section': port '$port' is invalid"; return 0; }
	is_domain "$domain" || { err "upstream '$section': probe_domain '$domain' is invalid"; return 0; }

	if [ -n "$cidr" ] && ! is_cidr "$cidr"; then
		err "upstream '$section': expect_cidr '$cidr' is not a CIDR"
		return 0
	fi

	# An empty expect_cidr has always meant "any answer is fine"; keep that and
	# make the rule explicit instead of implicit.
	if [ -z "$mode" ]; then
		if [ -n "$cidr" ]; then mode=in; else mode=any; fi
	fi
	if ! is_mode "$mode"; then
		err "upstream '$section': expect_mode '$mode' is not in, not-in or any"
		return 0
	fi
	if [ "$mode" = "any" ]; then
		cidr=""
	fi

	case "$source" in
		static)
			is_ipv4 "$address" || {
				err "upstream '$section': address '$address' is not an IPv4 address"
				return 0
			}
			_emit_upstream "$pri" "$section" "$address" "$port" "$domain" "$cidr" "$mode"
			;;
		resolv)
			local n=0 a
			resolv_upstreams | while read -r a; do
				n=$((n + 1))
				printf '%s|%s|%s|%s|%s|%s|%s\n' \
					"$pri" "${section}_$n" "$a" "53" "$domain" "$cidr" "$mode" \
					>> "$_LIST"
			done
			# Note: the counter runs inside a subshell, so it cannot be used
			# after the pipe; the loop above numbers entries by itself.
			;;
		*)
			err "upstream '$section': source '$source' is not static or resolv"
			;;
	esac
}

# collect_upstreams <outfile> -> prints the number of usable entries
collect_upstreams() {
	_LIST="$1"
	: > "$_LIST"

	config_foreach _handle_upstream upstream

	if [ ! -s "$_LIST" ]; then
		echo 0
		return 0
	fi

	awk 'END { print NR }' "$_LIST"
}
