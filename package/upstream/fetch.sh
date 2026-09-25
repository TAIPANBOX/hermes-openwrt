#!/bin/sh
# Fetch the pinned upstream Hermes archive into build/upstream/ and verify it.
#
# Prints the path of the verified archive on stdout. Runs on the build host, not in a
# container: the rootfs images have no curl, and the archive is mounted into them.
#
# Why api.github.com and not the /archive/ URL
#
# Two different archives exist for one commit. /archive/<sha>.tar.gz serves the
# "tar.gz" flavour (top directory hermes-agent-<full sha>); api.github.com's tarball
# endpoint serves the "legacy" flavour (top directory NousResearch-hermes-agent-<short
# sha>). Their bytes differ, so their checksums differ, and the pin in upstream.env is of
# the legacy one. Measured 2026-09-25: the API endpoint returned the pinned bytes with
# and without a token, while codeload.github.com answered this machine 429 both ways.
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SRC/../.." && pwd)
. "$SRC/upstream.env"

CACHE="$ROOT/build/upstream"
OUT="$CACHE/hermes-agent-$HERMES_COMMIT.tar.gz"
mkdir -p "$CACHE"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [ -f "$OUT" ] && [ "$(sha256 "$OUT")" = "$HERMES_TARBALL_SHA256" ]; then
	echo "$OUT"
	exit 0
fi

URL="https://api.github.com/repos/NousResearch/hermes-agent/tarball/$HERMES_COMMIT"
TMP="$OUT.part"
rm -f "$TMP"
# A token only raises the rate limit; the archive is public. CI has GITHUB_TOKEN.
TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
if [ -n "$TOKEN" ]; then
	curl -sSfL --retry 4 --retry-delay 5 -H "Authorization: Bearer $TOKEN" -o "$TMP" "$URL"
else
	curl -sSfL --retry 4 --retry-delay 5 -o "$TMP" "$URL"
fi

got=$(sha256 "$TMP")
if [ "$got" != "$HERMES_TARBALL_SHA256" ]; then
	echo "fetch.sh: upstream archive for $HERMES_COMMIT has sha256 $got" >&2
	echo "fetch.sh: upstream.env pins $HERMES_TARBALL_SHA256. Refusing to build from it." >&2
	rm -f "$TMP"
	exit 1
fi
mv "$TMP" "$OUT"
echo "$OUT"
