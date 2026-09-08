#!/bin/sh
# build-feed.sh -- sign the packages, build a signed index, lay out a publishable feed.
#
# Why sign at all
#
# An unsigned package can only be installed with `apk add --allow-untrusted`, which is a
# flag people learn to type reflexively and then keep typing at the one moment it
# matters. A signed feed removes the flag from the instructions entirely: the key is
# added once, and after that `apk add hermes-agent` either verifies or fails. The
# difference is not cosmetic. This package installs a Python runtime and an agent with a
# shell on someone's router.
#
# The order matters, and the error message does not say so
#
# `apk mkndx` refuses to index a package whose signature it does not trust, so the
# packages are signed FIRST and the index second. Running mkndx on unsigned packages
# gives "UNTRUSTED signature ... 2 errors, not creating index", which reads like a
# problem with the key rather than with the order.
#
# Reading an unsigned input needs --allow-untrusted even while writing a signature.
# Without it adbsign fails, and it fails after having already truncated the output: a
# 60 MB package came back as 470 KB the first time this was tried. adbsign rewrites in
# place, so this script always works on copies under build/feed and never on the
# artefacts themselves.
#
# What "trusted" means on the router
#
# apk trusts a key because the file is in /etc/apk/keys, and nothing more. Verified on
# openwrt/rootfs:x86-64-25.12.4: without the key the feed's packages are not merely
# rejected, they are invisible, and `apk add hermes-agent` says "no such package" while
# reporting two fewer packages available. With the key present both packages install
# with no --allow-untrusted anywhere.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${RELEASE:-25.12}
OUT=${OUT:-$ROOT/feed-out}
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}

# The private key never lives in the repository. In CI it arrives as a secret and is
# written to a file the job deletes; locally it is whatever path the caller points at.
SIGN_KEY=${SIGN_KEY:-}
[ -n "$SIGN_KEY" ] && [ -f "$SIGN_KEY" ] || {
	echo "build-feed.sh: set SIGN_KEY to the private key file" >&2
	echo "  generate a pair with: ./scripts/feed-keygen.sh" >&2
	exit 1
}
PUB_KEY=${PUB_KEY:-$ROOT/keys/hermes-openwrt.pem}
[ -f "$PUB_KEY" ] || { echo "build-feed.sh: no public key at $PUB_KEY" >&2; exit 1; }

# Which architecture each package belongs under. A noarch package is published into
# every architecture's directory rather than a shared one: apk resolves a repository per
# architecture, and a single noarch directory would simply never be looked in.
# Ordered by which device this is actually for. A GL.iNet Flint 2 reports
# aarch64_cortex-a53 in /etc/apk/arch and will not look at a package declaring anything
# else, so that name leads. x86_64 follows because it is the mini-PC case and the one CI
# can exercise natively. aarch64_generic is the vehicle the aarch64 tree is built in and
# is published because it costs nothing, not because a router was chosen for it.
ARCHES=${ARCHES:-"aarch64_cortex-a53 x86_64 aarch64_generic"}

rm -rf "$OUT"

