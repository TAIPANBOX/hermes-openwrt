#!/bin/sh
# teeth-apk-owner.sh -- gate-apk-owner.sh goes red on the package CI used to make.
#
# A tree owned by uid 1001, as a Linux runner leaves it, packaged by plain `apk mkpkg` must be
# refused; the same tree through mkpkg-root.sh must pass and be handed back to 1001. Built in
# the container's own filesystem: a Docker Desktop bind mount ignores chown, so a tree there
# would be root's whatever this asked for, and the red would never be seen on a Mac.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
back=$(docker run --rm -v "$OUT:/out" -v "$ROOT/scripts/mkpkg-root.sh:/mkpkg-root:ro" "$ALPINE" sh -c '
mk() { rm -rf /w; mkdir -p /w/tree/etc/hermes-agent && echo k > /w/tree/etc/hermes-agent/provider.key && chown -R 1001:1001 /w/tree; }
mk; apk mkpkg --info name:t --info version:1-r0 --info arch:noarch --files /w/tree --output /out/plain.apk >/dev/null
mk; OWN=1001:1001 sh /mkpkg-root --info name:t --info version:1-r0 --info arch:noarch --files /w/tree --output /out/root.apk >/dev/null
stat -c %u:%g /w/tree/etc/hermes-agent/provider.key; chmod 644 /out/*.apk')
if "$ROOT/scripts/gate-apk-owner.sh" "$OUT/plain.apk" >"$OUT/log" 2>&1; then
	echo "TEETH FAIL: a package of a uid 1001 tree passed"; cat "$OUT/log"; exit 1; fi
grep -q 'not owned by root' "$OUT/log" || { echo "TEETH FAIL: red, but not for the owner"; cat "$OUT/log"; exit 1; }
echo "teeth ok: plain mkpkg of a uid 1001 tree -> not owned by root"
"$ROOT/scripts/gate-apk-owner.sh" "$OUT/root.apk" >"$OUT/log" 2>&1 || { echo "TEETH FAIL: mkpkg-root's package was refused"; cat "$OUT/log"; exit 1; }
[ "$back" = 1001:1001 ] || { echo "TEETH FAIL: mkpkg-root left the tree $back, not handed back to 1001:1001"; exit 1; }
echo "teeth ok: the same tree through mkpkg-root -> root's, and handed back to 1001:1001"
