#!/bin/sh
# SPDX-License-Identifier: MIT
#
# dnswatchd - taking DNS over, and giving it back.
#
# Installing the package changes nothing. `takeover` is the only code path that
# touches /etc/config/dhcp, it writes a complete backup first, and `rollback`
# puts the original values back. Both are idempotent.
#
# What takeover actually does, in this order, so DNS never has no upstream:
#   1. back up the dhcp config and the exact values we are about to change
#   2. write the servers-file (still nobody reads it, harmless)
#   3. clear `list server` and point dnsmasq at the servers-file
#   4. set noresolv=1 — without this, resolv.conf.auto keeps the ISP resolvers
#      in dnsmasq's candidate pool and the "one upstream" invariant is a lie
#   5. add the `isp` upstream so the ISP resolvers stay available as a real,
#      probeable, lowest-priority fallback instead of an invisible one
#   6. reload dnsmasq
#
# Note the ordering: 3 and 4 only become visible after 6, and by then the file
# in step 2 is already correct.

: "${DNSWATCHD_LIB:=/usr/lib/dnswatchd}"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/common.sh"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/apply.sh"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/config.sh"

TAKEOVER_MSG=""

_uci_get() { uci -q get "$1" 2>/dev/null; }
_uci_has() { uci -q get "$1" >/dev/null 2>&1; }

# First usable upstream currently configured in dhcp, as addr[#port].
_existing_server() {
	_ex=""
	_i=0
	while [ "$_i" -lt 8 ]; do
		_v=$(_uci_get "dhcp.@dnsmasq[0].server[$_i]")
		[ -n "$_v" ] || break
		_i=$((_i + 1))
		case "${_v%%#*}" in
			127.*|::1|0.0.0.0|'') continue ;;
		esac
		_ex=$_v
		break
	done

	# Fall back to `uci get` on images where indexed access is unsupported.
	if [ -z "$_ex" ]; then
		_ex=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | head -1)
		case "${_ex%%#*}" in
			127.*|::1|0.0.0.0) _ex="" ;;
		esac
	fi

	printf '%s\n' "$_ex"
}

