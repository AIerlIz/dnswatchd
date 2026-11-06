#!/bin/sh
# SPDX-License-Identifier: MIT
#
# ipk-field.sh <file.ipk> <Field>
#
# Prints one control field from a built package, e.g.
#
#   sh scripts/ipk-field.sh dnswatchd_0.2.0-r1_x86_64.ipk Architecture
#   -> x86_64
#
# Reading the field beats parsing the filename: three of the architectures we
# publish contain an underscore (x86_64, mips_24kc, mipsel_24kc), so
# `basename | awk -F_ '{print $NF}'` silently yields "64" or "24kc".

set -u

IPK=${1:?usage: ipk-field.sh <file.ipk> <Field>}
FIELD=${2:?usage: ipk-field.sh <file.ipk> <Field>}

IPK=$(cd "$(dirname "$IPK")" && pwd)/$(basename "$IPK")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

if ar -t "$IPK" >/dev/null 2>&1; then
	( cd "$WORK" && ar -x "$IPK" ) >/dev/null 2>&1
else
	tar -xzf "$IPK" -C "$WORK" >/dev/null 2>&1
fi

for member in control.tar.gz control.tar.xz control.tar.zst; do
	[ -f "$WORK/$member" ] || continue
	case "$member" in
		*.gz) tar -xzf "$WORK/$member" -C "$WORK" ;;
		*.xz) tar -xJf "$WORK/$member" -C "$WORK" ;;
		*.zst) tar --zstd -xf "$WORK/$member" -C "$WORK" ;;
	esac
done

[ -f "$WORK/control" ] || {
	echo "ipk-field: no control file in $IPK" >&2
	exit 1
}

sed -n "s/^$FIELD:[[:space:]]*//p" "$WORK/control" | head -1
