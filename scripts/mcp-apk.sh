#!/bin/sh
# mcp-apk.sh [apk-arch] -- print the path of the openwrt-mcp apk the gates install beside
# hermes-agent, and say how to build it when there is none. OPENWRT_MCP_APK overrides.
# Sourced by nothing: the gates call it, so the lookup lives in one place.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${1:-aarch64_generic}
RELEASE=${RELEASE:-25.12}
if [ -n "${OPENWRT_MCP_APK:-}" ]; then
	[ -f "$OPENWRT_MCP_APK" ] || { echo "mcp-apk: OPENWRT_MCP_APK=$OPENWRT_MCP_APK is not a file" >&2; exit 1; }
	echo "$OPENWRT_MCP_APK"; exit 0
fi
found=$(ls -t "$ROOT/build/$RELEASE/$ARCH-openwrt-mcp"/openwrt-mcp-[0-9]*.apk 2>/dev/null | head -1 || true)
[ -n "$found" ] || {
	echo "mcp-apk: no openwrt-mcp apk for $ARCH. Build it: ./scripts/build-openwrt-mcp.sh $ARCH" >&2; exit 1; }
echo "$found"
