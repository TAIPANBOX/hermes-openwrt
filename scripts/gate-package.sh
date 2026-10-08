#!/bin/sh
# gate-package.sh -- the package must install on a real OpenWrt and refuse to misbehave.
#
# Invariant:
#
#   "apk installs hermes-agent on a stock OpenWrt 25.12 rootfs, the CLI runs there, the
#   service is enabled but does not start until it is configured, the API key reaches
#   neither the process table nor UCI, and the agent's own user can ping."
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

CHECKS='check_installs check_deps_resolve check_cli_runs check_ships_disabled check_refuses_without_key check_service_command_runs check_key_not_in_argv check_key_not_in_uci check_key_not_in_procd_env check_config_survives check_clean_removal check_upgrade_keeps_boot_start check_agent_can_ping'

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
# From 0.21.5-r3 the package depends on openwrt-mcp, which is not in OpenWrt's feed, so the
# rootfs is handed that apk the way gate-telegram.sh hands it the add-on.
MCP=${MCP:-$("$ROOT/scripts/mcp-apk.sh" "$ARCH")} || exit 1
echo "PASS: artefact $APK (with $(basename "$MCP"))"
echo "-- container checks: $IMAGE ($PLATFORM) --"

# -i is load-bearing. Without it docker hands `sh -s` an empty stdin, the script never
# runs, the container exits 0, and this gate reports every check passed having measured
# nothing at all.
docker run --rm -i --platform "$PLATFORM" -v "$APK:/pkg.apk:ro" -v "$MCP:/mcp.apk:ro" "$IMAGE" /bin/sh -s <<'CONTAINER'
set -eu
fail() { echo "FAIL $1: $2"; exit 1; }

# A booted router has /var symlinked to /tmp with these present; a bare rootfs has
# neither, and without them rc.common's enable silently writes no rc.d link.
mkdir -p /var/lock /var/run /var/state
apk update -q

# ---- 1. installs ----
apk add --allow-untrusted /pkg.apk /mcp.apk >/tmp/add.log 2>&1 || { cat /tmp/add.log; fail "[1/13] check_installs" "apk add failed"; }
apk info -e hermes-agent >/dev/null 2>&1 || fail "[1/13] check_installs" "not registered after install"
echo "PASS [1/13] check_installs"

# ---- 2. dependencies resolve from the real release feed ----
# The package declares runtime dependencies it cannot function without; if any of them
# stopped existing in the feed, apk would have refused above, but an unresolved OPTIONAL
# name would pass silently, so assert each one landed. iputils-ping is left out of this list on
# purpose: it is asserted by what it is for, check 13, so a package that drops it goes red where
# the loss shows (teeth.sh fault 9) rather than here.
for d in python3 python3-pip ca-bundle bash ffmpeg ffprobe ripgrep openwrt-mcp; do
	apk info -e "$d" >/dev/null 2>&1 || fail "[2/13] check_deps_resolve" "$d did not install"
done
echo "PASS [2/13] check_deps_resolve"

# ---- 3. the CLI runs on the router ----
# This is the check the whole musllinux-wheel bet comes down to. If any of the 13
# compiled dependencies were assembled for the wrong libc, it fails here with an
# ImportError rather than on somebody's device.
out=$(/usr/bin/hermes --version 2>&1) || { echo "$out"; fail "[3/13] check_cli_runs" "hermes --version exited non-zero"; }
echo "$out" | grep -q "Hermes Agent" || { echo "$out"; fail "[3/13] check_cli_runs" "unexpected output"; }
# The webbrowser shim. Since 0.21.5 the CLI imports webbrowser lazily, so --version runs
# without it (measured 2026-10-05) and only the gateway and the sign-ins break. So the
# module that needs it for the ChatGPT sign-in is imported here, and the shim's contract
# held: open() answers False on a machine with no screen.
out=$(PYTHONPATH=/usr/lib/hermes-agent/site-packages PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -c \
	'import webbrowser, hermes_cli.auth_codex_browser; r = webbrowser.open("https://example.invalid/pair"); assert r is False, r' 2>&1) \
	|| { echo "$out" | tail -3; fail "[3/13] check_cli_runs" "the ChatGPT sign-in cannot load, or webbrowser.open did not answer False"; }
