#!/bin/sh
# SPDX-License-Identifier: MIT
#
# dnswatchd - shared constants, logging and validation.
#
# Every path is overridable from the environment so the test harness can run
# the real scripts against a throwaway directory tree without touching /etc.

: "${DNSWATCHD_STATE_DIR:=/var/run/dnswatchd}"
: "${DNSWATCHD_ETC_DIR:=/etc/dnswatchd}"
: "${DNSWATCHD_PROBE:=/usr/libexec/dnswatchd/probe}"
: "${DNSWATCHD_DNSMASQ_INIT:=/etc/init.d/dnsmasq}"
: "${DNSWATCHD_RESOLV_AUTO:=/tmp/resolv.conf.d/resolv.conf.auto}"

STATE_DIR="$DNSWATCHD_STATE_DIR"
ETC_DIR="$DNSWATCHD_ETC_DIR"
PROBE_BIN="$DNSWATCHD_PROBE"
DNSMASQ_INIT="$DNSWATCHD_DNSMASQ_INIT"
RESOLV_AUTO="$DNSWATCHD_RESOLV_AUTO"

BACKUP_DIR="$ETC_DIR/backup"
MARKER="$ETC_DIR/takenover"

PROG=dnswatchd
LOG_TAG=dnswatchd

# Filled by load_config; these defaults also apply to `status`/`probe` when the
# daemon is not configured yet.
INTERVAL=30
PROBE_DEADLINE=2000
FAIL_TH=2
RECOVER_TH=2
SERVERS_FILE="$ETC_DIR/servers"
SELECTION=priority
LATENCY_MARGIN=20
LATENCY_SWITCH_AFTER=2
ROUND_BUDGET_PCT=80
DRY_RUN=0
USE_SYSLOG=1
VERBOSE=0
CFG_ENABLED=0

VERSION="0.2.0"

log() {
	# `--` matters: a message may start with '-', which busybox logger would
	# otherwise parse as an option.
	[ "$USE_SYSLOG" = "1" ] && logger -t "$LOG_TAG" -- "$*" 2>/dev/null
	[ "$VERBOSE" = "1" ] && printf '%s %s\n' "$(date '+%F %T')" "$*" >&2
	return 0
}

# Errors bypass `verbose` on purpose: a configuration mistake that only reaches
# syslog is invisible in exactly the moment someone needs to see it. stdout stays
# clean so rpcd's JSON replies are never polluted.
err() {
	[ "$USE_SYSLOG" = "1" ] && logger -t "$LOG_TAG" -- "ERROR: $*" 2>/dev/null
	printf '%s ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
	return 0
}

die() {
	err "$*"
	exit 1
}

# stdout-only helpers: these must never log, so they stay usable from rpcd.
say() {
	printf '%s\n' "$*"
}

# ---------------------------------------------------------------- validation

is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

is_ipv4() {
	case "$1" in
		'') return 1 ;;
		*[!0-9.]*) return 1 ;;
	esac
	_old_ifs=$IFS
	IFS=.
	# shellcheck disable=SC2086
	set -- $1
	IFS=$_old_ifs
	[ $# -eq 4 ] || return 1
	for _o in "$@"; do
		is_uint "$_o" || return 1
		[ "$_o" -le 255 ] || return 1
	done
	return 0
}

# a.b.c.d/n with a dotted-quad network and a 0..32 prefix.
is_cidr() {
	case "$1" in
		*/*) ;;
		*) return 1 ;;
	esac
	_net=${1%%/*}
	_pfx=${1##*/}
	is_ipv4 "$_net" || return 1
	is_uint "$_pfx" || return 1
	[ "$_pfx" -le 32 ] || return 1
	return 0
}

is_port() {
	is_uint "$1" || return 1
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_mode() {
	case "$1" in
		in|not-in|any) return 0 ;;
	esac
	return 1
}

# A UCI section name becomes a path component, so keep it boring.
is_safe_name() {
	case "$1" in
		''|*[!A-Za-z0-9_.-]*) return 1 ;;
	esac
	case "$1" in
		.*|*..*) return 1 ;;
	esac
	return 0
}

# probe_domain is passed to the probe binary, which validates it again; this
# only rejects the obviously broken so the error message is friendlier.
is_domain() {
	case "$1" in
		''|*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}

ensure_state_dir() {
	mkdir -p "$STATE_DIR" 2>/dev/null || true
}

ensure_etc_dir() {
	mkdir -p "$ETC_DIR" 2>/dev/null || true
}
