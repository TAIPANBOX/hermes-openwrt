#!/bin/sh
# gate-apk-owner.sh -- every file in every package this repository builds is root's.
#
# apk mkpkg records each file's owner as it finds it on disk. A tree owned by the CI runner's
# uid 1001 became files owned by `nobody` on the router, /etc/hermes-agent and its key files
# included (2026-10-02). Packages built on a Mac never show it, because Docker Desktop presents
# a bind mount as root, so this reads the packages themselves rather than trusting the host.
#
#   scripts/gate-apk-owner.sh [package.apk ...]   (default: the built packages in the tree)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
if [ $# -eq 0 ]; then
	set -- $(ls "$ROOT"/build/*/*/hermes-agent-[0-9]*.apk "$ROOT"/build/*/*/hermes-agent-telegram-*.apk \
		"$ROOT"/build/luci-app-hermes-apk/luci-app-hermes-*.apk 2>/dev/null | grep -v mutant || true)
fi
[ $# -gt 0 ] || { echo "FAIL: no package to read; measured nothing"; exit 1; }
bad=0
for apk in "$@"; do
	d=$(cd "$(dirname "$apk")" && pwd); b=$(basename "$apk")
	owners=$(docker run --rm -v "$d:/p:ro" "$ALPINE" apk adbdump "/p/$b" 2>/dev/null \
		| sed -nE 's/^ *(user|group): *//p' | sort | uniq -c)
	[ -n "$owners" ] || { echo "FAIL $b: no owner recorded at all; measured nothing"; bad=1; continue; }
	if echo "$owners" | awk '$2 != "root" { found = 1 } END { exit !found }'; then
		echo "FAIL $b: files not owned by root:"; echo "$owners" | awk '$2 != "root"'; bad=1
	else
		echo "PASS $b: $(echo "$owners" | awk '{ n += $1 } END { print n }') owner entries, all root"
	fi
done
[ "$bad" = 0 ] || exit 1
echo "gate-apk-owner: $# packages, every file root's"