echo "PASS [3/13] check_cli_runs"

# ---- 4. ships disabled, and says so instead of erroring ----
[ -e /etc/rc.d/S95hermes-agent ] || fail "[4/13] check_ships_disabled" "post-install did not enable the service"
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q "disabled in /etc/config/hermes" || { echo "$msg"; fail "[4/13] check_ships_disabled" "starting an unconfigured service did not say why"; }
pgrep -f "hermes_cli/main.py gateway" >/dev/null 2>&1 && fail "[4/13] check_ships_disabled" "it started anyway"
echo "PASS [4/13] check_ships_disabled"

# ---- 5. refuses without a key, naming the fix ----
uci set hermes.main.enabled=1 >/dev/null 2>&1; uci commit hermes
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q "no API key" || { echo "$msg"; fail "[5/13] check_refuses_without_key" "did not refuse"; }
echo "$msg" | grep -q "provider.key" || { echo "$msg"; fail "[5/13] check_refuses_without_key" "refused without naming the file to write"; }
echo "PASS [5/13] check_refuses_without_key"

# ---- 6. the command the init actually builds is one the CLI accepts ----
#
# The check that was missing, and its absence shipped a package that could not start.
#
# The init passed `--toolsets a,b,c` to `hermes gateway run`. That flag does not exist on
# that subcommand, so the service died at argument parsing on every start, with the
# configuration the package ships, on every router. Every other check here passed: the
# package installed, the CLI ran, the service refused politely without a key. Nothing
# ever ran the command the init would hand to procd. It was found by looking at the LuCI
# log box in a browser.
#
# procd is not running in a bare rootfs, so its parameter functions are stubbed and the
# real start_service is called. That records the exact argv and environment procd would
# have been given, with no second copy of the truth to drift: the init file is the only
# source, and it is read as code rather than parsed as text.
SECRET=sk-gate-canary-value
mkdir -p /etc/hermes-agent /srv/hermes
printf '%s' "$SECRET" > /etc/hermes-agent/provider.key
chmod 600 /etc/hermes-agent/provider.key

# This rootfs has no procd cgroup. The runtime gate separately requires a real
# kernel ceiling and fail-closed startup; this check exercises CLI argv only.
uci set hermes.main.mem_max_mb=0
uci commit hermes
cat > /tmp/fakeprocd.sh <<'STUB'
. /lib/functions.sh
procd_open_instance()     { :; }
procd_close_instance()    { :; }
procd_add_jail_mount_rw() { :; }
procd_add_reload_trigger(){ :; }
procd_set_param() {
	k=$1; shift
	case "$k" in
		command) printf '%s\n' "$@" > /tmp/argv ;;
		env)     printf '%s\n' "$@" > /tmp/envv ;;
	esac
}
procd_append_param() {
	k=$1; shift
	case "$k" in
		command) printf '%s\n' "$@" >> /tmp/argv ;;
		env)     printf '%s\n' "$@" >> /tmp/envv ;;
	esac
}
. /etc/init.d/hermes-agent
start_service
STUB
sh /tmp/fakeprocd.sh >/tmp/fp.log 2>&1 || { cat /tmp/fp.log; fail "[6/13] check_service_command_runs" "start_service did not complete"; }
[ -s /tmp/argv ] || { cat /tmp/fp.log; fail "[6/13] check_service_command_runs" "the init built no command at all, so this check measured nothing"; }

