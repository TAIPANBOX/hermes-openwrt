#!/bin/sh
# gate-package.sh -- the package must install on a real OpenWrt and refuse to misbehave.
#
# Invariant:
#
#   "apk installs hermes-agent on a stock OpenWrt 25.12 rootfs, the CLI runs there, the
#   service is enabled but does not start until it is configured, and the API key reaches
#   neither the process table nor UCI."
#
# The first half is the obvious part. The second half is the half that matters, and it is
# why this gate installs into a real rootfs instead of inspecting the archive: a package
# that lands its files correctly and then leaks a key into argv, or spins in a restart
# loop because it was shipped enabled with no configuration, has passed every check an
# archive inspection could make and is still wrong on somebody's router.
#
# Everything runs in one container. Each `docker run` is a fresh one, and the state these
# checks build on (installed package, edited config, written key) does not carry between
# them.
set -eu

CHECKS='check_installs check_deps_resolve check_cli_runs check_ships_disabled check_refuses_without_key check_key_not_in_argv check_key_not_in_uci check_config_survives check_clean_removal'

if [ "${1:-}" = "--selftest" ]; then
	n=0
	for c in $CHECKS; do echo "$c"; n=$((n + 1)); done
	# A gate listing zero checks looks identical in CI output to a healthy one, right up
	# until someone notices it has been testing nothing for a month.
	[ "$n" -gt 0 ] || { echo "measured nothing" >&2; exit 1; }
	exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
case "$ARCH" in
	x86_64) IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:x86-64-$RELEASE} ;;
	*)      IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:$ARCH-$RELEASE} ;;
esac
# OpenWrt publishes its OCI platform string as the package architecture; plain
# linux/arm64 finds no manifest even though it is the same silicon.
PLATFORM=${PLATFORM:-linux/$ARCH}


# Where to look for the package, and why not the repository root.
#
# An .apk filename carries no architecture, unlike an .ipk, so every architecture builds
# a file of the same name and the last build to finish wins in the repository root. A
# gate reading it therefore tests whichever architecture was built most recently, which
# on 2026-09-08 meant an aarch64 gate trying to install an x86_64 package and reporting
# "error: uninstallable" with no hint of the cause. The per-architecture build directory
# has no such ambiguity, so it is what is read; the root is a fallback that says so.
LINE=${LINE:-${RELEASE%%.*}.$(echo "$RELEASE" | cut -d. -f2)}
BUILD_DIR="$ROOT/build/$LINE/$ARCH"
pick_apk() {
	found=$(ls -t "$BUILD_DIR"/$1 2>/dev/null | head -1)
	if [ -n "$found" ]; then echo "$found"; return 0; fi
	found=$(ls -t "$ROOT"/$1 2>/dev/null | head -1)
	if [ -n "$found" ]; then
		echo "$ROOT holds no per-architecture build for $ARCH; falling back to $(basename "$found")," >&2
		echo "which may have been built for another architecture. Build $ARCH to be sure." >&2
		echo "$found"
	fi
}

# [0-9] so the glob stops matching hermes-agent-telegram-*.apk, which it began doing the
# day that package was added.
APK=${APK:-$(pick_apk 'hermes-agent-[0-9]*.apk')}
[ -n "$APK" ] && [ -f "$APK" ] || {
	echo "FAIL: no package found. Build it: ./package/hermes-agent/build-in-container.sh $ARCH"
	exit 1
}
echo "PASS: artefact $APK"
echo "-- container checks: $IMAGE ($PLATFORM) --"

# -i is load-bearing. Without it docker hands `sh -s` an empty stdin, the script never
# runs, the container exits 0, and this gate reports every check passed having measured
# nothing at all.
docker run --rm -i --platform "$PLATFORM" -v "$APK:/pkg.apk:ro" "$IMAGE" /bin/sh -s <<'CONTAINER'
set -eu
fail() { echo "FAIL $1: $2"; exit 1; }

# A booted router has /var symlinked to /tmp with these present; a bare rootfs has
# neither, and without them rc.common's enable silently writes no rc.d link.
mkdir -p /var/lock /var/run /var/state
apk update -q

# ---- 1. installs ----
apk add --allow-untrusted /pkg.apk >/tmp/add.log 2>&1 || { cat /tmp/add.log; fail "[1/9] check_installs" "apk add failed"; }
apk info -e hermes-agent >/dev/null 2>&1 || fail "[1/9] check_installs" "not registered after install"
echo "PASS [1/9] check_installs"

