#!/bin/sh
# build-llm-gateway.sh -- build the companion project llm-gateway, the router's own gateway to the
# model servers in the house, and put it where the runtime gate looks.
#
#   ./scripts/build-llm-gateway.sh [apk-arch]          default aarch64_generic
#   LLM_GATEWAY_SRC=/path/to/openwrt-llm-gateway ./scripts/build-llm-gateway.sh
#
# Why this exists: with hermes.main.llm_gateway on, the init pairs a client named hermes with
# llm-gateway through that program's own command line (`client list`, `client add`, `client
# remove`) and reads the key from what `client add` prints. A stand-in would only repeat what this
# repository believes the program prints, so the runtime gate runs the real one: the binary built
# from the checkout named by LLM_GATEWAY_SRC (default: the sibling directory), beside that
# repository's own /etc/config/llm-gateway. Not an apk: hermes-agent does not depend on it, the
# option is the owner's choice, and the gate installs what a test needs and takes it away after.
# The Go binary is cross-compiled on the host, as that repository's mkapk.sh is handed one;
# nothing is installed: only `go` is used, which build-openwrt-mcp.sh already needs.
#
# Static, CGO_ENABLED=0: the rootfs is musl, and Go's own os/user is what finds the program's account
# in /etc/passwd. Only the commit below is built, the one CI checks out; ANY_COMMIT=1 builds another
# by hand, for a look at a change of that repository.
set -eu

LLM_GATEWAY_COMMIT=6f623c4415100709e47c81bacbdebdfd04178f52

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${1:-aarch64_generic}
RELEASE=${RELEASE:-25.12}
SRC=${LLM_GATEWAY_SRC:-$ROOT/../openwrt-llm-gateway}
OUT="$ROOT/build/$RELEASE/$ARCH-llm-gateway"

[ -f "$SRC/main.go" ] && [ -f "$SRC/files/etc/config/llm-gateway" ] || {
	echo "build-llm-gateway: no openwrt-llm-gateway checkout at $SRC (set LLM_GATEWAY_SRC)" >&2; exit 1; }

case "$ARCH" in
	x86_64) GOARCH=amd64 ;;
	aarch64_*) GOARCH=arm64 ;;
	*) echo "build-llm-gateway: unknown apk architecture $ARCH" >&2; exit 1 ;;
esac

HEAD=$(cd "$SRC" && git rev-parse HEAD 2>/dev/null || echo unknown)
[ "$HEAD" = "$LLM_GATEWAY_COMMIT" ] || [ -n "${ANY_COMMIT:-}" ] || {
	echo "build-llm-gateway: $SRC is at $HEAD, and this repository is tested against $LLM_GATEWAY_COMMIT" >&2; exit 1; }
COMMIT=$(cd "$SRC" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
rm -rf "$OUT"
mkdir -p "$OUT"
(cd "$SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH go build -trimpath -ldflags="-s -w -X main.version=$COMMIT" -o "$OUT/llm-gateway" .)
cp "$SRC/files/etc/config/llm-gateway" "$OUT/llm-gateway.config"
echo "$COMMIT" > "$OUT/commit"
echo "==> $OUT/llm-gateway  (openwrt-llm-gateway at $COMMIT)"