# Run exactly that, with exactly that environment, and require it to still be alive.
# A gateway that exits inside its first seconds against an unreachable endpoint is one
# that failed before it ever tried to reach it.
#
# The clock starts at the EXEC, not at launch. The wrapper runs three Python helpers (the
# memory ceiling, the UCI bridge, the preflight) before it execs the gateway, and the
# gateway then imports its way to argument parsing. On the emulated aarch64 leg of CI the
# two together outlast the fixed ten seconds this check used to wait from launch (the
# exec came at about 4 s, and `hermes --version` alone takes 6.3 s there), so a gateway
# that died at argument parsing still looked alive, and teeth.sh fault 4 left this check
# green on 2026-09-24. After the exec the process is polled, so a gateway that dies says
# when, and 30 s leaves several times the start-up it has to outlast. A zombie counts as
# dead.
set -- $(cat /tmp/argv)
t0=$(date +%s)
# shellcheck disable=SC2046
env $(cat /tmp/envv) "$@" >/tmp/svc.log 2>&1 &
SVC=$!
alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null; }
svc_fail() {
	echo "argv:"; sed 's/^/  /' /tmp/argv
	sed 's/\x1b\[[0-9;]*m//g' /tmp/svc.log | tail -8
	fail "[6/13] check_service_command_runs" "$1"
}
until tr '\0' ' ' < "/proc/$SVC/cmdline" 2>/dev/null | grep -q 'gateway run'; do
	alive "$SVC" || svc_fail "the command exited before this check saw it start the gateway"
	[ $(($(date +%s) - t0)) -lt 180 ] || svc_fail "the wrapper did not reach the gateway within 180 s"
	sleep 1
done
t1=$(date +%s)
while [ $(($(date +%s) - t1)) -lt 30 ]; do
	sleep 1
	alive "$SVC" || svc_fail "the gateway exited $(($(date +%s) - t1)) s after the wrapper started it"
done
# what the running gateway's own command line holds, for check 7
tr '\0' '\n' < "/proc/$SVC/cmdline" > /tmp/svc.cmdline 2>/dev/null
kill "$SVC" 2>/dev/null || true
echo "PASS [6/13] check_service_command_runs ($(wc -l < /tmp/argv | tr -d ' ') argv words, $(wc -l < /tmp/envv | tr -d ' ') env entries; gateway after $((t1 - t0)) s, up 30 s)"

# ---- 7 and 8. the key reaches neither argv nor uci ----
# The command the init hands procd (built in check 6 with this same key in the key file),
# and the gateway that command started, carry the key's path at most, never the key.
SECRET=sk-gate-canary-value
grep -qF "$SECRET" /tmp/argv && fail "[7/13] check_key_not_in_argv" "the init hands procd the key itself on the command line"
[ -s /tmp/svc.cmdline ] || fail "[7/13] check_key_not_in_argv" "measured nothing: the gateway check 6 started left no command line to read"
grep -qF "$SECRET" /tmp/svc.cmdline && fail "[7/13] check_key_not_in_argv" "the key is on the command line of the gateway the init's command started"
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
		kill "$GW" 2>/dev/null; fail "[7/13] check_key_not_in_argv" "the key is in the process command line"
	fi
	echo "PASS [7/13] check_key_not_in_argv (the init's command, the gateway it started, and one started by hand)"
	kill "$GW" 2>/dev/null || true
else
	# The gateway not staying up would make the argv check vacuous, and a check that
	# cannot fail is worse than no check.
	sed 's/\x1b\[[0-9;]*m//g' /tmp/gw.log | tail -5
	fail "[7/13] check_key_not_in_argv" "the gateway exited, so nothing was inspected"
fi

uci show hermes 2>/dev/null | grep -q "$SECRET" && fail "[8/13] check_key_not_in_uci" "the key is in UCI"
echo "PASS [8/13] check_key_not_in_uci"

