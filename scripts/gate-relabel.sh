#!/bin/sh
# gate-relabel.sh -- a package re-emitted under another architecture label must be the
# primary package with nothing changed but that label.
#
#   gate-relabel.sh <primary.apk> <relabelled.apk>
#
# Why this exists: r4 declared bash on aarch64_generic and x86_64 and NOT on
# aarch64_cortex-a53, the label every GL.iNet MediaTek router installs. The relabel was
# a second `apk mkpkg` call with its own copy of the depends string, the fix had edited
# only the first, and CI installed only the primary. Found on a router on 2026-09-15.
#
# The comparison is of the two package databases (`apk adbdump`) with three lines taken
# out: the arch itself, the content hash (it covers the arch) and the block size (it
# follows the length of the arch string). Everything else has to be byte-identical.
#
# Exit 0: identical apart from the label.  Exit 1: they differ, and the diff is printed.
# Exit 2: nothing was measured (a file is missing), which is not a pass.
set -u
# The binding gate asks every gate which checks it runs; this one runs exactly one.
[ "${1:-}" = "--selftest" ] && { echo check_relabel_identical; exit 0; }
A=${1:?usage: gate-relabel.sh <primary.apk> <relabelled.apk>}
B=${2:?usage: gate-relabel.sh <primary.apk> <relabelled.apk>}
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}

for f in "$A" "$B"; do
	[ -s "$f" ] || { echo "gate-relabel: measured nothing: $f is missing or empty" >&2; exit 2; }
done
# docker wants absolute paths for bind mounts; a relative one is read as a volume name.
A=$(cd "$(dirname "$A")" && pwd)/$(basename "$A")
B=$(cd "$(dirname "$B")" && pwd)/$(basename "$B")

docker run --rm -i -v "$A:/a.apk:ro" -v "$B:/b.apk:ro" "$ALPINE" sh -c '
	strip() { apk adbdump "$1" | grep -v "^  arch:\|^  hashes:\|^# ADB block"; }
	strip /a.apk > /tmp/a || exit 2
	strip /b.apk > /tmp/b || exit 2
	[ -s /tmp/a ] || { echo "gate-relabel: measured nothing: adbdump printed nothing" >&2; exit 2; }
	if cmp -s /tmp/a /tmp/b; then
		echo "gate-relabel: identical apart from the label ($(grep -c . /tmp/a) lines compared)"
	else
		echo "gate-relabel: FAIL: the relabelled package differs from the primary beyond its arch:" >&2
		diff /tmp/a /tmp/b | head -20 >&2
		exit 1
	fi'
