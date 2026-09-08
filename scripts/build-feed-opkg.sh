#!/bin/sh
# build-feed-opkg.sh -- the same feed, for the 24.10 line, which apk cannot serve.
#
# Nothing here is a variation on the apk feed. It is a different index format, a
# different signature algorithm, a different key, and a different place the key lives on
# the router:
#
#                  25.12                          24.10
#   index          packages.adb (binary ADB)      Packages + Packages.gz (text)
#   signed by      apk adbsign, EC prime256v1     usign, Ed25519
#   signature      inside the index               a separate Packages.sig
#   trusted keys   /etc/apk/keys/<name>.pem       /etc/opkg/keys/<fingerprint>
#   what signs     packages AND the index         the index only
#
# That last row matters. On apk each package carries its own signature; on opkg only the
# index is signed, and a package is trusted because its SHA256 appears in a signed index.
# So an .ipk on its own is never verifiable, and `opkg install ./file.ipk` cannot check
# anything no matter how the feed was built.
#
# The field set below is copied from a real 24.10 feed
# (downloads.openwrt.org/releases/24.10.8/packages/x86_64/base/Packages) rather than from
# documentation, because opkg ignores fields it does not know and silently skips a stanza
# missing one it does: an index that looks right can simply not offer the package.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${RELEASE:-24.10}
OUT=${OUT:-$ROOT/feed-out}
# usign comes from OpenWrt's own feed rather than being compiled here: it is the
# reference implementation and the router will verify with the same code.
SIGNER_IMAGE=${SIGNER_IMAGE:-openwrt/rootfs:x86-64-24.10.8}

SIGN_KEY=${SIGN_KEY:-$ROOT/keys/hermes-openwrt.usign.sec}
PUB_KEY=${PUB_KEY:-$ROOT/keys/hermes-openwrt.usign.pub}
[ -f "$SIGN_KEY" ] || { echo "build-feed-opkg.sh: no usign secret key at $SIGN_KEY" >&2; exit 1; }
[ -f "$PUB_KEY" ]  || { echo "build-feed-opkg.sh: no usign public key at $PUB_KEY" >&2; exit 1; }

ARCHES=${ARCHES:-"aarch64_cortex-a53 x86_64 aarch64_generic"}

for arch in $ARCHES; do
	dir="$OUT/$RELEASE/$arch"
	mkdir -p "$dir"
	found=0
	# The architecture IS in an .ipk filename, unlike apk, so the packages can be picked
	# out of one directory. The all-architecture LuCI package goes into every one of
	# them: opkg reads a feed per architecture and would never look in a shared one.
	#
	# One file per package name, newest first, and the chosen name is printed.
	#
	# The repository root accumulates builds: nothing removes yesterday's .ipk, so a bare
	# `hermes-agent_*_$arch.ipk` matches every revision ever built and the feed ends up
	# carrying several 56 MB copies of the same package, the stale ones included. Names
	# are listed rather than globbed for the same reason the apk feed lists them: a file
	# that reaches a signed feed should be one somebody named.
	for pkg in hermes-agent hermes-agent-telegram; do
		f=$(ls -t "$ROOT"/"$pkg"_*_"$arch".ipk 2>/dev/null | head -1)
		[ -n "$f" ] && [ -f "$f" ] || continue
		cp "$f" "$dir/"; found=$((found + 1))
		echo "    $(basename "$f")"
	done
	f=$(ls -t "$ROOT"/luci-app-hermes_*_all.ipk 2>/dev/null | head -1)
	if [ -n "$f" ] && [ -f "$f" ]; then
		cp "$f" "$dir/"; found=$((found + 1))
		echo "    $(basename "$f")"
	fi
	[ "$found" -gt 0 ] || {
		echo "build-feed-opkg.sh: nothing for $arch. Build it first:" >&2
		echo "  RELEASE=24.10.8 ./package/hermes-agent/build-in-container.sh $arch" >&2
		echo "  FORMAT=ipk ./package/luci-app-hermes/build.sh" >&2
		exit 1; }
	echo "==> $arch: $found packages"
done

docker run --rm -i --platform linux/amd64 \
	-v "$OUT:/feed" \
	-v "$SIGN_KEY:/keys/usign.sec:ro" \
	"$SIGNER_IMAGE" /bin/sh -s <<CONTAINER
set -eu
# opkg refuses to run at all without this and blames a lock file for it.
mkdir -p /var/lock /var/run /var/state
opkg update >/dev/null 2>&1
opkg install usign >/dev/null 2>&1
command -v usign >/dev/null || { echo "usign did not install"; exit 1; }

for dir in /feed/$RELEASE/*; do
	[ -d "\$dir" ] || continue
	cd "\$dir"
	: > Packages
	for f in *.ipk; do
		# Every .ipk is a gzipped tar holding control.tar.gz; the stanza is that control
		# file plus the three fields only the index can know.
		rm -rf /tmp/x && mkdir -p /tmp/x && cd /tmp/x
		tar -xzf "\$dir/\$f" ./control.tar.gz 2>/dev/null || tar -xzf "\$dir/\$f" control.tar.gz
		tar -xzf control.tar.gz ./control 2>/dev/null || tar -xzf control.tar.gz control
		cd "\$dir"
		# Description must come last: it is the only multi-line field, and anything
		# printed after its continuation lines is read as part of it.
		grep -vE '^(Description:| )' /tmp/x/control >> Packages
		echo "Filename: \$f" >> Packages
		echo "Size: \$(wc -c < "\$f" | tr -d ' ')" >> Packages
		echo "SHA256sum: \$(sha256sum "\$f" | cut -d' ' -f1)" >> Packages
		sed -n '/^Description:/,\$p' /tmp/x/control >> Packages
		echo "" >> Packages
	done
	gzip -9 -c Packages > Packages.gz
	# The signature covers the uncompressed index, which is what a router verifies after
	# decompressing what it downloaded.
	usign -S -m Packages -s /keys/usign.sec -x Packages.sig
	echo "==> \$(basename "\$dir"): \$(grep -c '^Package:' Packages) packages, index \$(wc -c < Packages | tr -d ' ') bytes, signed"
done
CONTAINER

# The public key travels with the feed. opkg identifies a key by its fingerprint rather
# than its filename, so it is published under both: the readable name for a person
# following instructions, and the fingerprint for anything scripted.
cp "$PUB_KEY" "$OUT/hermes-openwrt.usign.pub"
FP=$(docker run --rm -i -v "$PUB_KEY:/k.pub:ro" --platform linux/amd64 "$SIGNER_IMAGE" \
	/bin/sh -c 'mkdir -p /var/lock; opkg update >/dev/null 2>&1; opkg install usign >/dev/null 2>&1; usign -F -p /k.pub' | tr -d '\r\n ')
[ -n "$FP" ] && cp "$PUB_KEY" "$OUT/$FP"
echo "==> usign fingerprint: ${FP:-unknown}"
echo "==> opkg feed under $OUT/$RELEASE"