# ---- 9. the key does not reach procd's service table ----
#
# Found on real hardware on 2026-09-13, after argv and uci had been clean for months:
# the init passes the key with `procd_set_param env`, and procd then hands that whole
# environment back to anyone who can ask ubus:
#
#   ubus call service list '{"name":"hermes-agent"}'   ->   "OPENAI_API_KEY": "sk-..."
#
# /proc/<pid>/environ is root-only, which is what the older checks relied on, but ubus is
# a wider surface: rpcd ACLs can grant a LuCI session access to it. So the env block the
# init builds is inspected directly, using the same fake-procd harness the service
# command check already uses, and the secret must not be in it.
if [ -s /tmp/envv ]; then
	if grep -q "$SECRET" /tmp/envv; then
		fail "[9/13] check_key_not_in_procd_env" "the key is in the procd env block, so ubus call service list exposes it"
	fi
	echo "PASS [9/13] check_key_not_in_procd_env"
else
	fail "[9/13] check_key_not_in_procd_env" "no env block was captured, so this check measured nothing"
fi

# ---- 8. a hand-edited config survives reinstall ----
# Losing this on a router means losing every setting on a reinstall, silently. This is the
# install path (post-install); what an upgrade's post-upgrade does to the start at boot is
# check 12, and its effect on this file is not checked.
# Adding the same file again rewrites nothing (apk 3.0.5 answers OK and leaves every file as it
# is), so the reinstall is a removal and an install, and a probe in one of the package's own
# files proves the install really wrote them again.
marker="# gate canary"
echo "$marker" >> /etc/config/hermes
echo "# reinstall probe" >> /usr/sbin/hermes-gateway
apk del hermes-agent >/dev/null 2>&1 || fail "[10/13] check_config_survives" "apk del failed"
apk add --allow-untrusted /pkg.apk >/dev/null 2>&1 || fail "[10/13] check_config_survives" "the package would not install again"
grep -q "reinstall probe" /usr/sbin/hermes-gateway 2>/dev/null && fail "[10/13] check_config_survives" "measured nothing: the reinstall wrote none of the package's files again"
grep -qF "$marker" /etc/config/hermes || fail "[10/13] check_config_survives" "the config was overwritten by a reinstall"
echo "PASS [10/13] check_config_survives"

# ---- 9. clean removal ----
# What "clean" means for the hermes user and group, since 0.21.5-r3 (@decided 2026-10-01):
# they are NOT removed. Files that account owns (the agent's sessions, in the data directory
# the package never deletes) stay on disk, and a user later handed the same id would own
# them. So removal leaves the account, a reinstall finds it and keeps its id, and neither
# ever leaves it twice.
HUID=$(grep '^hermes:' /etc/passwd | cut -d: -f3)
[ -n "$HUID" ] || fail "[11/13] check_clean_removal" "the install created no hermes user, so there is nothing to leave behind"
apk del hermes-agent >/dev/null 2>&1 || fail "[11/13] check_clean_removal" "apk del failed"
[ -e /usr/bin/hermes ] && fail "[11/13] check_clean_removal" "the launcher is still there"
[ -e /usr/libexec/hermes-drop ] && fail "[11/13] check_clean_removal" "hermes-drop is still there"
[ -e /etc/rc.d/S95hermes-agent ] && fail "[11/13] check_clean_removal" "the rc.d link is still there"
[ -d /usr/lib/hermes-agent/site-packages ] && fail "[11/13] check_clean_removal" "site-packages was left behind"
[ "$(grep '^hermes:' /etc/passwd | cut -d: -f3)" = "$HUID" ] || fail "[11/13] check_clean_removal" "removal took the hermes user, or changed its id"
grep -q '^hermes:' /etc/group || fail "[11/13] check_clean_removal" "removal took the hermes group"
apk add --allow-untrusted /pkg.apk /mcp.apk >/tmp/readd.log 2>&1 || { cat /tmp/readd.log; fail "[11/13] check_clean_removal" "the package would not install again after removal"; }
[ "$(grep -c '^hermes:' /etc/passwd)" = 1 ] && [ "$(grep -c '^hermes:' /etc/group)" = 1 ] && [ "$(grep -c '^hermes:' /etc/shadow)" = 1 ] \
	|| fail "[11/13] check_clean_removal" "reinstalling left more than one hermes account"
