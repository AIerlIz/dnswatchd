#!/bin/sh
# SPDX-License-Identifier: MIT
#
# dnswatchd - per-upstream counter state and the round lock.
#
# State files are key=value but are NEVER sourced: a file in /var/run must not be
# able to inject shell. Every key and value is matched against a whitelist.

: "${DNSWATCHD_LIB:=/usr/lib/dnswatchd}"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/common.sh"

state_path() {
	_s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
	printf '%s/%s.state' "$STATE_DIR" "$_s"
}

# state_read <section> -> ST_FAILS ST_OKS ST_STATUS ST_RTT
state_read() {
	ST_FAILS=0
	ST_OKS=0
	ST_STATUS=unknown
	ST_RTT=""

	_f=$(state_path "$1")
	[ -f "$_f" ] || return 0

	while IFS='=' read -r _k _v; do
		case "$_k" in
			fails) is_uint "$_v" && ST_FAILS=$_v ;;
			oks)   is_uint "$_v" && ST_OKS=$_v ;;
			rtt)   case "$_v" in ''|*[!0-9.]*) ;; *) ST_RTT=$_v ;; esac ;;
			status)
				case "$_v" in
					up|down|unknown) ST_STATUS=$_v ;;
				esac
				;;
		esac
	done < "$_f"

	return 0
}

state_write() {
	_f=$(state_path "$1")
	printf 'fails=%s\noks=%s\nstatus=%s\nrtt=%s\n' \
		"$ST_FAILS" "$ST_OKS" "$ST_STATUS" "$ST_RTT" > "$_f" 2>/dev/null || {
		err "cannot write state file $_f"
		return 1
	}
	return 0
}

# ---------------------------------------------------------------- active

# The servers-file is the single source of truth for what dnsmasq was told, so
# `active` is derived from it rather than kept in a second file that can drift.
active_target() {
	[ -f "$SERVERS_FILE" ] || return 0
	sed -n 's/^server=//p' "$SERVERS_FILE" 2>/dev/null | head -1
}

active_section() {
	_list=$1
	_t=$(active_target)
	[ -n "$_t" ] || return 0

	while IFS='|' read -r _pri _sec _addr _port _rest; do
		[ -n "$_addr" ] || continue
		_cand=$_addr
		[ "$_port" != "53" ] && _cand="$_addr#$_port"
		if [ "$_cand" = "$_t" ]; then
			printf '%s\n' "$_sec"
			return 0
		fi
	done < "$_list"

	# A server line we did not write (hand-edited, or left over from an older
	# config) still counts as "something is active", just not one of ours.
	printf '%s\n' "?"
	return 0
}

# ---------------------------------------------------------------- lock

# mkdir is atomic everywhere; flock is not guaranteed to exist in every busybox.
lock_acquire() {
	_ld="$STATE_DIR/lock"

	[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null

	if mkdir "$_ld" 2>/dev/null; then
		printf '%s\n' "$$" > "$_ld/pid" 2>/dev/null
		return 0
	fi

	# A crashed run must not wedge the daemon forever.
	if [ -n "$(find "$_ld" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
		log "removing stale lock $_ld"
		rm -rf "$_ld"
		if mkdir "$_ld" 2>/dev/null; then
			printf '%s\n' "$$" > "$_ld/pid" 2>/dev/null
			return 0
		fi
	fi

	return 1
}

lock_release() {
	[ -d "$STATE_DIR/lock" ] || return 0
	_owner=$(cat "$STATE_DIR/lock/pid" 2>/dev/null)
	[ -z "$_owner" ] || [ "$_owner" = "$$" ] || return 0
	rm -rf "$STATE_DIR/lock"
	return 0
}
