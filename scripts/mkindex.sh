#!/bin/sh
# SPDX-License-Identifier: MIT
#
# mkindex.sh <directory-with-ipks>
#
# Rebuilds opkg's `Packages` index for one architecture directory.
#
# Two .ipk packings exist in the wild:
#   * classic: an ar archive (debian-binary + control.tar.gz + data.tar.gz)
#   * newer:   a plain tar.gz holding those three members
# Both are handled by trying ar first.
#
# Filename / Size / SHA256sum must be inserted BEFORE the Description field:
# opkg's control parser treats everything after Description as description text,
# even across blank lines, and then reports "does not have a valid filename
# field".

set -u

DIR=${1:-.}
# Resolve before cd: everything below refers to files by bare name, and a
# relative "$DIR" would otherwise be re-joined onto itself.
case "$DIR" in
	/*) ;;
	*) DIR="$PWD/$DIR" ;;
esac
cd "$DIR" || exit 1

: > Packages
count=0

for f in *.ipk; do
	[ -f "$f" ] || continue

	work=$(mktemp -d)

	if ar -t "$f" >/dev/null 2>&1; then
		( cd "$work" && ar -x "$DIR/$f" ) >/dev/null 2>&1
	else
		( cd "$work" && tar -xzf "$DIR/$f" ) >/dev/null 2>&1
	fi
	# $DIR is absolute by now, so this is safe either way.

	for member in control.tar.gz control.tar.xz control.tar.zst; do
		[ -f "$work/$member" ] || continue
		case "$member" in
			*.gz) tar -xzf "$work/$member" -C "$work" ;;
			*.xz) tar -xJf "$work/$member" -C "$work" ;;
			*.zst) tar --zstd -xf "$work/$member" -C "$work" ;;
		esac
	done

	if [ ! -f "$work/control" ]; then
		echo "WARNING: $f has no control file, skipping" >&2
		rm -rf "$work"
		continue
	fi

	size=$(wc -c < "$f" | tr -d ' ')
	sha=$(sha256sum "$f" | awk '{print $1}')

	awk -v f="$f" -v s="$size" -v h="$sha" '
		/^Description:/ && !done {
			print "Filename: " f
			print "Size: " s
			print "SHA256sum: " h
			done = 1
		}
		{ print }
		END {
			if (!done) {
				print "Filename: " f
				print "Size: " s
				print "SHA256sum: " h
			}
		}
	' "$work/control" >> Packages

	# A blank line separates records; the control file may lack a trailing one.
	printf '\n' >> Packages

	count=$((count + 1))
	rm -rf "$work"
done

gzip -kf Packages

echo "indexed $count package(s) in $DIR"

# An empty index used to be published with a zero exit status, which made a
# broken feed indistinguishable from a working one.
if [ "$count" -eq 0 ]; then
	echo "mkindex: no packages found in $DIR" >&2
	exit 1
fi

grep -c '^Package:' Packages