[ "$(grep '^hermes:' /etc/passwd | cut -d: -f3)" = "$HUID" ] || fail "[11/13] check_clean_removal" "reinstalling gave the hermes user another id"
echo "PASS [11/13] check_clean_removal (account kept across removal and reinstall, uid $HUID)"

# ---- 12. an upgrade leaves the start at boot as the owner set it ----
# OpenWrt's own default_postinst enables a service when it is installed and not when it is
# upgraded (PKG_UPGRADE=1). This package's post-upgrade ran the same enable as its
# post-install, so every apk upgrade switched the start at boot back on, an owner's
# `disable` undone (a Brume 2, 2026-10-05, upgrading from the feed). The script run here is
# the one apk keeps for the installed package and runs on the next upgrade.
mkdir -p /tmp/pkgscripts && tar -xzf /lib/apk/db/scripts.tar.gz -C /tmp/pkgscripts 2>/dev/null
pu=$(ls /tmp/pkgscripts/hermes-agent-[0-9]*.post-upgrade 2>/dev/null | head -n 1)
[ -n "$pu" ] || fail "[12/13] check_upgrade_keeps_boot_start" "measured nothing: apk keeps no post-upgrade script for hermes-agent"
/etc/init.d/hermes-agent disable
[ ! -e /etc/rc.d/S95hermes-agent ] || fail "[12/13] check_upgrade_keeps_boot_start" "the start at boot could not be switched off to begin with"
sh "$pu" >/tmp/post-upgrade.log 2>&1 || { cat /tmp/post-upgrade.log; fail "[12/13] check_upgrade_keeps_boot_start" "the post-upgrade script failed"; }
[ -e /etc/rc.d/S95hermes-agent ] && fail "[12/13] check_upgrade_keeps_boot_start" "an upgrade switched the start at boot back on after the owner had switched it off"
/etc/init.d/hermes-agent enable
sh "$pu" >/tmp/post-upgrade.log 2>&1 || { cat /tmp/post-upgrade.log; fail "[12/13] check_upgrade_keeps_boot_start" "the post-upgrade script failed"; }
[ -e /etc/rc.d/S95hermes-agent ] || fail "[12/13] check_upgrade_keeps_boot_start" "an upgrade switched the start at boot off"
echo "PASS [12/13] check_upgrade_keeps_boot_start (off stays off, on stays on)"

# ---- 13. the agent can ping ----
# The first command of any network diagnosis. BusyBox's ping opens a raw socket, which only root
# may, and since 0.21.5-r3 the agent runs as `hermes`, so on a clean install every ping it ran
# answered "permission denied (are you root?)" and the model reported the internet as
# unreachable (a Flint 2, 2026-10-08). The ping is run the way the agent's terminal runs one: as
# `hermes`, through the package's own hermes-drop, on the PATH procd gives the service, so the
# check reads whichever ping that PATH finds first.
[ -x /usr/libexec/hermes-drop ] && id hermes >/dev/null 2>&1 \
	|| fail "[13/13] check_agent_can_ping" "measured nothing: no hermes user or no hermes-drop to run the ping as"
out=$(env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/python3 -I -B /usr/libexec/hermes-drop hermes \
	/bin/sh -c 'echo "uid=$(id -u) ping=$(command -v ping)"; ping -c 1 -W 2 127.0.0.1' 2>&1) || true
echo "$out" | grep -q "^uid=$(id -u hermes) " \
	|| { echo "$out" | tail -3; fail "[13/13] check_agent_can_ping" "measured nothing: the ping did not run as hermes"; }
echo "$out" | grep -q ' 0% packet loss' \
	|| { echo "$out" | tail -3; fail "[13/13] check_agent_can_ping" "the agent's user cannot ping, so a network diagnosis fails at its first command"; }
echo "PASS [13/13] check_agent_can_ping ($(echo "$out" | sed -n 's/^uid=[0-9]* ping=//p'))"
CONTAINER

echo "gate-package: all 13 checks passed"
