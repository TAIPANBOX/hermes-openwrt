#!/bin/sh
# gate-ipk.sh -- the 24.10 package installs with opkg and behaves the same as the apk one.
#
# Invariant:
#
#   "opkg installs hermes-agent on a stock OpenWrt 24.10, the CLI runs there on Python
#   3.11, /etc/config/hermes is registered as a conffile, and the service is enabled but
#   does not start until it is configured."
#
# 24.10 is not a smaller version of 25.12, it is a different set of moving parts: opkg
# instead of apk, a gzipped-tar container instead of an ADB blob, Python 3.11 instead of
# 3.13, and therefore a different wheel set. Every one of those can break independently,
# and the only one that fails loudly is the container format. A wheel built for 3.13
# installs perfectly and then raises ImportError at the first run, and a missing
# conffiles entry does nothing at all until the day someone upgrades.
#
# The conffile check is the one worth naming. On apk the equivalent is implicit; on opkg
# it is a file inside the package, and if it is absent the upgrade silently overwrites a
# router's configuration. Nothing about the install says so.
set -eu

CHECKS='check_installs check_deps_resolve check_cli_runs_on_311 check_conffile_registered check_ships_disabled check_clean_removal'

if [ "${1:-}" = "--selftest" ]; then
	n=0; for c in $CHECKS; do echo "$c"; n=$((n + 1)); done
	[ "$n" -gt 0 ] || { echo "measured nothing" >&2; exit 1; }
	exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-x86_64}
RELEASE=${RELEASE:-24.10.8}
case "$ARCH" in
	x86_64) IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:x86-64-$RELEASE} ;;
	*)      IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:$ARCH-$RELEASE} ;;
esac
PLATFORM=${PLATFORM:-linux/$ARCH}

# -t, because the repository root accumulates builds and nothing removes yesterday's.
# Without it this gate tested hermes-agent_0.19.0-r1 while r2 sat beside it, and passed:
# the checks here do not touch what changed between them, so the pass was true and about
# the wrong package.
IPK=${IPK:-$(ls -t "$ROOT"/hermes-agent_*_"$ARCH".ipk 2>/dev/null | head -1)}
[ -n "$IPK" ] && [ -f "$IPK" ] || {
	echo "FAIL: no .ipk for $ARCH. Build it: RELEASE=$RELEASE ./package/hermes-agent/build-in-container.sh $ARCH"
	exit 1; }
echo "PASS: artefact $(basename "$IPK")"
echo "-- container checks: $IMAGE ($PLATFORM) --"

# -i is load-bearing: without it docker hands `sh -s` an empty stdin and this gate
# reports every check passed having run nothing.
docker run --rm -i --platform "$PLATFORM" -v "$IPK:/pkg.ipk:ro" "$IMAGE" /bin/sh -s <<'CONTAINER'
set -eu
fail() { echo "FAIL $1: $2"; exit 1; }

# opkg refuses to do anything at all without this, with an error about a lock file that
# reads like a permissions problem rather than a missing directory.
mkdir -p /var/lock /var/run /var/state
opkg update >/dev/null 2>&1

# ---- 1. installs ----
opkg install /pkg.ipk >/tmp/i.log 2>&1 || { tail -20 /tmp/i.log; fail check_installs "opkg install failed"; }
opkg list-installed 2>/dev/null | grep -q '^hermes-agent ' || fail check_installs "not registered"
echo "PASS check_installs"

# ---- 2. dependencies came from the release feed ----
for d in python3 python3-pip ca-bundle ffmpeg ripgrep; do
	opkg list-installed 2>/dev/null | grep -q "^$d " || fail check_deps_resolve "$d did not install"
done
echo "PASS check_deps_resolve"

# ---- 3. it runs, on the Python this release ships ----
# The whole reason 24.10 needs its own tree: 3.11 here against 3.13 on 25.12, so a
# different wheel set. A tree built for the wrong one installs fine and dies here.
out=$(/usr/bin/hermes --version 2>&1) || { echo "$out"; fail check_cli_runs_on_311 "hermes --version failed"; }
echo "$out" | grep -q "Hermes Agent" || { echo "$out"; fail check_cli_runs_on_311 "unexpected output"; }
echo "$out" | grep -q "Python: 3.11" || { echo "$out"; fail check_cli_runs_on_311 "not running on the 3.11 this release ships"; }
echo "PASS check_cli_runs_on_311"

# ---- 4. the config is a conffile ----
# Without this an upgrade overwrites a configured router silently. opkg keeps the list in
# the package's own info directory; its absence is invisible until the day it matters.
grep -qx '/etc/config/hermes' /usr/lib/opkg/info/hermes-agent.conffiles 2>/dev/null \
	|| fail check_conffile_registered "/etc/config/hermes is not registered as a conffile"
echo "PASS check_conffile_registered"

# ---- 5. enabled at boot, but not started ----
[ -e /etc/rc.d/S95hermes-agent ] || fail check_ships_disabled "postinst did not enable the service"
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q "disabled in /etc/config/hermes" || { echo "$msg"; fail check_ships_disabled "an unconfigured start did not say why"; }
echo "PASS check_ships_disabled"

# ---- 6. clean removal ----
opkg remove hermes-agent >/dev/null 2>&1 || fail check_clean_removal "opkg remove failed"
[ -e /usr/bin/hermes ] && fail check_clean_removal "the launcher is still there"
# Files first, because that is what matters: opkg deletes every file it owns and then
# leaves the directory tree standing, and a check that only looked at the directory
# would fail on tidiness while passing on an actual leftover file.
left=$(find /usr/lib/hermes-agent -type f 2>/dev/null | wc -l)
[ "$left" -eq 0 ] || fail check_clean_removal "$left files left under /usr/lib/hermes-agent"
[ -d /usr/lib/hermes-agent ] && fail check_clean_removal "the empty tree was left behind; the postrm did not run"
echo "PASS check_clean_removal"
CONTAINER

echo "gate-ipk: all 6 checks passed"