for arch in $ARCHES; do
	dir="$OUT/$RELEASE/$arch"
	mkdir -p "$dir"

	# Packages are collected from the per-architecture build directories, not from the
	# repository root. An apk filename carries no architecture, unlike an .ipk, so the
	# aarch64 and x86_64 builds of hermes-agent have the identical name and the second
	# build silently overwrites the first wherever they share a directory.
	# The add-on's build directory is a sibling of the base package's, not a child of
	# it: the base build opens with `rm -rf` on its own directory, so anything kept
	# inside would survive only until the next base build. That is why the name has a
	# suffix here rather than a slash.
	found=0
	for src in "$ROOT/build/$RELEASE/$arch" "$ROOT/build/$RELEASE/$arch-telegram" \
	           "$ROOT/build/luci-app-hermes-apk"; do
		[ -d "$src" ] || continue
		for f in "$src"/*.apk; do
			[ -f "$f" ] || continue
			# An allow-list of names, and a refusal rather than a skip.
			#
			# These directories are working directories: teeth.sh repacks deliberately
			# broken packages into them as mutant.apk and, on a run that fails partway,
			# leaves them there. A `cp *.apk` collected one on 2026-09-08, and nothing
			# downstream would have objected: the feed builder would have signed it with
			# the real key and served it from Pages beside the real packages.
			#
			# Skipping quietly would be the wrong repair. A file here that nobody named
			# means the working directory is not what this script believes it is, and
			# the artefact about to be signed should not be built on that.
			case "$(basename "$f")" in
				hermes-agent-[0-9]*.apk|hermes-agent-telegram-[0-9]*.apk|luci-app-hermes-[0-9]*.apk) ;;
				*)
					echo "build-feed.sh: $f is not a package this repository publishes." >&2
					echo "build-feed.sh: a stray file in a build directory, most likely from an" >&2
					echo "build-feed.sh: interrupted teeth run. Remove it, or add the name here." >&2
					exit 1 ;;
			esac
			cp "$f" "$dir/"
			found=$((found + 1))
		done
	done
	[ "$found" -gt 0 ] || {
		echo "build-feed.sh: nothing for $arch. Build it first:" >&2
		echo "  ./package/hermes-agent/build-in-container.sh $arch" >&2
		echo "  ./package/luci-app-hermes/build.sh" >&2
		exit 1; }
	echo "==> $arch: $found packages"
done

# One container for all the signing, with the key mounted read-only and the public key
# trusted inside it so mkndx will accept what adbsign just wrote.
docker run --rm -i \
	-v "$OUT:/feed" \
	-v "$SIGN_KEY:/keys/private.pem:ro" \
	-v "$PUB_KEY:/keys/public.pem:ro" \
	"$ALPINE" /bin/sh -s <<CONTAINER
set -eu
cp /keys/public.pem /etc/apk/keys/hermes-openwrt.pem

for dir in /feed/$RELEASE/*; do
	[ -d "\$dir" ] || continue
	cd "\$dir"
	for f in *.apk; do
		# --allow-untrusted describes the INPUT, not the output: the package being
		# signed has no signature yet, and without this adbsign refuses and leaves a
		# truncated file behind.
		apk adbsign --allow-untrusted --sign-key /keys/private.pem "\$f" >/dev/null
	done
	apk mkndx --output packages.adb *.apk >/dev/null
	apk adbsign --allow-untrusted --sign-key /keys/private.pem packages.adb >/dev/null
	echo "==> \$(basename "\$dir"): index \$(stat -c %s packages.adb) bytes, \$(ls *.apk | wc -l) packages"
done
CONTAINER

# The public key travels with the feed so the install instructions are two lines and not
# a scavenger hunt.
cp "$PUB_KEY" "$OUT/hermes-openwrt.pem"

# A landing page, because a bare directory index is a bad first impression for something
# whose whole job is to be trusted.
cat > "$OUT/index.html" <<HTML
<!doctype html><meta charset="utf-8"><title>hermes-openwrt feed</title>
<style>body{font:16px/1.6 system-ui,sans-serif;max-width:46rem;margin:3rem auto;padding:0 1rem}
code,pre{background:#f4f4f4;padding:.15rem .35rem;border-radius:3px}pre{padding:.8rem;overflow-x:auto}
h2{margin-top:2.2rem}</style>
<h1>hermes-openwrt</h1>
<p>A signed feed carrying <a href="https://github.com/TAIPANBOX/hermes-openwrt">hermes-agent
and luci-app-hermes</a>: the Hermes Agent as a native OpenWrt service. The reference
device is a GL.iNet Flint 2; x86_64 and generic aarch64 are served too.</p>

<h2>OpenWrt 25.12 and later (apk)</h2>
<pre>wget -O /etc/apk/keys/hermes-openwrt.pem \\
  https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.pem

echo "https://taipanbox.github.io/hermes-openwrt/25.12/\$(cat /etc/apk/arch)/packages.adb" \\
  >> /etc/apk/repositories.d/customfeeds.list

apk update && apk add hermes-agent luci-app-hermes</pre>

<h2>OpenWrt 24.10 (opkg)</h2>
<p>Pick the line for your device. opkg needs the exact architecture, and
<code>opkg print-architecture</code> lists several of which only one is right.</p>
<pre># GL.iNet Flint 2 and other Cortex-A53 routers
ARCH=aarch64_cortex-a53
# x86 boxes:            ARCH=x86_64
# other 64-bit ARM:     ARCH=aarch64_generic

wget -O /tmp/hermes.pub \\
  https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.usign.pub
opkg-key add /tmp/hermes.pub

echo "src/gz hermes https://taipanbox.github.io/hermes-openwrt/24.10/\$ARCH" \\
  >> /etc/opkg/customfeeds.conf

opkg update && opkg install hermes-agent luci-app-hermes</pre>

<h2>Why the two look different</h2>
<p>They are not the same feed in two shapes. 25.12 signs every package and the index with
an EC key that apk verifies; 24.10 signs only the index, with a usign Ed25519 key that
opkg verifies against a fingerprint in <code>/etc/opkg/keys</code>. Neither key works for
the other line.</p>
<p>Without the right key: apk drops the repository silently and the package simply does
not exist, while opkg says <code>Signature check failed</code> and refuses. In both cases
no <code>--force</code> and no <code>--allow-untrusted</code> appears anywhere above.</p>
<p>Architectures: $ARCHES</p>
HTML

echo "==> feed at $OUT ($(du -sh "$OUT" | cut -f1))"
