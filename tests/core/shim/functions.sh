#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Minimal stand-in for OpenWrt's /lib/functions.sh, just enough for
# config_load / config_get / config_get_bool / config_foreach over a single
# UCI-style config file. Only what dnswatchd actually uses.

_TEST_CFG=${DNSWATCHD_TEST_CONFIG:-}

config_load() {
	# $1 is the package name; the file is supplied through the environment.
	[ -n "$_TEST_CFG" ] && [ -f "$_TEST_CFG" ]
}

_section_type_of() {
	awk -v want="$1" '
		$1 == "config" { n = $3; gsub(/["\047]/, "", n); if (n == want) { print $2; exit } }
	' "$_TEST_CFG"
}

config_get() {
	_var=$1
	_sec=$2
	_opt=$3
	_def=$4

	_val=$(awk -v sec="$_sec" -v opt="$_opt" '
		$1 == "config" {
			n = $3; gsub(/["\047]/, "", n)
			insec = (n == sec)
			next
		}
		insec && $1 == "option" && $2 == opt {
			v = $3
			gsub(/^["\047]|["\047]$/, "", v)
			print v
			exit
		}
	' "$_TEST_CFG")

	[ -n "$_val" ] || _val=$_def
	eval "$_var=\$_val"
	return 0
}

config_get_bool() {
	_var=$1
	_sec=$2
	_opt=$3
	_def=$4

	config_get "$_var" "$_sec" "$_opt" "$_def"

	eval "_raw=\$$_var"
	case "$_raw" in
		1|on|true|yes|enabled) _raw=1 ;;
		0|off|false|no|disabled|'') _raw=0 ;;
		*) _raw=0 ;;
	esac
	eval "$_var=\$_raw"
	return 0
}

config_list_foreach() {
	_sec=$1
	_opt=$2
	_fn=$3
	awk -v sec="$_sec" -v opt="$_opt" '
		$1 == "config" { n = $3; gsub(/["\047]/, "", n); insec = (n == sec); next }
		insec && $1 == "list" && $2 == opt { v = $3; gsub(/^["\047]|["\047]$/, "", v); print v }
	' "$_TEST_CFG" | while read -r _item; do
		[ -n "$_item" ] && "$_fn" "$_item"
	done
}

config_foreach() {
	_fn=$1
	_type=$2
	awk -v t="$_type" '
		$1 == "config" && $2 == t { n = $3; gsub(/["\047]/, "", n); print n }
	' "$_TEST_CFG" | while read -r _sec; do
		[ -n "$_sec" ] && "$_fn" "$_sec"
	done
}
