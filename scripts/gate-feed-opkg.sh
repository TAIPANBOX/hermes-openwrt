#!/bin/sh
# gate-feed-opkg.sh -- the 24.10 feed's signature has to be the thing that decides.
#
# Invariant:
#
#   "with the feed's usign key trusted, opkg installs from it and reports the signature
#   check passing; without it, the update is rejected and the package cannot be
#   installed."
#
# The same shape as the apk gate and worth writing separately, because the two fail
# differently and only one of them fails visibly. apk drops an untrusted repository in
# silence, so the package merely appears not to exist. opkg says "Signature check
# failed" and refuses. A gate that only asserted "install fails" would pass on a feed
# whose packages were absent for some entirely unrelated reason, so this asserts on the
# signature message itself.
#
# What opkg signs, and what it does not: only the index. A package is trusted because
# its SHA256 appears in a signed Packages file, which means an .ipk handed over on its
# own is never verifiable and `opkg install ./file.ipk` checks nothing at all.
set -eu

CHECKS='check_refused_without_key check_signature_passes_with_key check_installs_and_runs'

if [ "${1:-}" = "--selftest" ]; then
	n=0; for c in $CHECKS; do echo "$c"; n=$((n + 1)); done
	[ "$n" -gt 0 ] || { echo "measured nothing" >&2; exit 1; }
	exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-x86_64}
RELEASE=${RELEASE:-24.10}
FEED=${FEED:-$ROOT/feed-out}
IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:x86-64-24.10.8}

[ -f "$FEED/$RELEASE/$ARCH/Packages.sig" ] || {
	echo "FAIL: no signed index at $FEED/$RELEASE/$ARCH/Packages.sig; build the feed first"; exit 1; }
FP=$(ls "$FEED" | grep -E '^[0-9a-f]{16}$' | head -1)
[ -n "$FP" ] || { echo "FAIL: no usign public key (fingerprint-named) in the feed"; exit 1; }
echo "PASS: signed index present for $ARCH, key fingerprint $FP"

# -i is load-bearing: without it docker hands `sh -s` an empty stdin, nothing runs, and
# this gate reports success having measured nothing.
docker run --rm -i --platform linux/amd64 -v "$FEED:/feed:ro" "$IMAGE" /bin/sh -s <<CONTAINER
set -eu
fail() { echo "FAIL \$1: \$2"; exit 1; }

mkdir -p /var/lock /var/run /var/state
# If this ever ships off, every check below passes for the wrong reason.
grep -q check_signature /etc/opkg.conf || fail check_refused_without_key "signature checking is not enabled on this image, so nothing here proves anything"

echo "src/gz hermes file:///feed/$RELEASE/$ARCH" >> /etc/opkg/customfeeds.conf

# ---- 1. refused without the key ----
opkg update >/tmp/u1.log 2>&1 || true
grep -qi "signature check failed" /tmp/u1.log || {
	cat /tmp/u1.log; fail check_refused_without_key "the update did not report a failed signature check"; }
if opkg install hermes-agent >/tmp/i1.log 2>&1; then
	fail check_refused_without_key "it installed with no key trusted, so the signature decides nothing"
fi
echo "PASS check_refused_without_key"

# ---- 2. the signature passes once the key is trusted ----
opkg-key add "/feed/$FP" >/dev/null 2>&1 || fail check_signature_passes_with_key "opkg-key add failed"
[ -e "/etc/opkg/keys/$FP" ] || fail check_signature_passes_with_key "the key did not land in /etc/opkg/keys"
opkg update >/tmp/u2.log 2>&1 || true
grep -qi "signature check passed" /tmp/u2.log || {
	cat /tmp/u2.log; fail check_signature_passes_with_key "the signature still does not verify"; }
echo "PASS check_signature_passes_with_key"

# ---- 3. and the packages install and run ----
opkg install hermes-agent luci-app-hermes >/tmp/i2.log 2>&1 || {
	tail -20 /tmp/i2.log; fail check_installs_and_runs "install failed with the key trusted"; }
opkg list-installed 2>/dev/null | grep -q '^hermes-agent ' || fail check_installs_and_runs "hermes-agent is not registered"
opkg list-installed 2>/dev/null | grep -q '^luci-app-hermes ' || fail check_installs_and_runs "the LuCI app is not registered"
/usr/bin/hermes --version >/dev/null 2>&1 || fail check_installs_and_runs "installed from the feed but does not run"
echo "PASS check_installs_and_runs"
CONTAINER

echo "gate-feed-opkg: all 3 checks passed"
