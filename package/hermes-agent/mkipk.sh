#!/bin/sh
# Build an opkg .ipk for OpenWrt 24.10, from a tree build.sh has already assembled.
#
# 24.10 is the other maintained line and it predates the move to apk, so it needs a
# different container format and a different index and signature scheme. Nothing about
# the payload changes: the same wheels, the same launcher, the same service. What
# changes is Python, 3.11 there against 3.13 on 25.12, which is why the tree has to be
# assembled inside a 24.10 rootfs rather than reused from the 25.12 build.
#
# The container format, and the trap in it
#
# An .ipk is three members in a fixed order: debian-binary holding the literal "2.0",
# control.tar.gz with the metadata, and data.tar.gz with the filesystem tree. Most
# documentation describes the outer container as an ar archive, identical to a .deb, and
# opkg on these targets REFUSES that form:
#
#   * pkg_init_from_file: Malformed package file /tmp/x.ipk.
#
# The gzipped-tar form installs. This is not a guess: it is the finding GlassOnTin
# documented in openwrt-mcp's own mkipk.sh after testing both against opkg 1bf042dd on a
# GL-BE14000, and it cost them the same afternoon it would have cost us.
#
# Reproducibility
#
# Fixed mtime, root ownership, sorted order. Two builds of the same input then produce
# the same bytes, which is what lets anyone check that a published package matches the
# source without trusting the machine that built it.
set -eu

usage() { echo "usage: mkipk.sh <staging-dir> <ipk-arch> [version]" >&2; exit 2; }

TREE=${1:?$(usage)}
ARCH=${2:?$(usage)}
VERSION=${3:-${HERMES_VERSION:-0.19.0}}
PKGREL=${PKGREL:-1}
PKG=hermes-agent
OUT="${PKG}_${VERSION}-r${PKGREL}_${ARCH}.ipk"

[ -d "$TREE" ] || { echo "mkipk.sh: no tree at $TREE" >&2; exit 1; }

SRC=$(cd "$(dirname "$0")" && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

CTRL="$BUILD/control"
mkdir -p "$CTRL"

# Depends uses opkg's comma-separated form, not apk's space-separated one. Same names on
# both releases; only the separator differs, and getting it wrong yields a package that
# installs and then cannot run because nothing pulled Python in.
cat > "$CTRL/control" <<EOF
Package: $PKG
Version: $VERSION-r$PKGREL
Depends: python3, python3-pip, ca-bundle, ffmpeg, ffprobe, ripgrep
Source: https://github.com/TAIPANBOX/hermes-openwrt
Section: utils
Architecture: $ARCH
Maintainer: TAIPANBOX <yukosemail@gmail.com>
License: MIT
Description: Hermes Agent, the self-hosted AI agent, packaged for OpenWrt.
 Runs as a procd service against any OpenAI-compatible endpoint. The model runs
 elsewhere; this device talks to it over the network.
EOF

# Without this line an upgrade silently overwrites a configured router's settings, which
# is the same failure the apk build guards against and is worth stating twice.
cat > "$CTRL/conffiles" <<EOF
/etc/config/hermes
EOF

cat > "$CTRL/postinst" <<'POST'
#!/bin/sh
# IPKG_INSTROOT is set when opkg is populating an image rather than a running router;
# touching the live service then would be wrong and enabling it would fail anyway.
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
mkdir -p /etc/hermes-agent
chmod 0700 /etc/hermes-agent
/etc/init.d/hermes-agent enable
# Not started: the package ships with no key and no model, and a service that cannot
# work should not spend the first boot saying so.
exit 0
POST

cat > "$CTRL/prerm" <<'PRE'
#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
/etc/init.d/hermes-agent stop
/etc/init.d/hermes-agent disable
exit 0
PRE
# opkg removes every file it owns and then leaves the directory tree standing: 9033
# files gone, 985 empty directories still there. That is its documented behaviour, not a
# fault, but on a router it looks like a failed uninstall and it is the kind of litter
# nobody goes back for. apk prunes them by itself, which is why this script exists only
# on the opkg side.
cat > "$CTRL/postrm" <<'POSTRM'
#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
# Only the private site-packages tree, and only when it holds no files: anything left in
# it is something opkg did not put there, and deleting a stranger's file on the way out
# would be worse than leaving an empty directory.
if [ -d /usr/lib/hermes-agent ] && [ -z "$(find /usr/lib/hermes-agent -type f 2>/dev/null | head -1)" ]; then
	rm -rf /usr/lib/hermes-agent
fi
exit 0
POSTRM
chmod 0755 "$CTRL/postinst" "$CTRL/prerm" "$CTRL/postrm"

MTIME=${SOURCE_DATE_EPOCH:-0}
TAR="tar --numeric-owner --owner=0 --group=0 --sort=name --mtime=@$MTIME --format=gnu"

# shellcheck disable=SC2086
(cd "$CTRL" && $TAR -czf "$BUILD/control.tar.gz" ./*)
# shellcheck disable=SC2086
(cd "$TREE" && $TAR -czf "$BUILD/data.tar.gz" ./*)
echo "2.0" > "$BUILD/debian-binary"

# The gzipped-tar container, not ar. See the header.
# shellcheck disable=SC2086
(cd "$BUILD" && $TAR -czf "$BUILD/$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz)

DEST=${DEST:-$(cd "$SRC/../.." && pwd)}
mkdir -p "$DEST"
cp "$BUILD/$OUT" "$DEST/$OUT"
echo "$OUT"
