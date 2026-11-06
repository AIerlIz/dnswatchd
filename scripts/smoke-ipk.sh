#!/bin/sh
# SPDX-License-Identifier: MIT
#
# smoke-ipk.sh <file.ipk> [expected-package-name]
#
# Checks a built package without installing it: unpack, verify the file list and
# modes, syntax-check every installed script, and — when the package happens to
# be the host architecture — actually run the packaged CLI and probe.
#
# This is what catches the class of mistake the old CI could not see: a package
# that builds fine but ships a file in the wrong place, or a script that installs
# without the +x bit.

set -u

IPK=${1:?usage: smoke-ipk.sh <file.ipk> [package]}
EXPECT=${2:-dnswatchd}

# Absolute path, so the unpack below can cd freely.
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

for member in data.tar.gz data.tar.xz data.tar.zst; do
	[ -f "$WORK/$member" ] || continue
	mkdir -p "$WORK/data"
	case "$member" in
		*.gz) tar -xzf "$WORK/$member" -C "$WORK/data" ;;
		*.xz) tar -xJf "$WORK/$member" -C "$WORK/data" ;;
		*.zst) tar --zstd -xf "$WORK/$member" -C "$WORK/data" ;;
	esac
done

fail=0
note() { printf '  %-52s %s\n' "$1" "$2"; }
check() {
	if [ "$2" = "$3" ]; then
		note "$1" "ok"
	else
		note "$1" "FAIL (want '$3', got '$2')"
		fail=$((fail + 1))
	fi
}

echo "== $IPK"

[ -f "$WORK/control" ] || { echo "no control file" >&2; exit 1; }
[ -d "$WORK/data" ] || { echo "no data archive" >&2; exit 1; }

field() { sed -n "s/^$1:[[:space:]]*//p" "$WORK/control" | head -1; }

check "package name" "$(field Package)" "$EXPECT"
ARCH=$(field Architecture)
# The core package ships a compiled probe, so it must be architecture specific.
# The LuCI package is JavaScript plus translations and is correctly arch=all.
if [ "$EXPECT" = "dnswatchd" ]; then
	check "architecture is not 'all'" "$([ "$ARCH" = "all" ] && echo all || echo specific)" "specific"
fi
note "architecture" "$ARCH"
note "version" "$(field Version)"
note "depends" "$(field Depends)"

ROOT="$WORK/data"

if [ "$EXPECT" = "dnswatchd" ]; then
	FILES="usr/sbin/dnswatchd
usr/libexec/dnswatchd/probe
usr/libexec/rpcd/dnswatchd
usr/lib/dnswatchd/common.sh
usr/lib/dnswatchd/config.sh
usr/lib/dnswatchd/state.sh
usr/lib/dnswatchd/probe.sh
usr/lib/dnswatchd/apply.sh
usr/lib/dnswatchd/select.sh
usr/lib/dnswatchd/takeover.sh
etc/init.d/dnswatchd
etc/config/dnswatchd
etc/uci-defaults/90-dnswatchd"

	EXECUTABLES="usr/sbin/dnswatchd
usr/libexec/dnswatchd/probe
usr/libexec/rpcd/dnswatchd
etc/init.d/dnswatchd
etc/uci-defaults/90-dnswatchd"

	SCRIPTS="$ROOT/usr/sbin/dnswatchd $ROOT/usr/libexec/rpcd/dnswatchd"
	SCRIPTS="$SCRIPTS $ROOT/usr/lib/dnswatchd/common.sh $ROOT/usr/lib/dnswatchd/config.sh"
	SCRIPTS="$SCRIPTS $ROOT/usr/lib/dnswatchd/state.sh $ROOT/usr/lib/dnswatchd/probe.sh"
	SCRIPTS="$SCRIPTS $ROOT/usr/lib/dnswatchd/apply.sh $ROOT/usr/lib/dnswatchd/select.sh"
	SCRIPTS="$SCRIPTS $ROOT/usr/lib/dnswatchd/takeover.sh"
	SCRIPTS="$SCRIPTS $ROOT/etc/init.d/dnswatchd $ROOT/etc/uci-defaults/90-dnswatchd"
else
	FILES="www/luci-static/resources/view/dnswatchd/main.js
usr/share/luci/menu.d/luci-app-dnswatchd.json
usr/share/rpcd/acl.d/luci-app-dnswatchd.json"
	EXECUTABLES=""
	SCRIPTS=""
fi

for f in $FILES; do
	[ -f "$ROOT/$f" ] || { note "missing /$f" "FAIL"; fail=$((fail + 1)); }
done

for f in $EXECUTABLES; do
	[ -x "$ROOT/$f" ] && note "executable /$f" "ok" ||
		{ note "executable /$f" "FAIL"; fail=$((fail + 1)); }
done

if [ "$EXPECT" = "dnswatchd" ]; then
	check "conffiles protects the config" \
		"$(sed -n 's|^/etc/config/dnswatchd$|yes|p' "$WORK/conffiles" 2>/dev/null)" "yes"
fi

# Informational: prove (or disprove) that luci.mk picked the po files up.
if [ "$EXPECT" != "dnswatchd" ]; then
	LMO=$(find "$ROOT/usr/lib/lua/luci/i18n" -name '*.lmo' 2>/dev/null | head -3 | tr '\n' ' ')
	note "translation catalogues" "${LMO:-none found}"
fi

for f in $SCRIPTS; do
	[ -f "$f" ] || continue
	sh -n "$f" 2>/dev/null || { note "syntax $(basename "$f")" "FAIL"; fail=$((fail + 1)); }
done
[ -n "$SCRIPTS" ] && note "installed scripts parse" "ok"

# The probe must be statically linked: a dynamic binary would pin the package to
# one libc version and defeat the single-build-for-three-releases plan.
if command -v file >/dev/null 2>&1 && [ "$EXPECT" = "dnswatchd" ]; then
	if file "$ROOT/usr/libexec/dnswatchd/probe" | grep -q 'statically linked'; then
		note "probe is statically linked" "ok"
	else
		note "probe is statically linked" "FAIL"
		fail=$((fail + 1))
	fi
fi

# Execute the artifact when we can actually run it.
case "$ARCH" in
	x86_64|i386_*|i686)
		if [ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "i686" ]; then
			"$ROOT/usr/libexec/dnswatchd/probe" -s 127.0.0.1 -p 9 -d example.test -t 200 \
				>/dev/null 2>&1
			rc=$?
			check "packaged probe runs (exit 1 = no reply)" "$rc" "1"

			out=$(DNSWATCHD_LIB="$ROOT/usr/lib/dnswatchd" \
			      DNSWATCHD_STATE_DIR="$WORK/run" \
			      DNSWATCHD_ETC_DIR="$WORK/etc" \
			      DNSWATCHD_PROBE="$ROOT/usr/libexec/dnswatchd/probe" \
			      DNSWATCHD_FUNCTIONS=/dev/null \
			      DNSWATCHD_TEST_CONFIG=/dev/null \
			      sh "$ROOT/usr/sbin/dnswatchd" status --json 2>/dev/null)

			case "$out" in
				\{*\}*) note "packaged status --json speaks JSON" "ok" ;;
				*) note "packaged status --json speaks JSON" "FAIL"; fail=$((fail + 1)) ;;
			esac
		fi
		;;
	*)
		note "executing foreign architecture" "skipped"
		;;
esac

echo
if [ "$fail" -eq 0 ]; then
	echo "smoke: OK"
	exit 0
fi

echo "smoke: $fail failure(s)"
exit 1
