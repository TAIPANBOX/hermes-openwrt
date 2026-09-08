#!/bin/sh
# Build an opkg .ipk for the Telegram add-on on OpenWrt 24.10.
#
# The container format is the gzipped-tar form, not ar. opkg on these targets rejects
# the ar form outright with "pkg_init_from_file: Malformed package file". The base
# package's mkipk.sh carries the full account of that; it is repeated here only so
# nobody edits this file toward the documentation and breaks it.
#
# What differs from the base package
#
#   no conffiles   this package ships no configuration. The Telegram settings live in
#                  /etc/config/hermes, which the base package owns, so that a router has
#                  one config file for one service rather than two.
#   no init        it is the same process. The base service reads the telegram section.
#   a postrm       opkg removes every file it owns and leaves the directories standing.
#                  The base package prunes its own tree the same way; this one prunes
#                  only the directories it created, named explicitly, and only when
#                  nothing is left inside them.
set -eu

usage() { echo "usage: mkipk.sh <staging-dir> <ipk-arch> [version]" >&2; exit 2; }

TREE=${1:?$(usage)}
ARCH=${2:?$(usage)}
VERSION=${3:-${HERMES_VERSION:-0.19.0}}
PKGREL=${PKGREL:-1}
PKG=hermes-agent-telegram
OUT="${PKG}_${VERSION}-r${PKGREL}_${ARCH}.ipk"

[ -d "$TREE" ] || { echo "mkipk.sh: no tree at $TREE" >&2; exit 1; }

SRC=$(cd "$(dirname "$0")" && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

CTRL="$BUILD/control"
mkdir -p "$CTRL"

NEXT=$(echo "$VERSION" | awk -F. '{print $1"."$2"."$3+1}')
cat > "$CTRL/control" <<EOF
Package: $PKG
Version: $VERSION-r$PKGREL
Depends: hermes-agent (>= $VERSION), hermes-agent (<< $NEXT)
Source: https://github.com/TAIPANBOX/hermes-openwrt
Section: utils
Architecture: $ARCH
Maintainer: TAIPANBOX <yukosemail@gmail.com>
License: MIT
Description: Telegram platform for Hermes Agent on OpenWrt.
 The Telegram adapter already ships inside hermes-agent; this package adds the
 python-telegram-bot client library it cannot load without. Enable it in the
 telegram section of /etc/config/hermes.
EOF

# The directories this package creates under the base package's site-packages, taken
# from the tree rather than typed. Anything typed here would be right until upstream
# moved its pin, and wrong silently afterwards, in a script that only runs at removal.
DIRS=$(cd "$TREE/usr/lib/hermes-agent/site-packages" && find . -mindepth 1 -maxdepth 1 -type d \
	| sed 's|^\./||' | sort | tr '\n' ' ')
[ -n "$DIRS" ] || { echo "mkipk.sh: the tree installs no directory under site-packages" >&2; exit 1; }
# A name containing a space would split into two words in the generated loop and delete
# neither. Distribution names cannot contain one, so this asserts the tree is what it is
# believed to be rather than handling a case. Counting words against counting entries is
# the portable way to ask; busybox ash has no $'\n' and no arrays.
NDIRS=$(cd "$TREE/usr/lib/hermes-agent/site-packages" && find . -mindepth 1 -maxdepth 1 -type d | wc -l)
NWORDS=$(echo "$DIRS" | wc -w)
[ "$NDIRS" -eq "$NWORDS" ] || {
	echo "mkipk.sh: $NDIRS directories became $NWORDS words; a name contains a space" >&2
	exit 1
}

# Written with an unquoted heredoc so $DIRS is expanded here, at build time. Everything
# the postrm itself must evaluate at REMOVAL time is escaped.
cat > "$CTRL/postrm" <<POSTRM
#!/bin/sh
# Prune the directories this package created, and only those, and only once opkg has
# removed every file it owned from inside them. A directory still holding a file holds
# something opkg did not put there, and taking a stranger's file out on the way is worse
# than leaving an empty directory behind.
[ -n "\${IPKG_INSTROOT:-}" ] && exit 0
SITE=/usr/lib/hermes-agent/site-packages
for d in $DIRS; do
	[ -d "\$SITE/\$d" ] || continue
	[ -z "\$(find "\$SITE/\$d" -type f 2>/dev/null | head -1)" ] && rm -rf "\$SITE/\$d"
done
exit 0
POSTRM
chmod 0755 "$CTRL/postrm"

MTIME=${SOURCE_DATE_EPOCH:-0}
TAR="tar --numeric-owner --owner=0 --group=0 --sort=name --mtime=@$MTIME --format=gnu"

# shellcheck disable=SC2086
(cd "$CTRL" && $TAR -czf "$BUILD/control.tar.gz" ./*)
# shellcheck disable=SC2086
(cd "$TREE" && $TAR -czf "$BUILD/data.tar.gz" ./*)
echo "2.0" > "$BUILD/debian-binary"
# shellcheck disable=SC2086
(cd "$BUILD" && $TAR -czf "$BUILD/$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz)

DEST=${DEST:-$(cd "$SRC/../.." && pwd)}
mkdir -p "$DEST"
cp "$BUILD/$OUT" "$DEST/$OUT"
echo "$OUT"
