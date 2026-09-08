#!/bin/sh
# Package luci-app-hermes.
#
# Architecture-independent, because it is JavaScript, JSON and one shell script: the
# apk arch is `all` and one build serves every router. That is also why this does not
# reuse the agent package's build-in-container.sh, which exists to resolve wheels
# against the target's libc and has nothing to do here.
#
# The JS is shipped as written rather than minified. LuCI loads these files from the
# router's own filesystem over the LAN, where a few kilobytes cost nothing, and the
# person most likely to read them is someone debugging their own router at two in the
# morning. Readable source is worth more than the saving.
set -eu

PKGREL=${PKGREL:-1}
VERSION=${VERSION:-0.19.0}
SRC=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SRC/../.." && pwd)
WORK="$ROOT/build/luci-app-hermes"
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
OUT="luci-app-hermes-$VERSION-r$PKGREL.apk"

rm -rf "$WORK"; mkdir -p "$WORK/tree"

# The layout is LuCI's own, so the files land where luci-base already looks: views under
# luci-static/resources/view, the menu in menu.d, the permission grant in acl.d, and the
# rpcd backend in /usr/libexec/rpcd where rpcd enumerates plugins at start.
cp -a "$SRC/htdocs" "$WORK/tree/www" 2>/dev/null || true
mkdir -p "$WORK/tree/www/luci-static/resources/view/hermes"
cp "$SRC/htdocs/luci-static/resources/view/hermes/"*.js \
   "$WORK/tree/www/luci-static/resources/view/hermes/"
rm -rf "$WORK/tree/www/luci-static/resources/view/hermes/htdocs" 2>/dev/null || true

mkdir -p "$WORK/tree/usr/share/luci/menu.d" "$WORK/tree/usr/share/rpcd/acl.d" \
         "$WORK/tree/usr/libexec/rpcd"
cp "$SRC/root/usr/share/luci/menu.d/luci-app-hermes.json"   "$WORK/tree/usr/share/luci/menu.d/"
cp "$SRC/root/usr/share/rpcd/acl.d/luci-app-hermes.json"    "$WORK/tree/usr/share/rpcd/acl.d/"
cp "$SRC/root/usr/libexec/rpcd/hermes"                      "$WORK/tree/usr/libexec/rpcd/hermes"
chmod 0755 "$WORK/tree/usr/libexec/rpcd/hermes"
find "$WORK/tree" -name '*.js' -o -name '*.json' | xargs chmod 0644

# rpcd caches its plugin list, and acl.d is read at start too, so a freshly installed
# backend is invisible until rpcd is restarted. Without this the page installs and then
# reports "Object not found" for every call, which looks like a broken app rather than a
# service that has not noticed a new file.
cat > "$WORK/post-install" <<'POST'
#!/bin/sh
/etc/init.d/rpcd restart 2>/dev/null
# LuCI caches the menu it built from menu.d; a stale cache hides the new entry until
# something else happens to invalidate it.
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
exit 0
POST
cat > "$WORK/pre-deinstall" <<'PRE'
#!/bin/sh
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
exit 0
PRE
chmod 0755 "$WORK/post-install" "$WORK/pre-deinstall"

# arch is noarch, not "all". OpenWrt's own package-pack.mk maps PKGARCH=all to
# arch:noarch, and apk refuses anything whose arch is neither noarch nor the router's
# own with a bare "error: uninstallable" that names nothing and explains less.
# 24.10 predates apk and needs the opkg container format instead. Same tree, same files,
# different wrapper; FORMAT=ipk selects it.
if [ "${FORMAT:-apk}" = ipk ]; then
	IOUT="luci-app-hermes_${VERSION}-r${PKGREL}_all.ipk"
	CTRL="$WORK/ipkctrl"; mkdir -p "$CTRL"
	cat > "$CTRL/control" <<CTL
Package: luci-app-hermes
Version: $VERSION-r$PKGREL
Depends: luci-base, hermes-agent
Source: https://github.com/TAIPANBOX/hermes-openwrt
Section: luci
Architecture: all
Maintainer: TAIPANBOX <yukosemail@gmail.com>
License: MIT
Description: LuCI interface for the Hermes Agent service.
 Status, service control, log tail, and write-only key fields.
CTL
	cp "$WORK/post-install" "$CTRL/postinst"
	cp "$WORK/pre-deinstall" "$CTRL/prerm"
	chmod 0755 "$CTRL/postinst" "$CTRL/prerm"
	docker run --rm -i -v "$WORK:/work" -w /work "$ALPINE" sh -c '
		apk add -q --no-cache tar >/dev/null 2>&1
		T="tar --numeric-owner --owner=0 --group=0 --sort=name --mtime=@0 --format=gnu"
		(cd /work/ipkctrl && $T -czf /work/control.tar.gz ./*)
		(cd /work/tree    && $T -czf /work/data.tar.gz ./*)
		echo "2.0" > /work/debian-binary
		# gzipped tar, not ar: opkg on these targets rejects the ar form outright.
		(cd /work && $T -czf "/work/'"$IOUT"'" ./debian-binary ./control.tar.gz ./data.tar.gz)'
	cp "$WORK/$IOUT" "$ROOT/$IOUT"
	echo "==> $IOUT  ($(du -h "$ROOT/$IOUT" | cut -f1))"
	exit 0
fi

docker run --rm -i -v "$WORK:/work" -w /work "$ALPINE" apk mkpkg \
	--info "name:luci-app-hermes" \
	--info "version:$VERSION-r$PKGREL" \
	--info "arch:noarch" \
	--info "license:MIT" \
	--info "origin:luci-app-hermes" \
	--info "url:https://github.com/TAIPANBOX/hermes-openwrt" \
	--info "description:LuCI interface for the Hermes Agent service. Status, service control, log tail, and write-only key fields." \
	--info "depends:luci-base hermes-agent" \
	--script "post-install:/work/post-install" \
	--script "pre-deinstall:/work/pre-deinstall" \
	--files /work/tree \
	--output "/work/$OUT"

cp "$WORK/$OUT" "$ROOT/$OUT"
echo "==> $OUT  ($(du -h "$ROOT/$OUT" | cut -f1))"