takeover() {
	TAKEOVER_MSG=""

	command -v uci >/dev/null 2>&1 || {
		TAKEOVER_MSG="uci not found"
		err "$TAKEOVER_MSG"
		return 1
	}

	if [ -f "$MARKER" ]; then
		TAKEOVER_MSG="already managing dnsmasq (marker $MARKER)"
		log "$TAKEOVER_MSG"
		return 0
	fi

	_cur_sf=$(_uci_get dhcp.@dnsmasq[0].serversfile)
	if [ -n "$_cur_sf" ] && [ "$_cur_sf" != "$SERVERS_FILE" ]; then
		TAKEOVER_MSG="dhcp.@dnsmasq[0].serversfile is already set to '$_cur_sf'; refusing to take over"
		err "$TAKEOVER_MSG"
		return 1
	fi

	# ------------------------------------------------------------- backup
	ensure_etc_dir
	_ts=$(date '+%Y%m%d-%H%M%S')
	_bak="$BACKUP_DIR/$_ts"
	mkdir -p "$_bak" 2>/dev/null || {
		TAKEOVER_MSG="cannot create backup directory $_bak"
		err "$TAKEOVER_MSG"
		return 1
	}

	uci export dhcp > "$_bak/dhcp.export" 2>/dev/null
	uci export dnswatchd > "$_bak/dnswatchd.export" 2>/dev/null

	{
		printf 'serversfile_set=%s\n' "$(_uci_has dhcp.@dnsmasq[0].serversfile && echo 1 || echo 0)"
		printf 'serversfile=%s\n' "$_cur_sf"
		printf 'noresolv_set=%s\n' "$(_uci_has dhcp.@dnsmasq[0].noresolv && echo 1 || echo 0)"
		printf 'noresolv=%s\n' "$(_uci_get dhcp.@dnsmasq[0].noresolv)"
	} > "$_bak/meta"

	: > "$_bak/servers.list"
	_i=0
	while [ "$_i" -lt 32 ]; do
		_v=$(_uci_get "dhcp.@dnsmasq[0].server[$_i]")
		[ -n "$_v" ] || break
		printf '%s\n' "$_v" >> "$_bak/servers.list"
		_i=$((_i + 1))
	done

	# ------------------------------------------------------------- seed
	_first=$(_existing_server)
	if [ -z "$_first" ]; then
		_first=$(resolv_upstreams 2>/dev/null | head -1)
		log "no configured dnsmasq upstream; seeding from resolv.conf.auto"
	fi
	if [ -z "$_first" ]; then
		_first="223.5.5.5"
		log "no usable upstream at all; seeding with 223.5.5.5"
	fi

	_first_addr=${_first%%#*}
	_first_port=53
	case "$_first" in
		*\#*) _first_port=${_first##*#} ;;
	esac
	is_port "$_first_port" || _first_port=53

	if ! write_servers_file "$_first_addr" "$_first_port"; then
		TAKEOVER_MSG="could not write $SERVERS_FILE; dhcp config left untouched"
		err "$TAKEOVER_MSG"
		return 1
	fi

	# ------------------------------------------------------------- switch
	while uci -q delete dhcp.@dnsmasq[0].server; do :; done
	uci -q set "dhcp.@dnsmasq[0].serversfile=$SERVERS_FILE"
	uci -q set "dhcp.@dnsmasq[0].noresolv=1"

	if ! uci -q commit dhcp; then
		TAKEOVER_MSG="uci commit dhcp failed; run 'dnswatchd rollback --from $_ts'"
		err "$TAKEOVER_MSG"
		return 1
	fi

	# ------------------------------------------------------------- isp
	if ! _uci_has dnswatchd.isp; then
		uci -q set dnswatchd.isp=upstream
		uci -q set dnswatchd.isp.enabled=1
		uci -q set dnswatchd.isp.source=resolv
		uci -q set dnswatchd.isp.probe_domain=www.baidu.com
		uci -q set dnswatchd.isp.expect_mode=any
		uci -q set dnswatchd.isp.priority=90
	fi

	uci -q set dnswatchd.main.enabled=1
	uci -q commit dnswatchd

	reload_dnsmasq || log "dnsmasq reload reported failure; check 'logread -e dnsmasq'"

	printf '%s\n' "$_ts" > "$MARKER"

	[ -x /etc/init.d/dnswatchd ] && /etc/init.d/dnswatchd start >/dev/null 2>&1

	TAKEOVER_MSG="dnsmasq is now managed by dnswatchd (backup $_bak)"
	log "$TAKEOVER_MSG"
	return 0
}

rollback() {
	TAKEOVER_MSG=""

	[ -f "$MARKER" ] || {
		TAKEOVER_MSG="dnswatchd is not managing dnsmasq; nothing to roll back"
		err "$TAKEOVER_MSG"
		return 1
	}

	_ts=$1
	[ -n "$_ts" ] || _ts=$(cat "$MARKER" 2>/dev/null)
	_bak="$BACKUP_DIR/$_ts"

	[ -d "$_bak" ] || {
		# Fall back to the newest backup we have.
		_ts=$(ls -1 "$BACKUP_DIR" 2>/dev/null | sort | tail -1)
		_bak="$BACKUP_DIR/$_ts"
	}

	[ -f "$_bak/meta" ] || {
		TAKEOVER_MSG="backup $_bak is incomplete (no meta); refusing to guess"
		err "$TAKEOVER_MSG"
		return 1
	}

	# shellcheck disable=SC1090
	. "$_bak/meta"

	if [ "${serversfile_set:-0}" = "1" ] && [ -n "${serversfile:-}" ]; then
		uci -q set "dhcp.@dnsmasq[0].serversfile=$serversfile"
	else
		uci -q delete dhcp.@dnsmasq[0].serversfile
	fi

	if [ "${noresolv_set:-0}" = "1" ]; then
		uci -q set "dhcp.@dnsmasq[0].noresolv=${noresolv:-0}"
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv
	fi

	while uci -q delete dhcp.@dnsmasq[0].server; do :; done
	if [ -f "$_bak/servers.list" ]; then
		while read -r _s; do
			[ -n "$_s" ] || continue
			uci -q add_list "dhcp.@dnsmasq[0].server=$_s"
		done < "$_bak/servers.list"
	fi

	uci -q commit dhcp

	uci -q set dnswatchd.main.enabled=0
	uci -q commit dnswatchd
	[ -x /etc/init.d/dnswatchd ] && /etc/init.d/dnswatchd stop >/dev/null 2>&1

	reload_dnsmasq || log "dnsmasq reload reported failure; restart it by hand"

	rm -f "$MARKER"

	TAKEOVER_MSG="restored dnsmasq from $_bak; dnswatchd is disabled"
	log "$TAKEOVER_MSG"
	return 0
}
