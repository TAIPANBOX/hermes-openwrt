#!/bin/sh
# gate-feed.sh -- the signature has to be the thing that decides.
#
# Invariant:
#
#   "with the feed's public key in /etc/apk/keys, apk installs from the feed with no
#   --allow-untrusted; without it, the feed's packages are not installable at all."
#
# Both halves matter and only the second one is easy to get wrong silently. A feed whose
# packages install either way is not a signed feed, it is an unsigned feed with a key
# file next to it, and nothing about the successful install would tell you which you had
# built. So this runs the same install twice, and requires it to fail the first time.
#
# What "not installable" looks like is worth knowing before you see it: apk does not
# announce a rejected repository. It drops it, and the package then simply does not
# exist, so the message is "no such package" and the available count is quietly lower.
# The check below asserts on that, because it is what a user would actually hit.
set -eu

CHECKS='check_refused_without_key check_installs_with_key check_no_allow_untrusted_needed'

if [ "${1:-}" = "--selftest" ]; then
	n=0; for c in $CHECKS; do echo "$c"; n=$((n + 1)); done
	[ "$n" -gt 0 ] || { echo "measured nothing" >&2; exit 1; }
	exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-x86_64}
RELEASE=${RELEASE:-25.12}
FEED=${FEED:-$ROOT/feed-out}
case "$ARCH" in
	x86_64) IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:x86-64-25.12.4} ;;
	*)      IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:$ARCH-25.12.4} ;;
esac
PLATFORM=${PLATFORM:-linux/$ARCH}

[ -f "$FEED/$RELEASE/$ARCH/packages.adb" ] || {
	echo "FAIL: no index at $FEED/$RELEASE/$ARCH/packages.adb; build the feed first"; exit 1; }
[ -f "$FEED/hermes-openwrt.pem" ] || { echo "FAIL: no public key in the feed"; exit 1; }
echo "PASS: feed present for $ARCH"

# The feed is mounted rather than served: what is under test is the signature, and an
# HTTP server between here and apk would only add a way for the test to fail for a
# reason that has nothing to do with it.
docker run --rm -i --platform "$PLATFORM" -v "$FEED:/feed:ro" "$IMAGE" /bin/sh -s <<CONTAINER
set -eu
fail() { echo "FAIL \$1: \$2"; exit 1; }

mkdir -p /var/lock /var/run /var/state
echo "/feed/$RELEASE/$ARCH/packages.adb" > /etc/apk/repositories.d/customfeeds.list

# ---- 1. refused without the key ----
apk update >/tmp/u1.log 2>&1 || true
if apk add hermes-agent >/tmp/a1.log 2>&1; then
	fail check_refused_without_key "it installed with no key trusted, so the signature decides nothing"
fi
grep -q "no such package" /tmp/a1.log || {
	cat /tmp/a1.log
	fail check_refused_without_key "it failed, but not by the feed being untrusted"; }
before=\$(grep -oE '[0-9]+ distinct packages' /tmp/u1.log | grep -oE '^[0-9]+' | tail -1)
echo "PASS check_refused_without_key (\${before:-?} packages visible)"

# ---- 2 and 3. installs with the key, and without the flag ----
cp /feed/hermes-openwrt.pem /etc/apk/keys/hermes-openwrt.pem
apk update >/tmp/u2.log 2>&1 || true
after=\$(grep -oE '[0-9]+ distinct packages' /tmp/u2.log | grep -oE '^[0-9]+' | tail -1)
[ "\${after:-0}" -gt "\${before:-0}" ] || fail check_installs_with_key "trusting the key did not make more packages visible"

# Deliberately no --allow-untrusted: if this needs the flag, the feed is not signed in
# any way that helps, and the whole exercise was decoration.
apk add hermes-agent luci-app-hermes >/tmp/a2.log 2>&1 || { cat /tmp/a2.log; fail check_installs_with_key "install failed with the key trusted"; }
apk info -e hermes-agent >/dev/null 2>&1 || fail check_installs_with_key "not registered after install"
apk info -e luci-app-hermes >/dev/null 2>&1 || fail check_installs_with_key "the LuCI app did not install"
echo "PASS check_installs_with_key (\${before:-?} -> \${after:-?} packages)"

grep -q 'allow-untrusted' /tmp/a2.log && fail check_no_allow_untrusted_needed "apk asked for --allow-untrusted"
/usr/bin/hermes --version >/dev/null 2>&1 || fail check_no_allow_untrusted_needed "installed from the feed but does not run"
echo "PASS check_no_allow_untrusted_needed"
CONTAINER

echo "gate-feed: all 3 checks passed"
