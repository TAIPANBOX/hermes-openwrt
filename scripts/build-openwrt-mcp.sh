#!/bin/sh
# build-openwrt-mcp.sh -- build the apk of the companion project, openwrt-mcp, that
# hermes-agent depends on from 0.21.5-r3, and put it where the gates and the feed look.
#
#   ./scripts/build-openwrt-mcp.sh [apk-arch]          default aarch64_generic
#   OPENWRT_MCP_SRC=/path/to/openwrt-mcp ./scripts/build-openwrt-mcp.sh
#
# Why this exists: hermes-agent in the owner profile asks openwrt-mcp for everything it
# reads and changes on the router, so the package declares it a dependency, and a gate
# that installs hermes-agent into a bare OpenWrt rootfs has to be handed that dependency
# the same way the Telegram gate is handed its add-on. The apk is built by openwrt-mcp's
# own mkapk.sh, from the checkout named by OPENWRT_MCP_SRC (default: the sibling
# directory), so what the gates install is what that repository's packaging produces.
# The Go binary is cross-compiled on the host, as that repository's Makefile does, and
# nothing is installed: only `go` and docker are used, both already needed here.
#
# The output directory is a sibling of the base package's build directory, for the same
# reason the Telegram add-on's is: the base build starts with `rm -rf` on its own.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${1:-aarch64_generic}
RELEASE=${RELEASE:-25.12}
SRC=${OPENWRT_MCP_SRC:-$ROOT/../openwrt-mcp}
OUT="$ROOT/build/$RELEASE/$ARCH-openwrt-mcp"

[ -f "$SRC/mkapk.sh" ] && [ -f "$SRC/main.go" ] || {
	echo "build-openwrt-mcp: no openwrt-mcp checkout at $SRC (set OPENWRT_MCP_SRC)" >&2; exit 1; }

case "$ARCH" in
	x86_64) GOARCH=amd64 ;;
	aarch64_*) GOARCH=arm64 ;;
	*) echo "build-openwrt-mcp: unknown apk architecture $ARCH" >&2; exit 1 ;;
esac

VERSION=$(sed -n 's/^var version = "\(.*\)"/\1/p' "$SRC/main.go")
[ -n "$VERSION" ] || { echo "build-openwrt-mcp: no version in $SRC/main.go" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
(cd "$SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH go build -ldflags="-s -w" -o "$WORK/openwrt-mcp" .)

# mkapk.sh leaves the package beside its own sources; take it from there and leave that
# checkout as it was.
APK=$(cd "$SRC" && ./mkapk.sh "$WORK/openwrt-mcp" "$VERSION" "$ARCH" | tail -n 1)
mkdir -p "$OUT"
rm -f "$OUT"/openwrt-mcp-*.apk
mv "$SRC/$APK" "$OUT/$APK"
echo "==> $OUT/$APK  (openwrt-mcp $VERSION from $(cd "$SRC" && git rev-parse --short HEAD 2>/dev/null || echo unknown))"
