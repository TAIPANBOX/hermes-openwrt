#!/bin/sh
# Build the hermes-agent-telegram package inside the OpenWrt release it targets.
#
# Same two-container shape as the base package, and for the same reasons:
#
#   openwrt/rootfs:<arch>-<release>   assembles the tree, so pip resolves against the
#                                     router's own CPython and musl.
#   alpine:edge                       writes the package. OpenWrt's rootfs ships
#                                     apk-tools without mkpkg, and macOS ships BSD tar,
#                                     which has neither --sort nor --mtime.
#
# One thing this build needs that the base build does not: the assembled base tree. The
# add-on installs into the base package's private site-packages, and two OpenWrt
# packages owning one file is an error that only appears on a router with both halves
# installed. So the collision check runs here, against the real tree, every time.
set -eu

ARCH=${1:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
case "$RELEASE" in
	24.10*) FORMAT=ipk ;;
	*)      FORMAT=apk ;;
esac
HERMES_VERSION=${HERMES_VERSION:-0.19.0}
PKGREL=${PKGREL:-1}
# Must match the base package's own PKGREL when the two are published together, because
# the dependency below is expressed against the upstream version rather than this.
BASE_PKGREL=${BASE_PKGREL:-2}

SRC=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SRC/../.." && pwd)
LINE=${RELEASE%%.*}.$(echo "$RELEASE" | cut -d. -f2)
# Keyed by release line, architecture AND package, and deliberately BESIDE the base
# package's directory rather than inside it.
#
# This is the third work-directory collision in this repository. The first two shipped
# wrong bytes: a directory shared between two release lines, and one shared between two
# package formats. This one was caught before it shipped anything, by reading the base
# script rather than by a failure: package/hermes-agent/build-in-container.sh opens with
# `rm -rf "$WORK"` on exactly $ROOT/build/$LINE/$ARCH, so a telegram tree kept under it
# lives only until the next base build, and the EXTRA_ARCHES loop does the same to the
# relabelled directories. Beside it, not under it.
WORK="$ROOT/build/$LINE/$ARCH-telegram"
BASE_TREE="$ROOT/build/$LINE/$ARCH/tree"

case "$ARCH" in
	x86_64) IMAGE="openwrt/rootfs:x86-64-$RELEASE" ;;
	*)      IMAGE="openwrt/rootfs:$ARCH-$RELEASE" ;;
esac
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
PKG=hermes-agent-telegram
OUT="$PKG-$HERMES_VERSION-r$PKGREL.apk"

if [ ! -d "$BASE_TREE" ]; then
	echo "$0: no base tree at $BASE_TREE" >&2
	echo "$0: the collision check needs it. Build the base package first:" >&2
	echo "$0:   RELEASE=$RELEASE ./package/hermes-agent/build-in-container.sh $ARCH" >&2
	exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> assembling the telegram tree inside $IMAGE"
docker run --rm -i --platform "linux/$ARCH" \
	-v "$SRC:/src:ro" -v "$WORK:/work" -v "$BASE_TREE:/base:ro" \
	"$IMAGE" /bin/sh -s <<CONTAINER
set -eu
mkdir -p /var/lock /var/run /var/state
if command -v apk >/dev/null 2>&1; then
	apk update -q
	apk add -q python3 python3-pip
else
	opkg update >/dev/null
	opkg install python3 python3-pip >/dev/null
fi
HERMES_VERSION=$HERMES_VERSION EXTRAS="${EXTRAS:-cron,mcp}" \\
	/src/build.sh "$ARCH" /work/tree /base
CONTAINER

# Root-owned inside the container. Harmless on Docker Desktop, a "Permission denied" on
# a Linux CI runner for anything that touches the tree afterwards.
docker run --rm -i --platform "linux/$ARCH" -v "$WORK:/work" "$IMAGE" \
	chown -R "$(id -u):$(id -g)" /work 2>/dev/null || true

if [ "$FORMAT" = ipk ]; then
	echo "==> packaging with mkipk.sh (opkg, $RELEASE)"
	docker run --rm -i -v "$SRC:/src:ro" -v "$WORK:/work" -v "$ROOT:/out" \
		-e HERMES_VERSION="$HERMES_VERSION" -e PKGREL="$PKGREL" -e DEST=/out \
		"$ALPINE" sh -c "apk add -q --no-cache tar >/dev/null 2>&1; /src/mkipk.sh /work/tree '$ARCH' '$HERMES_VERSION'"
	cp "$ROOT"/${PKG}_*_"$ARCH".ipk "$WORK/" 2>/dev/null || true
	for extra in ${EXTRA_ARCHES:-}; do
		docker run --rm -i -v "$SRC:/src:ro" -v "$WORK:/work" -v "$ROOT:/out" \
			-e HERMES_VERSION="$HERMES_VERSION" -e PKGREL="$PKGREL" -e DEST=/out \
			"$ALPINE" sh -c "apk add -q --no-cache tar >/dev/null 2>&1; /src/mkipk.sh /work/tree '$extra' '$HERMES_VERSION'"
		echo "==> also $extra"
	done
	exit 0
fi

echo "==> packaging with apk mkpkg"

# The dependency is expressed as a RANGE on the upstream version, not an exact pin.
#
# What this package ships was computed by subtracting hermes-agent 0.19.0's dependency
# closure from that same closure plus Telegram. Any 0.19.0-rN base has that closure, so
# pinning the packaging revision too would break the add-on on every base rebuild for no
# gain. A different upstream version is a different closure and genuinely must not be
# mixed, which is what the upper bound says.
DEPENDS="hermes-agent>=$HERMES_VERSION hermes-agent<$(echo "$HERMES_VERSION" | awk -F. '{print $1"."$2"."$3+1}')"

mkpkg_for() {
	arch=$1; dest=$2
	docker run --rm -i -v "$WORK:/work" -v "$dest:/out" -w /work "$ALPINE" apk mkpkg \
		--info "name:$PKG" \
		--info "version:$HERMES_VERSION-r$PKGREL" \
		--info "arch:$arch" \
		--info "license:MIT" \
		--info "origin:$PKG" \
		--info "url:https://github.com/TAIPANBOX/hermes-openwrt" \
		--info "description:Telegram platform for Hermes Agent on OpenWrt. Adds the python-telegram-bot client library to the hermes-agent package, whose Telegram adapter is already present but cannot load without it." \
		--info "depends:$DEPENDS" \
		--files /work/tree \
		--output "/out/$OUT"
}

mkpkg_for "$ARCH" "$WORK"
cp "$WORK/$OUT" "$ROOT/$OUT"
echo "==> $OUT  ($(du -h "$ROOT/$OUT" | cut -f1))"

# Relabelling, honest here for the same reason it is honest for the base package: the
# payload is one pure-python wheel and one stable-ABI musllinux aarch64 wheel, and the
# two architecture names differ only in compiler tuning of code this package does not
# contain. OpenWrt publishes no aarch64_cortex-a53 rootfs to build inside.
for extra in ${EXTRA_ARCHES:-}; do
	xdir="$ROOT/build/$LINE/$extra-telegram"
	rm -rf "$xdir"; mkdir -p "$xdir"
	mkpkg_for "$extra" "$xdir"
	echo "==> also $extra: $OUT"
done