# ---- 2. dependencies resolve from the real release feed ----
# The package declares runtime dependencies it cannot function without; if any of them
# stopped existing in the feed, apk would have refused above, but an unresolved OPTIONAL
# name would pass silently, so assert each one landed.
for d in python3 python3-pip ca-bundle ffmpeg ffprobe ripgrep; do
	apk info -e "$d" >/dev/null 2>&1 || fail "[2/9] check_deps_resolve" "$d did not install"
done
echo "PASS [2/9] check_deps_resolve"

# ---- 3. the CLI runs on the router ----
# This is the check the whole musllinux-wheel bet comes down to. If any of the 13
# compiled dependencies were assembled for the wrong libc, it fails here with an
# ImportError rather than on somebody's device.
out=$(/usr/bin/hermes --version 2>&1) || { echo "$out"; fail "[3/9] check_cli_runs" "hermes --version exited non-zero"; }
echo "$out" | grep -q "Hermes Agent" || { echo "$out"; fail "[3/9] check_cli_runs" "unexpected output"; }
echo "PASS [3/9] check_cli_runs"

# ---- 4. ships disabled, and says so instead of erroring ----
[ -e /etc/rc.d/S95hermes-agent ] || fail "[4/9] check_ships_disabled" "post-install did not enable the service"
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q "disabled in /etc/config/hermes" || { echo "$msg"; fail "[4/9] check_ships_disabled" "starting an unconfigured service did not say why"; }
pgrep -f "hermes_cli/main.py gateway" >/dev/null 2>&1 && fail "[4/9] check_ships_disabled" "it started anyway"
echo "PASS [4/9] check_ships_disabled"

# ---- 5. refuses without a key, naming the fix ----
uci set hermes.main.enabled=1 >/dev/null 2>&1; uci commit hermes
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q "no API key" || { echo "$msg"; fail "[5/9] check_refuses_without_key" "did not refuse"; }
echo "$msg" | grep -q "provider.key" || { echo "$msg"; fail "[5/9] check_refuses_without_key" "refused without naming the file to write"; }
echo "PASS [5/9] check_refuses_without_key"

# ---- 6 and 7. the key reaches neither argv nor uci ----
SECRET=sk-gate-canary-value
mkdir -p /etc/hermes-agent
printf '%s' "$SECRET" > /etc/hermes-agent/provider.key
chmod 600 /etc/hermes-agent/provider.key

env HERMES_HOME=/tmp/h OPENAI_API_KEY="$SECRET" OPENAI_BASE_URL=https://example.invalid/v1 \
	HERMES_DISABLE_LAZY_INSTALLS=1 /usr/bin/hermes gateway run >/tmp/gw.log 2>&1 &
GW=$!
sleep 6
if kill -0 "$GW" 2>/dev/null; then
	# Read argv from /proc rather than ps|grep: a grep for the secret matches its own
	# command line and reports a leak that is not there.
	if tr '\0' '\n' < "/proc/$GW/cmdline" | grep -q "$SECRET"; then
		kill "$GW" 2>/dev/null; fail "[6/9] check_key_not_in_argv" "the key is in the process command line"
	fi
	echo "PASS [6/9] check_key_not_in_argv"
	kill "$GW" 2>/dev/null || true
else
	# The gateway not staying up would make the argv check vacuous, and a check that
	# cannot fail is worse than no check.
	sed 's/\x1b\[[0-9;]*m//g' /tmp/gw.log | tail -5
	fail "[6/9] check_key_not_in_argv" "the gateway exited, so nothing was inspected"
fi

uci show hermes 2>/dev/null | grep -q "$SECRET" && fail "[7/9] check_key_not_in_uci" "the key is in UCI"
echo "PASS [7/9] check_key_not_in_uci"

# ---- 8. a hand-edited config survives reinstall ----
# Losing this on a router means losing every setting on a routine upgrade, silently.
marker="# gate canary"
echo "$marker" >> /etc/config/hermes
apk add --allow-untrusted --force-refresh /pkg.apk >/dev/null 2>&1 || apk add --allow-untrusted /pkg.apk >/dev/null 2>&1
grep -qF "$marker" /etc/config/hermes || fail "[8/9] check_config_survives" "the config was overwritten by a reinstall"
echo "PASS [8/9] check_config_survives"

# ---- 9. clean removal ----
apk del hermes-agent >/dev/null 2>&1 || fail "[9/9] check_clean_removal" "apk del failed"
[ -e /usr/bin/hermes ] && fail "[9/9] check_clean_removal" "the launcher is still there"
[ -e /etc/rc.d/S95hermes-agent ] && fail "[9/9] check_clean_removal" "the rc.d link is still there"
[ -d /usr/lib/hermes-agent/site-packages ] && fail "[9/9] check_clean_removal" "site-packages was left behind"
echo "PASS [9/9] check_clean_removal"
CONTAINER

echo "gate-package: all 9 checks passed"
