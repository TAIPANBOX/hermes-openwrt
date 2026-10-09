#!/bin/sh
# gate-unlock.sh -- the agent runs without root, and a change to the router needs its
# owner's say-so. The checks behind features/unlock.feature, run in OpenWrt's own rootfs.
#
# Invariant:
#
#   "The gateway and every process it starts run as the unprivileged user hermes unless
#   the profile says root; the keys stay readable by root only; the agent reads the router
#   freely through openwrt-mcp, and every change is refused until a second factor opens an
#   unlock for that one agent, with nothing configured meaning nothing can change."
#
# What is installed and what is stood in for. The packages are installed from their apks
# into the rootfs (hermes-agent and openwrt-mcp, which it depends on), and every file this
# gate reads or runs is the installed one. What a container lacks is a router: there is no
# procd, no ubusd and no log daemon. Where the package asks procd to run something, the
# gate runs the installed init under stubbed procd functions and executes the command and
# environment procd would have been handed (the same harness gate-package.sh uses), and
# openwrt-mcp's daemon is started the same way from ITS installed init. `ubus` and
# `logread`, which that daemon shells out to, are answered by small stand-ins on its PATH,
# so what is proven about reads and changes is the policy, the pairing, the second factor
# and the rollback state, not ubus. Every statement below that says "refused" is the
# daemon's own refusal, over its own HTTP endpoint, with the token the package paired.
#
# This gate is red until the feature is complete. Each scenario in
# features/unlock.feature names one check; one that is not built yet prints NOT IMPLEMENTED
# and fails, so a green run can only mean everything the feature promises is proven. With the
# LuCI Security page and the SSH enrolment (stage 5) there is no such check left.
#
# The Hermes-side half (stage 4) runs the installed gateway for real: the init's own command
# and environment, through the wrapper that drops root, with Telegram on, the real adapter,
# the real plugin and the real openwrt-mcp daemon. Only the two services across the network
# are stood in for, by scripts/unlock-harness.py: Telegram's Bot API, which records what the
# bot sent and deleted, and a model endpoint, which records every request it is sent. "Never
# reaches the model" is asserted on those recorded requests and "never in a log" on the files
# the gateway, the agent and the daemon wrote with the gateway logging at DEBUG.
#
#   gate-unlock.sh                  all checks
#   LUCI=/path/luci-app-hermes.apk  another build of the LuCI app (the Security page's backend)
#   ONLY="check_a check_b" ...      just those (the teeth use this)
#   APK=/path/hermes-agent.apk      another build of the base package
#   TGAPK=/path/addon.apk           another build of the Telegram add-on
#   HARNESS=/path/harness.py        another harness (the red-first runs use one whose
#                                   precondition, that the plugin is wired, is removed, so
#                                   each check fails on what it asserts)
#   OVERLAY=/dir                    files copied over the installed ones before the checks
#                                   (teeth-unlock.sh plants its faults this way)
#   NOT_BUILT="check_x"             names run as "not built yet": NOT IMPLEMENTED, red (teeth-unlock
#                                   uses this to prove that a scenario with no check cannot pass)

#   gate-unlock.sh --selftest       the check names, for gate-scenarios-bound.sh
set -eu

IMPLEMENTED='check_gateway_runs_as_hermes_user check_key_files_root_only check_memory_ceiling_non_root check_upgrade_hands_data_dir_to_hermes check_root_profile_is_opt_in_and_warned check_fresh_router_without_srv_starts check_unreachable_parent_is_named check_reads_need_no_unlock check_change_refused_while_locked check_no_factor_means_no_changes check_unlock_tools_hidden_from_model check_unlock_is_per_agent check_rollback_survives_reboot check_change_policy_hands_out_no_private_key check_window_changes_settings_never_runs_commands check_window_cannot_reach_the_agents_own_config check_no_change_policy_without_code_exec_refusal check_wireless_and_network_reads_are_redacted check_wide_reads_only_from_a_daemon_that_redacts check_daemon_from_before_the_upgrade_gets_no_wide_reads check_no_package_policy_from_a_daemon_from_before_the_upgrade check_package_install_needs_the_unlock check_scheduled_job_cannot_change check_pin_alone_unlocks check_code_alone_unlocks check_pin_and_code_both_required check_pin_stored_as_slow_hash check_wrong_attempts_lock_out check_code_works_once check_unlock_window_ends check_lock_closes_at_once check_unlock_message_deleted_and_never_reaches_model check_unlock_while_busy_never_reaches_model check_bare_code_is_an_unlock_attempt check_secret_in_no_log check_unlock_refused_in_group check_unlock_only_from_allowlist check_edited_unlock_never_reaches_model check_agent_told_window_is_open check_agent_not_told_after_window_ends check_luci_enrol_shows_qr_and_verifies check_cli_enrol_prints_qr check_luci_pin_write_only'
# Nothing is left to build: stage 4 (the unlock from Telegram) and stage 5 (the LuCI Security page
# and the SSH enrolment) are both in IMPLEMENTED. The two lists stay, empty, because a scenario
# added before its check is written has to be red and not skipped, and this is where it goes.
STAGE4=''
STAGE5=''

if [ "${1:-}" = "--selftest" ]; then
	n=0
	for c in $IMPLEMENTED $STAGE4 $STAGE5; do echo "$c"; n=$((n + 1)); done
	[ "$n" -gt 0 ] || { echo "measured nothing" >&2; exit 1; }
	exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
LINE=${RELEASE%.*}
case "$ARCH" in
	x86_64) IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:x86-64-$RELEASE} ;;
	*)      IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:$ARCH-$RELEASE} ;;
esac
PLATFORM=${PLATFORM:-linux/$ARCH}
BUILD_DIR="$ROOT/build/$LINE/$ARCH"

# The per-architecture build directory, not the repository root: an apk's name carries no
# architecture, so the root holds whichever build finished last (see gate-package.sh).
APK=${APK:-$(ls -t "$BUILD_DIR"/hermes-agent-[0-9]*.apk 2>/dev/null | head -1 || true)}
[ -n "$APK" ] && [ -f "$APK" ] || {
	echo "FAIL: no package found. Build it: ./package/hermes-agent/build-in-container.sh $ARCH"; exit 1; }
MCP=$("$ROOT/scripts/mcp-apk.sh" "$ARCH") || exit 1
# The Hermes-side checks run the real Telegram adapter, which needs the add-on's library. A gate
# run without one still runs every other check and fails the Telegram ones by name.
TGAPK=${TGAPK:-$(ls -t "$BUILD_DIR-telegram"/hermes-agent-telegram-*.apk 2>/dev/null | head -1 || true)}
HARNESS=${HARNESS:-$ROOT/scripts/unlock-harness.py}
# The LuCI app is architecture-neutral, so its one build directory is unambiguous. Its rpcd
# backend is what the Security page calls (stage 5).
LUCI=${LUCI:-$(ls -t "$ROOT"/build/luci-app-hermes-apk/luci-app-hermes-*.apk 2>/dev/null | head -1 || true)}
[ -n "$LUCI" ] && [ -f "$LUCI" ] || {
	echo "FAIL: no luci-app-hermes package found. Build it: ./package/luci-app-hermes/build.sh"; exit 1; }
TG_ARGS=""
[ -n "$TGAPK" ] && [ -f "$TGAPK" ] && TG_ARGS="-v $TGAPK:/tg.apk:ro"
echo "PASS: artefacts $(basename "$APK"), $(basename "$MCP")${TGAPK:+, $(basename "$TGAPK")} and $(basename "$LUCI")"
echo "-- container checks: $IMAGE ($PLATFORM) --"

OVERLAY_ARGS=""
[ -n "${OVERLAY:-}" ] && OVERLAY_ARGS="-v $OVERLAY:/overlay:ro"
# -i is load-bearing, as in every gate here: without it `sh -s` reads an empty stdin and
# the container exits 0 having run nothing. --privileged and a private cgroup namespace
# for the memory ceiling, exactly as gate-runtime.sh has them: the root cgroup in here is
# the disposable container, never the host's.
# shellcheck disable=SC2086
docker run -v "$ROOT/scripts/apk-retry.sh:/apk-retry.sh:ro" ${APK_CACHE:+-v "$APK_CACHE:/apk-cache"} --rm -i --platform "$PLATFORM" --privileged --cgroupns private --memory 2g \
	-e ONLY="${ONLY:-}" -e IMPLEMENTED="$IMPLEMENTED" -e STAGE4="$STAGE4" -e STAGE5="${STAGE5:-}${NOT_BUILT:+ $NOT_BUILT}" \
	-v "$APK:/pkg.apk:ro" -v "$MCP:/mcp.apk:ro" -v "$LUCI:/luci.apk:ro" $TG_ARGS -v "$HARNESS:/harness.py:ro" \
	-v "$ROOT/scripts/security-harness.py:/sec/security-harness.py:ro" -v "$ROOT/scripts/qr_decode.py:/sec/qr_decode.py:ro" \
	-v "$ROOT/README.md:/README.md:ro" $OVERLAY_ARGS "$IMAGE" /bin/sh -s <<'CONTAINER'
. /apk-retry.sh  # apk retries a download the feed cut off; see the file
set -u
mkdir -p /var/lock /var/run /var/state /stubs /tmp/pristine
# A booted router's /tmp is a world-writable tmpfs with the sticky bit; this image's is a
# plain directory only root can write in. The agent writes there (a tool's scratch files).
chmod 1777 /tmp
apk update -q
apk add --allow-untrusted /pkg.apk /mcp.apk /luci.apk $([ -f /tg.apk ] && echo /tg.apk) >/tmp/install.log 2>&1 || { cat /tmp/install.log; echo "FAIL setup: the packages would not install"; exit 1; }
# Package installation is complete; nothing below needs more than loopback.
ip link set eth0 down 2>/dev/null || true
# The harness leaves the root cgroup before a domain controller is enabled in it.
mkdir -p /sys/fs/cgroup/harness
echo $$ > /sys/fs/cgroup/harness/cgroup.procs

if [ -d /overlay ]; then
	cp -R /overlay/. /
	echo "overlay applied: $(cd /overlay && find . -type f | sed 's|^\./||' | tr '\n' ' ')"
fi
cp /etc/config/hermes /tmp/pristine/hermes.config
cp /etc/config/openwrt-mcp /tmp/pristine/mcp.config
cp /usr/bin/hermes /tmp/pristine/hermes.bin
export PYTHONPATH=/usr/lib/hermes-agent/site-packages PYTHONDONTWRITEBYTECODE=1

# ---- what a router has and a container does not ----
cat > /stubs/ubus <<'EOF'
#!/bin/sh
# Every call the daemon let through, for the checks that ask whether a refused one got here.
echo "$*" >> /tmp/ubus.calls
case "$*" in
	"call system board") echo '{"kernel":"6.12","hostname":"gate-router","model":"gate stand-in"}' ;;
	"call network.interface dump") echo '{"interface":[{"interface":"lan","up":true,"proto":"static"}]}' ;;
	# What netifd answers here holds each Wi-Fi interface's configuration, its key included, and
	# openwrt-mcp does not redact ubus answers: so nothing may grant it.
	"call network.wireless status") echo '{"radio0":{"interfaces":[{"section":"main","config":{"ssid":"gate","key":"GATE-WIFI-KEY-CANARY"}}]}}' ;;
	"call uci reload_config"*) echo '{}' ;;
	# What an open window may run: a reload of the network, a service restarted.
	"call network reload"|"call rc init"*) echo '{}' ;;
	*) echo "Command failed: Not found" >&2; exit 4 ;;
esac
EOF
printf 'gate log line one\ngate log line two\n' > /stubs/log
cat > /stubs/logread <<'EOF'
#!/bin/sh
cat /stubs/log
EOF
chmod +x /stubs/ubus /stubs/logread

# A standard-library MCP client: initialize, then one call. Exit 0 with the text when the
# tool answered, 3 with the text when it refused, so a check reads "was it allowed".
cat > /tmp/mcpcall.py <<'EOF'
import json, sys, urllib.request
URL = "http://127.0.0.1:8730/mcp"
def post(token, body, session=None):
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(URL, json.dumps(body).encode(), headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw, sid = resp.read().decode(), resp.headers.get("Mcp-Session-Id")
    for line in raw.splitlines():
        if line.startswith("data:"):
            raw = line[5:].strip()
            break
    return (json.loads(raw) if raw.strip() else None), sid
token, tool = sys.argv[1], sys.argv[2]
_, sid = post(token, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "gate", "version": "0"}}})
post(token, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
res, _ = post(token, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": args}}, sid)
r = res["result"]
print("".join(c.get("text", "") for c in r.get("content", [])))
sys.exit(3 if r.get("isError") else 0)
EOF

# ---- helpers ----
TOTAL=$(echo "$IMPLEMENTED $STAGE4 $STAGE5" | wc -w)
CUR=""
pass() { echo "PASS $CUR${1:+ ($1)}"; : > /tmp/verdict; exit 0; }
fail() { echo "FAIL $CUR: $*"; exit 1; }

uid_of() { grep "^$1:" /etc/passwd | cut -d: -f3; }
gid_of() { grep "^$1:" /etc/passwd | cut -d: -f4; }
# Owner of a path as a numeric id, without stat (busybox here has none).
owner_of() { set -- $(ls -ldn "$1"); echo "$3"; }
group_of() { set -- $(ls -ldn "$1"); echo "$4"; }
mode_of()  { set -- $(ls -ld "$1"); echo "$1"; }

# Back to the state right after install, so no check depends on another.
reset() {
	daemon_stop
	# The state directory is emptied, not removed: a symlink put there (a state directory on
	# RAM, which teeth-unlock.sh plants) is part of the system under test and must survive.
	mkdir -p /etc/openwrt-mcp && chmod 700 /etc/openwrt-mcp
	rm -rf /etc/openwrt-mcp/* /etc/openwrt-mcp/.[!.]* /srv/hermes /tmp/argv /tmp/envv /tmp/probe.out /tmp/start.log /tmp/openwrt-mcp-rollback-* /tmp/h /tmp/totp.secret /tmp/totp.pending /tmp/mcp-shim.log /tmp/sec.png /tmp/rpcd.log /tmp/ubusd.log
	cp /tmp/pristine/hermes.config /etc/config/hermes
	cp /tmp/pristine/mcp.config /etc/config/openwrt-mcp
	cp /tmp/pristine/hermes.bin /usr/bin/hermes
	rm -f /etc/hermes-agent/*
	cat > /etc/config/network <<'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.77.1'

config interface 'wg0'
	option proto 'wireguard'
	option private_key 'GATE-WIREGUARD-PRIVATE-KEY-CANARY'
EOF
	cat > /etc/config/system <<'EOF'
config system
	option hostname 'gate-router'
	option description 'baseline-gate'
EOF
	printf "config dnsmasq\n\toption domain 'lan'\n" > /etc/config/dhcp
	printf "config defaults\n\toption input 'REJECT'\n" > /etc/config/firewall
	printf "config wifi-iface 'main'\n\toption ssid 'gate'\n\toption key 'GATE-WIFI-KEY-CANARY'\n" > /etc/config/wireless
	printf '%s' 'sk-gate-provider-key-canary' > /etc/hermes-agent/provider.key
	chmod 600 /etc/hermes-agent/provider.key
}

# Set the options a check cares about; everything else is the shipped default.
#   configure <profile|-> <factor|->      "-" leaves it unset
configure() {
	uci set hermes.main.enabled=1
	uci set hermes.main.mem_max_mb="${MEM:-0}"
	uci set hermes.main.data_dir=/srv/hermes
	if [ "$1" = "-" ]; then uci -q delete hermes.main.profile || true; else uci set hermes.main.profile="$1"; fi
	if [ "$2" != "-" ]; then
		uci set hermes.security=security
		uci set hermes.security.factor="$2"
	fi
	uci commit hermes
}

# The init's own start_service, under the same stubbed procd functions gate-package.sh
# uses. What procd would have been handed lands in /tmp/argv and /tmp/envv, what the init
# said in /tmp/start.log, and the status is the init's.
start_instance() {
	rm -f /tmp/argv /tmp/envv
	cat > /tmp/fakeprocd.sh <<'STUB'
. /lib/functions.sh
procd_open_instance()     { :; }
procd_close_instance()    { :; }
procd_add_jail_mount_rw() { :; }
procd_add_reload_trigger(){ :; }
procd_set_param() { k=$1; shift; case "$k" in command) printf '%s\n' "$@" > /tmp/argv ;; env) printf '%s\n' "$@" > /tmp/envv ;; esac; }
procd_append_param() { k=$1; shift; case "$k" in command) printf '%s\n' "$@" >> /tmp/argv ;; env) printf '%s\n' "$@" >> /tmp/envv ;; esac; }
. /etc/init.d/hermes-agent
start_service
STUB
	sh /tmp/fakeprocd.sh >/tmp/start.log 2>&1
}
started() { start_instance || { cat /tmp/start.log; fail "the init refused to start: $(tail -n 1 /tmp/start.log)"; }; [ -s /tmp/argv ] || fail "the init built no command"; }

# Run the command and environment the init handed procd, in front of the wrapper, with
# extra KEY=VALUE words added.
run_wrapper() {
	extra="$*"
	set -- $(cat /tmp/argv)
	# shellcheck disable=SC2046
	env $(cat /tmp/envv) $extra "$@"
}

# Stand-ins for /usr/bin/hermes: what the wrapper's last line runs. Each records what
# it saw to $PROBE_OUT.
probe_ids() {
	cat > /usr/bin/hermes <<'EOF'
#!/bin/sh
{
	grep -E '^(Uid|Gid|Groups):' /proc/self/status
	echo "ARGV=$*"
	echo "HOME=$HOME USER=${USER:-} LOGNAME=${LOGNAME:-}"
	echo "CGROUP=$(sed -n 's/^0:://p' /proc/self/cgroup)"
} > "$PROBE_OUT"
EOF
	chmod 755 /usr/bin/hermes
}
# The agent's own terminal tool, upstream's code, run as the gateway runs it.
probe_terminal() {
	cat > /usr/bin/hermes <<'EOF'
#!/bin/sh
cd /tmp 2>/dev/null
python3 - > "$PROBE_OUT" <<'PY'
import json
from tools.terminal_tool import terminal_tool
r = json.loads(terminal_tool(command="grep -E '^(Uid|Gid|Groups):' /proc/self/status", timeout=30))
print(r["output"])
PY
EOF
	chmod 755 /usr/bin/hermes
}
# What upstream registers for the model from the MCP connection the package wrote: the raw
# catalog of every enabled tool, which is what the model reaches directly or through
# upstream's tool_search and tool_call bridge (that bridge only reads this catalog, and
# replaces it in the model's own list when the tools would take too much of its context).
probe_tools() {
	cat > /usr/bin/hermes <<'EOF'
#!/bin/sh
cd /tmp 2>/dev/null
python3 - > "$PROBE_OUT" 2>/tmp/probe.err <<'PY'
import json, yaml
from hermes_cli.config import get_config_path
from hermes_cli.tools_config import _get_platform_tools
from tools.mcp_tool_discovery import discover_mcp_tools
import model_tools
discover_mcp_tools()
config = yaml.safe_load(get_config_path().read_text())
enabled = sorted(_get_platform_tools(config, "telegram"))
disabled = (config.get("agent") or {}).get("disabled_toolsets") or []
defs = model_tools.get_tool_definitions(enabled_toolsets=enabled, disabled_toolsets=disabled, quiet_mode=True,
                                        skip_tool_search_assembly=True)
print(json.dumps(sorted(d["function"]["name"] for d in defs if d["function"]["name"].startswith("mcp__openwrt__"))))
PY
EOF
	chmod 755 /usr/bin/hermes
}

# openwrt-mcp's daemon, started the way ITS init starts it: the init under stubbed procd
# functions, then the command it built, with ubus and logread answered by the stand-ins.
daemon_start() {
	daemon_stop
	cat > /tmp/fakemcp.sh <<'STUB'
. /lib/functions.sh
procd_open_instance()  { :; }
procd_close_instance() { :; }
procd_set_param() { k=$1; shift; [ "$k" = command ] && printf '%s\n' "$@" > /tmp/mcp.argv; return 0; }
. /etc/init.d/openwrt-mcp
start_service
STUB
	rm -f /tmp/mcp.argv
	sh /tmp/fakemcp.sh >/dev/null 2>&1
	[ -s /tmp/mcp.argv ] || fail "openwrt-mcp's own init built no command"
	set -- $(cat /tmp/mcp.argv)
	PATH=/stubs:$PATH "$@" >/tmp/mcp.log 2>&1 &
	echo $! > /tmp/mcp.pid
	i=0
	until python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8730/health", timeout=2)' 2>/dev/null; do
		i=$((i + 1)); [ "$i" -lt 30 ] || { cat /tmp/mcp.log; fail "openwrt-mcp did not come up"; }
		sleep 1
	done
}
daemon_stop() {
	if [ -f /tmp/mcp.pid ]; then kill "$(cat /tmp/mcp.pid)" 2>/dev/null || true; rm -f /tmp/mcp.pid; fi
	# busybox here has no pkill.
	for p in $(pgrep -x openwrt-mcp 2>/dev/null); do kill "$p" 2>/dev/null || true; done
	sleep 1
}
# mcp <token-file> <tool> [json]: prints the text; status 0 answered, 3 refused.
mcp() {
	args=${3:-}
	[ -n "$args" ] || args='{}'
	python3 /tmp/mcpcall.py "$(cat "$1")" "$2" "$args"
}
# The router's own description option: what the changes in these checks touch.
desc() { uci -q get 'system.@system[0].description'; }
# The owner's PIN, set the way the owner does it.
set_pin() { printf '%s\n' "$2" | openwrt-mcp pin set "$1" >/dev/null || fail "could not set a PIN for $1"; }
TOKEN=/etc/hermes-agent/router-mcp.token
CHANGE='{"changes":[{"config":"system","section":"@system[0]","option":"description","value":"changed-by-gate"}]}'

# ======================================================================= the checks

check_gateway_runs_as_hermes_user() {
	reset; configure - -
	# The account: a locked password, no login shell.
	grep -q '^hermes:' /etc/passwd || fail "the package created no user hermes"
	grep -q '^hermes:' /etc/group || fail "the package created no group hermes"
	[ "$(grep '^hermes:' /etc/passwd | cut -d: -f7)" = /bin/false ] || fail "the hermes user has a login shell: $(grep '^hermes:' /etc/passwd | cut -d: -f7)"
	hash=$(grep '^hermes:' /etc/shadow | cut -d: -f2)
	case "$hash" in x|\*|\!*) ;; *) fail "the hermes user's password field is '$hash', not a locked one" ;; esac
	HU=$(uid_of hermes); HG=$(gid_of hermes)
	[ "$HU" != 0 ] && [ "$HG" != 0 ] || fail "hermes is uid $HU gid $HG"
	started
	# Nothing is lowered by procd: the wrapper starts as root and drops itself.
	grep -q 'hermes-gateway' /tmp/argv || fail "procd is not handed the wrapper"
	# The drop itself: ids, groups, and no way back.
	[ -x /usr/libexec/hermes-drop ] || fail "no /usr/libexec/hermes-drop"
	out=$(/usr/libexec/hermes-drop hermes python3 -c '
import os
print(os.getresuid(), os.getresgid(), os.getgroups())
try:
    os.setuid(0)
except OSError:
    print("setuid(0) refused")
' 2>&1) || fail "hermes-drop failed: $out"
	echo "$out" | grep -q "($HU, $HU, $HU) ($HG, $HG, $HG) \[\]" || fail "after the drop: $out"
	echo "$out" | grep -q 'setuid(0) refused' || fail "root could be taken back: $out"
	# The real gateway, started the way procd starts it. One `sh -c exec`, not a function,
	# so that $! is the very process that becomes the wrapper and then the gateway.
	sh -c 'exec env $(cat /tmp/envv) "$@"' sh $(cat /tmp/argv) >/tmp/svc.log 2>&1 &
	SVC=$!
	i=0
	until tr '\0' ' ' < "/proc/$SVC/cmdline" 2>/dev/null | grep -q 'gateway run'; do
		kill -0 "$SVC" 2>/dev/null || { tail -n 5 /tmp/svc.log; fail "the wrapper exited before the gateway started"; }
		i=$((i + 1)); [ "$i" -lt 180 ] || { tail -n 5 /tmp/svc.log; fail "the gateway did not start in 180 s"; }
		sleep 1
	done
	sleep 3
	kill -0 "$SVC" 2>/dev/null || { tail -n 5 /tmp/svc.log; fail "the gateway died right after starting"; }
	ids=$(grep -E '^(Uid|Gid|Groups):' "/proc/$SVC/status" | tr -s '\t ' ' ')
	kill "$SVC" 2>/dev/null; sleep 1
	echo "$ids" | grep -qx "Uid: $HU $HU $HU $HU" || fail "the gateway's uids are not hermes ($HU): $ids"
	echo "$ids" | grep -qx "Gid: $HG $HG $HG $HG" || fail "the gateway's gids are not hermes ($HG): $ids"
	echo "$ids" | grep -q '^Groups: *$' || fail "the gateway keeps supplementary groups: $ids"
	# A process the agent's own terminal tool starts.
	probe_terminal
	run_wrapper PROBE_OUT=/tmp/probe.out >/tmp/svc.log 2>&1 || { tail -n 5 /tmp/svc.log; fail "the wrapper failed under the terminal probe"; }
	child=$(tr -s '\t ' ' ' < /tmp/probe.out)
	echo "$child" | grep -qx "Uid: $HU $HU $HU $HU" || fail "a tool child's uids are not hermes ($HU): $child"
	echo "$child" | grep -qx "Gid: $HG $HG $HG $HG" || fail "a tool child's gids are not hermes ($HG): $child"
	pass "hermes uid $HU gid $HG; gateway and tool child both"
}

check_key_files_root_only() {
	reset; configure - pin
	started
	printf '%s' '123456789:AAHgateCanaryTokenNotRealAAHgateCanary' > /etc/hermes-agent/telegram.token
	chmod 600 /etc/hermes-agent/telegram.token
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	[ -x /usr/libexec/hermes-drop ] || fail "no /usr/libexec/hermes-drop to run a command as the agent"
	for f in /etc/hermes-agent /etc/hermes-agent/provider.key /etc/hermes-agent/telegram.token "$TOKEN" /etc/openwrt-mcp /etc/openwrt-mcp/tokens; do
		[ -e "$f" ] || fail "$f is missing, so the check would measure nothing"
		[ "$(owner_of "$f")" = 0 ] || fail "$f is not owned by root"
		m=$(mode_of "$f")
		perm=${m#?}
		[ "${perm#???}" = ------ ] || fail "$f is $m, open to more than root"
	done
	for f in /etc/hermes-agent/provider.key /etc/hermes-agent/telegram.token "$TOKEN" /etc/openwrt-mcp/tokens; do
		if /usr/libexec/hermes-drop hermes cat "$f" >/dev/null 2>&1; then fail "a command run as hermes read $f"; fi
	done
	if /usr/libexec/hermes-drop hermes ls /etc/hermes-agent >/dev/null 2>&1; then fail "a command run as hermes listed /etc/hermes-agent"; fi
	# Positive control: the same command, as hermes, does work on what hermes may read.
	/usr/libexec/hermes-drop hermes cat /etc/passwd >/dev/null 2>&1 || fail "hermes cannot read anything, so the refusals above prove nothing"
	pass "provider key, Telegram token, router MCP token and openwrt-mcp's token store: root-only, unreadable as hermes"
}

check_memory_ceiling_non_root() {
	reset; MEM=256 configure - -
	started
	group=/sys/fs/cgroup/services/hermes-agent/instance1
	mkdir -p "$group"
	for n in memory.max memory.swap.max; do [ ! -e "$group/$n" ] || echo max > "$group/$n"; done
	probe_ids
	rm -f /tmp/probe.out
	# The wrapper joins its cgroup the way procd places it there, then runs.
	set -- $(cat /tmp/argv)
	sh -c 'echo $$ > "$1"/cgroup.procs; shift; exec env $(cat /tmp/envv) PROBE_OUT=/tmp/probe.out "$@"' sh "$group" "$@" >/tmp/svc.log 2>&1 \
		|| { cat /tmp/svc.log; fail "the wrapper did not run in its cgroup"; }
	[ -s /tmp/probe.out ] || { cat /tmp/svc.log; fail "the agent never started"; }
	uid=$(sed -n 's/^Uid:[[:space:]]*\([0-9]*\).*/\1/p' /tmp/probe.out)
	[ "$uid" != 0 ] || fail "the agent runs as root"
	[ "$(cat "$group/memory.max")" = 268435456 ] || fail "memory.max is $(cat "$group/memory.max"), not 256 MB"
	[ "$(cat "$group/memory.swap.max")" = 0 ] || fail "memory.swap.max is $(cat "$group/memory.swap.max")"
	[ "$(cat "$group/memory.oom.group")" = 1 ] || fail "memory.oom.group is $(cat "$group/memory.oom.group")"
	grep -q "^CGROUP=/services/hermes-agent/instance1$" /tmp/probe.out || fail "the agent left its cgroup: $(grep ^CGROUP /tmp/probe.out)"
	# The agent cannot lift the ceiling it runs under.
	[ -x /usr/libexec/hermes-drop ] || fail "no /usr/libexec/hermes-drop to run a command as the agent"
	if /usr/libexec/hermes-drop hermes sh -c "echo max > $group/memory.max" 2>/dev/null; then fail "a command run as hermes lifted the memory ceiling"; fi
	[ "$(cat "$group/memory.max")" = 268435456 ] || fail "the ceiling changed"
	pass "memory.max 268435456 applied by root before the drop; agent uid $uid cannot change it"
}

check_upgrade_hands_data_dir_to_hermes() {
	reset; configure - -
	# What the root-era release left: everything owned by root, sessions and jobs inside.
	mkdir -p /srv/hermes/sessions /srv/hermes/cron
	chmod 700 /srv/hermes
	printf 'SQLite format 3 gate-sessions' > /srv/hermes/state.db
	printf '{"jobs":[{"id":"gate"}]}' > /srv/hermes/cron/jobs.json
	printf 'turn one' > /srv/hermes/sessions/s1.json
	printf 'model: root-era\n' > /srv/hermes/config.yaml
	chmod 600 /srv/hermes/config.yaml
	ln -s /etc/passwd /srv/hermes/link-to-passwd
	before=$(cd /srv/hermes && md5sum state.db cron/jobs.json sessions/s1.json | tr '\n' ' ')
	started
	HU=$(uid_of hermes); HG=$(gid_of hermes)
	[ -n "$HU" ] || fail "no user hermes to hand the directory to"
	[ "$(owner_of /srv/hermes)" = "$HU" ] || fail "the data directory is still owned by uid $(owner_of /srv/hermes)"
	for f in state.db cron/jobs.json sessions/s1.json config.yaml sessions cron; do
		[ "$(owner_of "/srv/hermes/$f")" = "$HU" ] && [ "$(group_of "/srv/hermes/$f")" = "$HG" ] || fail "/srv/hermes/$f is not hermes:hermes"
	done
	after=$(cd /srv/hermes && md5sum state.db cron/jobs.json sessions/s1.json | tr '\n' ' ')
	[ "$before" = "$after" ] || fail "the sessions or jobs changed: $before / $after"
	[ "$(mode_of /srv/hermes/config.yaml | cut -c1-10)" = "-rw-------" ] || fail "config.yaml lost its mode"
	[ "$(owner_of /etc/passwd)" = 0 ] || fail "a symlink in the data directory took /etc/passwd's owner with it"
	# And not on every start: a file root drops in later is left as it is.
	: > /srv/hermes/later-root-file
	started
	[ "$(owner_of /srv/hermes/later-root-file)" = 0 ] || fail "the second start walked the whole directory again"
	# What the agent can then do there.
	/usr/libexec/hermes-drop hermes sh -c ': >/srv/hermes/agent-wrote' 2>/dev/null || fail "hermes cannot write in its own data directory"
	pass "owner root -> hermes, files and checksums kept, symlink target untouched, not repeated on the next start"
}

check_root_profile_is_opt_in_and_warned() {
	reset; probe_ids
	# Nothing set: the owner profile, said at the start, and not root.
	configure - -
	started
	grep -q "profile 'owner'" /tmp/start.log || { cat /tmp/start.log; fail "an unset profile did not say it is the owner profile"; }
	run_wrapper PROBE_OUT=/tmp/probe.out >/tmp/svc.log 2>&1 || { cat /tmp/svc.log; fail "the wrapper failed"; }
	grep -q '^Uid:[[:space:]]*0[[:space:]]' /tmp/probe.out && fail "an unset profile ran the agent as root"
	# root, and its old name admin: as root, with a warning that says what that allows.
	for p in root admin; do
		reset; probe_ids; configure "$p" -
		started
		grep -qi "as root" /tmp/start.log || { cat /tmp/start.log; fail "profile $p started without a warning that the agent runs as root"; }
		grep -qi "unlock" /tmp/start.log || { cat /tmp/start.log; fail "the warning for profile $p does not say no unlock applies"; }
		run_wrapper PROBE_OUT=/tmp/probe.out >/tmp/svc.log 2>&1 || { cat /tmp/svc.log; fail "the wrapper failed in profile $p"; }
		grep -q '^Uid:[[:space:]]*0[[:space:]]0[[:space:]]0[[:space:]]0$' /tmp/probe.out || fail "profile $p did not run the agent as root: $(grep ^Uid /tmp/probe.out)"
	done
	# Anything else still refuses.
	reset; configure superuser -
	if start_instance; then fail "an unknown profile started"; fi
	grep -q "owner" /tmp/start.log && grep -q "root" /tmp/start.log || { cat /tmp/start.log; fail "the refusal does not name the valid profiles"; }
	pass "unset -> owner, as hermes; root and admin -> uid 0 with a warning; an unknown value refuses"
}

# A router that has never had a /srv. The images the test routers and this gate run on already
# have one anyone may enter, which is how the init's `mkdir -p` closing it to everyone but root
# went unseen until a QEMU image without one (OpenWrt 25.12.5, armsr) refused to start the agent
# as "cannot write in /srv/hermes". A boot starts the service with a umask of 077, so that is
# what this check runs under: without it the gate's own umask would hide the defect again.
check_fresh_router_without_srv_starts() {
	reset; configure - -
	rm -rf /srv
	[ ! -e /srv ] || fail "could not remove /srv, so this measured nothing"
	umask 077
	started
	m=$(mode_of /srv)
	[ "$m" = drwxr-xr-x ] || fail "/srv was created $m, which the agent's user cannot enter"
	m=$(mode_of /srv/hermes)
	[ "$m" = drwx------ ] || fail "the data directory was created $m, not closed to everyone but its owner"
	HU=$(uid_of hermes)
	[ "$(owner_of /srv/hermes)" = "$HU" ] || fail "the data directory belongs to uid $(owner_of /srv/hermes), not hermes ($HU)"
	[ "$(owner_of /srv)" = 0 ] || fail "/srv belongs to uid $(owner_of /srv), not root"
	# The real gateway, started the way procd starts it, under the same umask.
	sh -c 'exec env $(cat /tmp/envv) "$@"' sh $(cat /tmp/argv) >/tmp/svc.log 2>&1 &
	SVC=$!
	i=0
	until tr '\0' ' ' < "/proc/$SVC/cmdline" 2>/dev/null | grep -q 'gateway run'; do
		kill -0 "$SVC" 2>/dev/null || { tail -n 5 /tmp/svc.log; fail "the wrapper exited before the gateway started"; }
		i=$((i + 1)); [ "$i" -lt 180 ] || { tail -n 5 /tmp/svc.log; fail "the gateway did not start in 180 s"; }
		sleep 1
	done
	sleep 3
	kill -0 "$SVC" 2>/dev/null || { tail -n 5 /tmp/svc.log; fail "the gateway died right after starting"; }
	ids=$(grep -E '^Uid:' "/proc/$SVC/status" | tr -s '\t ' ' ')
	kill "$SVC" 2>/dev/null; sleep 1
	echo "$ids" | grep -qx "Uid: $HU $HU $HU $HU" || fail "the gateway's uids are not hermes ($HU): $ids"
	pass "no /srv before the start: created $(mode_of /srv) root, the data directory drwx------ hermes, and the gateway ran as uid $HU"
}

check_unreachable_parent_is_named() {
	reset; configure - -
	# A /srv that is already there and that only root may enter. The init does not change the mode
	# of a directory it did not make; it says which one stands in the way.
	rm -rf /srv; mkdir /srv; chmod 700 /srv
	if start_instance; then fail "the agent was started with a directory above its data that it cannot enter"; fi
	grep -q "cannot enter /srv[ ,]" /tmp/start.log || { cat /tmp/start.log; fail "the refusal does not name the directory that stands in the way: $(tail -n 1 /tmp/start.log)"; }
	grep -q 'drwx------' /tmp/start.log || { cat /tmp/start.log; fail "the refusal does not give that directory's mode"; }
	[ "$(mode_of /srv)" = drwx------ ] || fail "an existing /srv was changed to $(mode_of /srv)"
	[ "$(owner_of /srv)" = 0 ] || fail "an existing /srv changed hands"
	# Not vacuous: the same configuration starts once /srv can be entered.
	chmod 755 /srv
	started
	pass "refused naming /srv and its mode, /srv left as it was; started once /srv was opened"
}

check_reads_need_no_unlock() {
	reset; configure - pin
	started
	daemon_start
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	out=$(mcp "$TOKEN" ubus_call '{"object":"system","method":"board"}') || fail "system board was refused: $out"
	echo "$out" | grep -q 'gate-router' || fail "system board gave: $out"
	out=$(mcp "$TOKEN" ubus_call '{"object":"network.interface","method":"dump"}') || fail "network.interface dump was refused: $out"
	out=$(mcp "$TOKEN" uci_get '{"config":"system"}') || fail "uci_get system was refused: $out"
	echo "$out" | grep -q 'gate-router' || fail "uci_get system gave: $out"
	out=$(mcp "$TOKEN" uci_get '{"config":"network","section":"lan"}') || fail "uci_get network.lan was refused: $out"
	echo "$out" | grep -q '192.168.77.1' || fail "uci_get network.lan gave: $out"
	for c in dhcp firewall; do
		out=$(mcp "$TOKEN" uci_get "{\"config\":\"$c\"}") || fail "uci_get $c was refused: $out"
	done
	out=$(mcp "$TOKEN" logread) || fail "logread was refused: $out"
	echo "$out" | grep -q 'gate log line one' || fail "logread gave: $out"
	# Wireless and the whole of network, and what keeps their keys out of the answer, are the
	# three checks after check_change_policy_hands_out_no_private_key.
	# Not vacuous: with a factor configured, the same token is refused a change, so the
	# reads above were not answered by something that opens everything.
	if out=$(mcp "$TOKEN" ubus_call '{"object":"network","method":"reload"}'); then fail "network reload was allowed with no unlock: $out"; fi
	echo "$out" | grep -q 'second factor' || fail "network reload was refused, but not for the second factor: $out"
	if out=$(mcp "$TOKEN" exec '{"argv":["id"]}'); then fail "exec was allowed: $out"; fi
	pass "state, interfaces, system, dhcp, firewall, one network section and the log answered with a PIN configured and no unlock; exec refused"
}

check_change_refused_while_locked() {
	reset; configure - pin
	started
	daemon_start
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	if out=$(mcp "$TOKEN" uci_apply "$CHANGE"); then fail "uci_apply was allowed with no unlock: $out"; fi
	echo "$out" | grep -q 'requires a second factor' || fail "uci_apply was refused, but not for the second factor: $out"
	echo "$out" | grep -q 'mfa_unlock' || fail "the refusal does not say how to unlock: $out"
	[ "$(desc)" = baseline-gate ] || fail "the change was applied anyway"
	# The agent is told what to do about it: the owner sends /unlock in the private chat.
	probe_ids
	run_wrapper PROBE_OUT=/tmp/probe.out >/tmp/svc.log 2>&1 || { cat /tmp/svc.log; fail "the wrapper failed"; }
	prompt=$(/usr/libexec/hermes-drop hermes env HERMES_HOME=/srv/hermes python3 -c 'from gateway.run import GatewayRunner; print(GatewayRunner._load_ephemeral_system_prompt())' 2>&1) || fail "could not load the gateway's system prompt: $prompt"
	echo "$prompt" | grep -q '/unlock' || fail "the agent is not told to ask for /unlock"
	echo "$prompt" | grep -qi 'private chat' || fail "the agent is not told to use the private chat"
	echo "$prompt" | grep -qi 'never ask' || fail "the agent is not told never to ask for a PIN or code in a message"
	pass "uci_apply refused for the second factor, nothing changed; the system prompt tells the agent to ask the owner for /unlock"
}

check_no_factor_means_no_changes() {
	reset; configure - -
	started
	daemon_start
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	uci -q show openwrt-mcp | grep -q 'hermes_main_change' && fail "a change policy was written with no factor configured"
	if out=$(mcp "$TOKEN" uci_apply "$CHANGE"); then fail "uci_apply was allowed with no factor configured: $out"; fi
	echo "$out" | grep -q 'no policy grants uci_apply' || fail "uci_apply was refused, but not for want of a policy: $out"
	if out=$(mcp "$TOKEN" ubus_call '{"object":"network","method":"reload"}'); then fail "a ubus change was allowed: $out"; fi
	[ "$(desc)" = baseline-gate ] || fail "the change was applied anyway"
	mcp "$TOKEN" ubus_call '{"object":"system","method":"board"}' >/dev/null || fail "reads stopped working with no factor"
	probe_ids
	run_wrapper PROBE_OUT=/tmp/probe.out >/tmp/svc.log 2>&1 || { cat /tmp/svc.log; fail "the wrapper failed"; }
	prompt=$(/usr/libexec/hermes-drop hermes env HERMES_HOME=/srv/hermes python3 -c 'from gateway.run import GatewayRunner; print(GatewayRunner._load_ephemeral_system_prompt())' 2>&1) || fail "could not load the gateway's system prompt: $prompt"
	echo "$prompt" | grep -q 'LuCI' || fail "the agent is not told a factor has to be set up in LuCI first"
	pass "factor unset: no change policy, every change refused for want of one, reads fine, and the agent says to set a factor up first"
}

# wg_new_client answers with a WireGuard peer's private key and QR. Whatever a tool
# returns goes to the model provider, so the package's change policy must not grant it,
# not even inside an unlock window. An owner who wants it grants it themselves.
check_change_policy_hands_out_no_private_key() {
	reset; configure - pin
	started
	daemon_start
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	uci -q show openwrt-mcp | grep -q 'hermes_main_change' || fail "no change policy was written with a factor set, so this measured nothing"
	uci -q get openwrt-mcp.hermes_main_change.tools | grep -qw wg_new_client && fail "the change policy grants wg_new_client, whose answer is a private key"
	if out=$(mcp "$TOKEN" wg_new_client '{"name":"probe"}'); then fail "wg_new_client was answered: $out"; fi
	pass "factor set: the change policy grants no tool that answers with a private key"
}

check_unlock_tools_hidden_from_model() {
	reset; configure - pin
	started
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	daemon_start
	# Not vacuous: the daemon itself offers both, to any client.
	python3 - <<'PY' || fail "openwrt-mcp does not list mfa_unlock and mfa_lock to begin with, so hiding them proves nothing"
import json, sys, urllib.request
tok = open("/etc/hermes-agent/router-mcp.token").read().strip()
def post(body, sid=None):
    h = {"Authorization": "Bearer " + tok, "Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if sid: h["Mcp-Session-Id"] = sid
    with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8730/mcp", json.dumps(body).encode(), h), timeout=20) as r:
        raw, sid = r.read().decode(), r.headers.get("Mcp-Session-Id")
    for l in raw.splitlines():
        if l.startswith("data:"): raw = l[5:].strip(); break
    return (json.loads(raw) if raw.strip() else None), sid
_, sid = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "gate", "version": "0"}}})
post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
names = {t["name"] for t in post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)[0]["result"]["tools"]}
sys.exit(0 if {"mfa_unlock", "mfa_lock"} <= names else 1)
PY
	probe_tools
	run_wrapper PROBE_OUT=/tmp/probe.out >/tmp/svc.log 2>&1 || { cat /tmp/svc.log; fail "the wrapper failed"; }
	[ -s /tmp/probe.out ] || { cat /tmp/probe.err /tmp/svc.log; fail "upstream registered nothing"; }
	names=$(cat /tmp/probe.out)
	echo "$names" | grep -q 'mcp__openwrt__ubus_call' || { echo "$names"; cat /tmp/probe.err; fail "upstream offers the model no openwrt tools at all, so absence proves nothing"; }
	echo "$names" | grep -q 'mfa_unlock' && fail "the model is offered mfa_unlock: $names"
	echo "$names" | grep -q 'mfa_lock' && fail "the model is offered mfa_lock: $names"
	pass "upstream's registry offers the model $(echo "$names" | grep -o 'mcp__' | wc -l) openwrt tools, neither mfa_unlock nor mfa_lock"
}

check_unlock_is_per_agent() {
	reset; configure - pin
	started
	# A second agent, the way a later release would add one: its own name, token and window.
	sh -c '. /lib/functions.sh; . /etc/init.d/hermes-agent; hermes_mcp_agent other /etc/hermes-agent/other.token pin 15m 5 15m' >/tmp/other.log 2>&1 \
		|| { cat /tmp/other.log; fail "the package cannot set up a second agent"; }
	[ -s /etc/hermes-agent/other.token ] || fail "no token for the second agent"
	cmp -s /etc/hermes-agent/other.token "$TOKEN" && fail "both agents hold the same token"
	set_pin hermes-main 4821
	set_pin hermes-other 4821
	daemon_start
	OTHER=/etc/hermes-agent/other.token
	for t in "$TOKEN" "$OTHER"; do
		if out=$(mcp "$t" uci_apply "$CHANGE"); then fail "a change was allowed before any unlock: $out"; fi
		echo "$out" | grep -q 'requires a second factor' || fail "refused, but not for the second factor: $out"
	done
	out=$(mcp "$TOKEN" mfa_unlock '{"pin":"4821"}') || fail "the owner's PIN did not unlock the first agent: $out"
	out=$(mcp "$TOKEN" uci_apply "$CHANGE") || fail "the first agent was refused after its own unlock: $out"
	echo "$out" | grep -q 'ROLLBACK ARMED' || fail "the first agent's change did not apply: $out"
	if out=$(mcp "$OTHER" uci_apply "$CHANGE"); then fail "the second agent changed the router on the first agent's unlock: $out"; fi
	echo "$out" | grep -q 'requires a second factor' || fail "the second agent was refused, but not for the second factor: $out"
	pass "hermes-main unlocked and changed the router; hermes-other, same owner and PIN, still refused"
}

check_rollback_survives_reboot() {
	reset; configure - pin
	started
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	set_pin hermes-main 4821
	daemon_start
	mcp "$TOKEN" mfa_unlock '{"pin":"4821"}' >/dev/null || fail "could not unlock"
	out=$(mcp "$TOKEN" uci_apply "$CHANGE") || fail "the change was refused after the unlock: $out"
	[ "$(desc)" = changed-by-gate ] || fail "the change did not land"
	# Where the rollback state lives: on flash, under the state directory, not in /tmp.
	ls /etc/openwrt-mcp/rollback/*.tar.gz >/dev/null 2>&1 || fail "no rollback snapshot under /etc/openwrt-mcp/rollback"
	[ -s /etc/openwrt-mcp/pending.json ] || fail "no pending record under /etc/openwrt-mcp"
	# And "under /etc" has to mean on flash: a state directory that is a link into RAM keeps
	# the path and loses the point.
	for f in /etc/openwrt-mcp/rollback /etc/openwrt-mcp/pending.json; do
		real=$(readlink -f "$f")
		case "$real" in /tmp/*|/var/*|/run/*|/dev/shm/*) fail "$f is really $real, which a reboot empties" ;; esac
	done
	ls /tmp/openwrt-mcp-rollback-* /var/tmp/openwrt-mcp-rollback-* >/dev/null 2>&1 && fail "a rollback snapshot is in /tmp, which a reboot empties"
	# A reboot: the daemon dies mid-window and everything in /tmp goes.
	kill -9 "$(cat /tmp/mcp.pid)"; rm -f /tmp/mcp.pid
	sleep 1
	find /tmp -mindepth 1 -maxdepth 1 ! -name pristine ! -name mcpcall.py ! -name cronrun.py ! -name run-cron-job.sh ! -name 'fake*.sh' ! -name 'verdict' -exec rm -rf {} + 2>/dev/null
	daemon_start
	sleep 1
	[ "$(desc)" = baseline-gate ] || fail "after the reboot the router kept the unconfirmed change: $(desc)"
	# And the other way out: nobody confirms in time.
	mcp "$TOKEN" mfa_unlock '{"pin":"4821"}' >/dev/null || fail "could not unlock again"
	out=$(mcp "$TOKEN" uci_apply '{"changes":[{"config":"system","section":"@system[0]","option":"description","value":"changed-by-gate"}],"timeout":3}') || fail "the second change was refused: $out"
	[ "$(desc)" = changed-by-gate ] || fail "the second change did not land"
	sleep 6
	[ "$(desc)" = baseline-gate ] || fail "the unconfirmed change was not undone after its window"
	pass "snapshot and pending record under /etc/openwrt-mcp, none in /tmp; the change undone after a reboot and again after its window"
}

# What an open unlock window lets the agent do: settings (uci_apply, rolled back unless
# confirmed), the VPN and services through the named ubus methods, and nothing that runs a
# command, writes a file, flashes a firmware or reboots. Every call the daemon lets through
# reaches /stubs/ubus, which writes it to /tmp/ubus.calls, so "denied" is read twice: in the
# daemon's refusal and in the absence of the call.
check_window_changes_settings_never_runs_commands() {
	reset; configure - pin
	started
	set_pin hermes-main 4821
	daemon_start
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	uci -q show openwrt-mcp | grep -q "hermes_main_change_ubus.scopes=.*'\*'" && fail "the ubus change policy grants '*'"
	mcp "$TOKEN" mfa_unlock '{"pin":"4821"}' >/dev/null || fail "could not unlock"
	: > /tmp/ubus.calls
	for call in '{"object":"file","method":"exec","args":{"command":"/bin/id"}}' \
		'{"object":"file","method":"write","args":{"path":"/etc/rc.local","data":"id"}}' \
		'{"object":"system","method":"sysupgrade","args":{"path":"/tmp/fw.bin"}}' \
		'{"object":"system","method":"validate_firmware_image","args":{"path":"/tmp/fw.bin"}}' \
		'{"object":"system","method":"reboot"}' \
		'{"object":"uci","method":"set","args":{"config":"system","section":"@system[0]","values":{"description":"via-ubus"}}}' \
		'{"object":"service","method":"set","args":{"name":"x","instances":{"i":{"command":["/bin/id"]}}}}' \
		'{"object":"rpc-sys","method":"upgrade_start"}'; do
		if out=$(mcp "$TOKEN" ubus_call "$call"); then fail "allowed in an open window: $call: $out"; fi
		echo "$out" | grep -q 'no policy scope covers' || fail "refused, but not for want of a policy scope: $call: $out"
	done
	! grep -E '^call (file|system|service|rpc-sys) |^call uci set' /tmp/ubus.calls || fail "a refused call reached ubus"
	[ "$(desc)" = baseline-gate ] || fail "uci.set over ubus changed the router"
	out=$(mcp "$TOKEN" ubus_call '{"object":"rc","method":"init","args":{"name":"dnsmasq","action":"restart"}}') || fail "rc.init restart of a service was refused in an open window: $out"
	out=$(mcp "$TOKEN" ubus_call '{"object":"network","method":"reload"}') || fail "network.reload was refused in an open window: $out"
	grep -q '^call rc init' /tmp/ubus.calls && grep -q '^call network reload' /tmp/ubus.calls \
		|| fail "the allowed calls never reached ubus: $(cat /tmp/ubus.calls)"
	# A setting that is itself a command: a firewall include, whose path fw4 runs as root on the
	# reload uci_apply makes. In one batch with a harmless change, so "nothing applied" is read on
	# that change too.
	[ "$(mcp_status capabilities.uci_apply_refuses_code_exec)" = true ] || fail "measured nothing: the installed openwrt-mcp does not refuse code execution in uci_apply"
	INCLUDE='{"changes":[{"config":"system","section":"@system[0]","option":"description","value":"changed-by-gate"},{"config":"firewall","section":"gateinc","type":"include"},{"config":"firewall","section":"gateinc","option":"path","value":"/tmp/gate-include.sh"}]}'
	if out=$(mcp "$TOKEN" uci_apply "$INCLUDE"); then fail "a firewall include was applied in an open window: $out"; fi
	echo "$out" | grep -q 'run code as root' || fail "the include was refused, but not as code: $out"
	uci -q get firewall.gateinc >/dev/null && fail "the firewall include section exists after the refusal"
	[ "$(desc)" = baseline-gate ] || fail "the harmless change in the refused batch was applied"
	out=$(mcp "$TOKEN" uci_apply "$CHANGE") || fail "uci_apply was refused in an open window: $out"
	echo "$out" | grep -q 'ROLLBACK ARMED' || fail "uci_apply did not arm its rollback: $out"
	[ "$(desc)" = changed-by-gate ] || fail "the uci_apply change did not land"
	pass "in an open window: file.exec, file.write, sysupgrade, firmware validation, reboot, uci.set, service.set and rpc-sys refused before ubus, a firewall include refused with nothing of its batch applied; rc.init restart, network.reload and uci_apply with its rollback allowed"
}

# In an open window uci_apply reaches the configs that are settings, the VPN and services, and
# none of the agent's own: a change to hermes (the profile to root, then a restart through
# rc.init) or to openwrt-mcp (its own client granted exec or every ubus method) would be the agent
# making itself root, and rpcd and dropbear are the ways in. Found as '*' in review on 2026-10-08.
check_window_cannot_reach_the_agents_own_config() {
	reset; configure - pin
	started
	set_pin hermes-main 4821
	daemon_start
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	mcp "$TOKEN" mfa_unlock '{"pin":"4821"}' >/dev/null || fail "could not unlock"
	before_mcp=$(md5sum < /etc/config/openwrt-mcp)
	before_hermes=$(md5sum < /etc/config/hermes)
	for change in '{"config":"hermes","section":"main","option":"profile","value":"root"}' \
		'{"config":"openwrt-mcp","section":"hermes_main_change_ubus","option":"scopes","value":"*"}' \
		'{"config":"openwrt-mcp","section":"gate_policy","type":"policy"}' \
		'{"config":"rpcd","section":"gate_login","type":"login"}' \
		'{"config":"dropbear","section":"gate_ssh","type":"dropbear"}' \
		'{"config":"uhttpd","section":"main","option":"listen_http","value":"0.0.0.0:8081"}' \
		'{"config":"fstab","section":"gate_mount","type":"mount"}'; do
		if out=$(mcp "$TOKEN" uci_apply "{\"changes\":[$change]}"); then fail "applied in an open window: $change: $out"; fi
		echo "$out" | grep -q 'no policy scope covers' || fail "refused, but not for want of a policy scope: $change: $out"
	done
	[ "$(md5sum < /etc/config/openwrt-mcp)" = "$before_mcp" ] || fail "/etc/config/openwrt-mcp changed"
	[ "$(md5sum < /etc/config/hermes)" = "$before_hermes" ] || fail "/etc/config/hermes changed"
	[ -z "$(uci -q get hermes.main.profile)" ] || fail "hermes.main.profile is now $(uci -q get hermes.main.profile)"
	# Not vacuous: the VPN and the firewall, in one apply, with its rollback armed.
	VPN='{"changes":[{"config":"network","section":"gatevpn","type":"interface"},{"config":"network","section":"gatevpn","option":"proto","value":"wireguard"},{"config":"firewall","section":"gatezone","type":"zone"},{"config":"firewall","section":"gatezone","option":"name","value":"gatevpn"}]}'
	out=$(mcp "$TOKEN" uci_apply "$VPN") || fail "a WireGuard interface and a firewall zone were refused in an open window: $out"
	echo "$out" | grep -q 'ROLLBACK ARMED' || fail "the network and firewall change did not arm its rollback: $out"
	[ "$(uci -q get network.gatevpn.proto)" = wireguard ] && [ "$(uci -q get firewall.gatezone.name)" = gatevpn ] \
		|| fail "the network and firewall change did not land"
	pass "in an open window: hermes, openwrt-mcp, rpcd, dropbear, uhttpd and fstab refused for want of a scope, their files unchanged; a WireGuard interface and a firewall zone applied with the rollback armed"
}

# A change policy only from an openwrt-mcp that refuses an apply that would run code (0.5.0.3 on,
# `uci_apply_refuses_code_exec` in its status). The installed binary behind a stand-in whose
# status lacks that one key; a PIN is the factor, so without the check a change policy is written.
check_no_change_policy_without_code_exec_refusal() {
	reset; configure - pin
	mv /usr/bin/openwrt-mcp /usr/bin/openwrt-mcp.real
	cat > /usr/bin/openwrt-mcp <<'EOF'
#!/bin/sh
if [ "$1" = status ]; then
	/usr/bin/openwrt-mcp.real "$@" | python3 -c 'import json, sys; d = json.load(sys.stdin); d.get("capabilities", {}).pop("uci_apply_refuses_code_exec", None); json.dump(d, sys.stdout)'
	exit
fi
exec /usr/bin/openwrt-mcp.real "$@"
EOF
	chmod 755 /usr/bin/openwrt-mcp
	[ "$(mcp_status capabilities.uci_get_redacts_credentials)" = true ] || fail "measured nothing: the stand-in lost more than the one capability"
	[ -z "$(mcp_status capabilities.uci_apply_refuses_code_exec)" ] || fail "measured nothing: the stand-in still reports uci_apply_refuses_code_exec"
	started
	uci -q show openwrt-mcp | grep -q '^openwrt-mcp\.hermes_main_read_ubus=' || fail "measured nothing: no read policy was written"
	uci -q show openwrt-mcp | grep -q '^openwrt-mcp\.hermes_main_change' && fail "a change policy was written for an openwrt-mcp that does not refuse code execution: $(uci -q show openwrt-mcp | grep hermes_main_change | head -3)"
	n=$(grep -c 'does not report that uci_apply refuses code execution' /tmp/start.log)
	[ "$n" = 1 ] || { cat /tmp/start.log; fail "the start said why in $n lines, not one"; }
	set_pin hermes-main 4821
	daemon_start
	mcp "$TOKEN" mfa_unlock '{"pin":"4821"}' >/dev/null 2>&1
	if out=$(mcp "$TOKEN" uci_apply "$CHANGE"); then fail "uci_apply was allowed: $out"; fi
	echo "$out" | grep -q 'no policy grants uci_apply' || fail "uci_apply was refused, but not for want of a policy: $out"
	[ "$(desc)" = baseline-gate ] || fail "the change was applied anyway"
	# Not vacuous: with the real status the same start writes the change policy.
	daemon_stop
	mv -f /usr/bin/openwrt-mcp.real /usr/bin/openwrt-mcp
	started
	uci -q show openwrt-mcp | grep -q '^openwrt-mcp\.hermes_main_change_ubus=' || fail "the real status did not get a change policy written either, so the refusal above proves nothing"
	pass "no uci_apply_refuses_code_exec: reads only, no change policy, said in one line, uci_apply refused for want of one after an unlock; the real status wrote it"
}

# ---- wireless and the whole of network: read only from a daemon that redacts their secrets ----

# What the installed openwrt-mcp says of itself: one field of its status, by jsonfilter path.
mcp_status() { openwrt-mcp status --json --audit 0 2>/dev/null | jsonfilter -e "@.$1" 2>/dev/null; }
# The uci_get scopes the package granted the agent, one per line.
read_uci_scopes() { uci -q get openwrt-mcp.hermes_main_read_uci.scopes | tr ' ' '\n'; }
# Any scope that reaches wireless or the whole of network, rather than network's named sections.
wide_scopes() { read_uci_scopes | grep -E '^(wireless|wireless\..*|network|network\.\*)$' || true; }

# The read a guest Wi-Fi needs (on 2026-10-08 an agent on a Beryl AX could not set one up, refused
# a read of wireless), from the openwrt-mcp the package depends on, which redacts every secret
# option in every uci_get answer. The canaries are the keys reset() plants in /etc/config/wireless
# and in the WireGuard section of /etc/config/network.
check_wireless_and_network_reads_are_redacted() {
	reset; configure - -
	grep -q GATE-WIFI-KEY-CANARY /etc/config/wireless && grep -q GATE-WIREGUARD-PRIVATE-KEY-CANARY /etc/config/network \
		|| fail "measured nothing: no key planted in wireless or network"
	[ "$(mcp_status capabilities.uci_get_redacts_credentials)" = true ] \
		|| fail "the installed openwrt-mcp $(mcp_status version) does not report uci_get_redacts_credentials, so this measured nothing; build it from the commit CI pins"
	started
	daemon_start
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	out=$(mcp "$TOKEN" uci_get '{"config":"wireless"}') || fail "uci_get wireless was refused: $out"
	echo "$out" | grep -qF "wireless.main.ssid='gate'" || fail "uci_get wireless gave no settings: $out"
	echo "$out" | grep -qF "wireless.main.key='<redacted>'" || fail "the Wi-Fi key does not read '<redacted>': $out"
	echo "$out" | grep -q CANARY && fail "the Wi-Fi key reached the answer: $out"
	out=$(mcp "$TOKEN" uci_get '{"config":"network"}') || fail "uci_get network was refused: $out"
	echo "$out" | grep -qF "network.lan.ipaddr='192.168.77.1'" || fail "uci_get network gave no settings: $out"
	echo "$out" | grep -qF "network.wg0.private_key='<redacted>'" || fail "the WireGuard private key does not read '<redacted>': $out"
	echo "$out" | grep -q CANARY && fail "the WireGuard private key reached the answer: $out"
	# Narrowed to the one option, the same.
	out=$(mcp "$TOKEN" uci_get '{"config":"network","section":"wg0","option":"private_key"}') || fail "uci_get of the private key itself was refused: $out"
	echo "$out" | grep -q CANARY && fail "the WireGuard private key reached the answer to a read of that option: $out"
	# netifd's network.wireless status carries the same key and openwrt-mcp does not redact a ubus
	# answer, so it stays ungranted however wide uci_get is.
	if out=$(mcp "$TOKEN" ubus_call '{"object":"network.wireless","method":"status"}'); then fail "network.wireless status was answered: $out"; fi
	echo "$out" | grep -q CANARY && fail "the Wi-Fi key reached a refusal: $out"
	echo "$out" | grep -qE 'no policy (grants|scope covers)' || fail "network.wireless status was refused, but not for want of a policy: $out"
	pass "wireless and the whole of network answered, the Wi-Fi key and the WireGuard private key read '<redacted>'; network.wireless status refused"
}

# What the init does when the openwrt-mcp it finds does not say it redacts: an older binary has no
# capabilities key in its status. The installed binary is put behind a stand-in whose status lacks
# that key and names an older version (the runner puts the real one back after every check).
check_wide_reads_only_from_a_daemon_that_redacts() {
	reset; configure - -
	mv /usr/bin/openwrt-mcp /usr/bin/openwrt-mcp.real
	cat > /usr/bin/openwrt-mcp <<'EOF'
#!/bin/sh
if [ "$1" = status ]; then
	/usr/bin/openwrt-mcp.real "$@" | python3 -c 'import json, sys; d = json.load(sys.stdin); d.pop("capabilities", None); d["version"] = "0.5.0"; json.dump(d, sys.stdout)'
	exit
fi
exec /usr/bin/openwrt-mcp.real "$@"
EOF
	chmod 755 /usr/bin/openwrt-mcp
	[ -n "$(mcp_status version)" ] || fail "measured nothing: the stand-in gives no status"
	[ -z "$(mcp_status capabilities)" ] || fail "measured nothing: the stand-in still reports capabilities"
	started
	[ -n "$(read_uci_scopes)" ] || fail "measured nothing: no uci_get policy was written"
	wide=$(wide_scopes | tr '\n' ' ')
	[ -z "$wide" ] || fail "granted $wide from an openwrt-mcp that does not report it redacts"
	read_uci_scopes | grep -qx 'network\.lan\*' || fail "the narrow grants are missing too: $(read_uci_scopes | tr '\n' ' ')"
	n=$(grep -c 'does not report that uci_get redacts credentials' /tmp/start.log)
	[ "$n" = 1 ] || { cat /tmp/start.log; fail "the start said why in $n lines, not one"; }
	daemon_start
	for q in '{"config":"wireless"}' '{"config":"network","section":"wg0"}' '{"config":"network"}'; do
		if out=$(mcp "$TOKEN" uci_get "$q"); then fail "uci_get $q was answered: $out"; fi
		echo "$out" | grep -q CANARY && fail "a key reached the answer to $q"
	done
	# Not vacuous: the same router, with the binary's own status, gets the wide grant.
	daemon_stop
	mv -f /usr/bin/openwrt-mcp.real /usr/bin/openwrt-mcp
	started
	wide_scopes | grep -qx wireless || fail "the installed openwrt-mcp's own status did not widen the grant either, so the refusal above proves nothing: $(read_uci_scopes | tr '\n' ' ')"
	pass "no capability: system, dhcp, firewall and the named network sections only, said in one line, wireless and network refused; the real status widened it"
}

# apk replaces openwrt-mcp's binary on an upgrade without restarting its daemon, so the one serving
# can be a version from before redaction. A stand-in on the daemon's own address answers /health as
# 0.5.0; with no procd in a container the init's restart cannot replace it, as a restart that did
# not take on a router would not.
health_standin() {
	cat > /tmp/standin.py <<'EOF'
import http.server, sys
body = ("openwrt-mcp %s ok\nsource: gate stand-in\n" % sys.argv[1]).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", 8730), H).serve_forever()
EOF
	python3 /tmp/standin.py "$1" >/tmp/standin.log 2>&1 &
	echo $! > /tmp/standin.pid
	i=0
	until python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8730/health", timeout=2)' 2>/dev/null; do
		i=$((i + 1)); [ "$i" -lt 20 ] || { cat /tmp/standin.log; fail "the /health stand-in did not come up"; }
		sleep 1
	done
}
standin_stop() { [ ! -f /tmp/standin.pid ] || kill "$(cat /tmp/standin.pid)" 2>/dev/null || true; rm -f /tmp/standin.pid; sleep 1; }

check_daemon_from_before_the_upgrade_gets_no_wide_reads() {
	reset; configure - -
	ver=$(mcp_status version)
	[ -n "$ver" ] && [ "$ver" != 0.5.0 ] || fail "measured nothing: the installed openwrt-mcp is '$ver'"
	health_standin 0.5.0
	[ "$(mcp_status running)" = true ] || { standin_stop; fail "measured nothing: openwrt-mcp status does not see the stand-in as a running daemon"; }
	started
	standin_stop
	wide=$(wide_scopes | tr '\n' ' ')
	[ -z "$wide" ] || fail "granted $wide while an openwrt-mcp 0.5.0 was the one serving"
	read_uci_scopes | grep -qx 'network\.lan\*' || fail "the narrow grants are missing too: $(read_uci_scopes | tr '\n' ' ')"
	grep -q "the openwrt-mcp running is 0.5.0, not the installed $ver" /tmp/start.log || { cat /tmp/start.log; fail "the start did not say which daemon was running"; }
	# Not vacuous: a daemon at the installed version, on the same address, gets the wide grant.
	health_standin "$ver"
	started
	standin_stop
	wide_scopes | grep -qx wireless || fail "a daemon at the installed $ver did not get the wide grant either, so the refusal above proves nothing: $(read_uci_scopes | tr '\n' ' ')"
	pass "0.5.0 still serving beside an installed $ver: the narrow grants, and the start says which daemon runs; at $ver the wide grant"
}

# ---- 0.21.5-r13: package installs from the official feed, the owner's opt-in ----

# openwrt-mcp's status, with the capability the package policy needs added and, optionally, others
# taken away: a stand-in for an openwrt-mcp that has apk_add, in front of the installed binary (the
# runner's recorders_off puts the real one back after every check).
#   apk_standin [capability to drop ...]
apk_standin() {
	[ -f /usr/bin/openwrt-mcp.real ] || mv /usr/bin/openwrt-mcp /usr/bin/openwrt-mcp.real
	cat > /usr/bin/openwrt-mcp <<EOF
#!/bin/sh
if [ "\$1" = status ]; then
	/usr/bin/openwrt-mcp.real "\$@" | python3 -c 'import json, sys; d = json.load(sys.stdin); c = d.setdefault("capabilities", {}); c["apk_add_official_feed_only"] = True; [c.pop(k, None) for k in sys.argv[1:]]; json.dump(d, sys.stdout)' $*
	exit
fi
exec /usr/bin/openwrt-mcp.real "\$@"
EOF
	chmod 755 /usr/bin/openwrt-mcp
}

# apk replaces openwrt-mcp's binary without restarting its daemon, so the one serving can be from
# before apk_add. Its word that apk_add installs official packages only is not taken from the
# installed binary while another daemon answers: the same /health discipline as the wide reads,
# with apk_add the only capability the stand-in reports, so nothing else sends the init to /health.
check_no_package_policy_from_a_daemon_from_before_the_upgrade() {
	reset; configure - pin
	uci set hermes.security.packages=official; uci commit hermes
	ver=$(mcp_status version)
	[ -n "$ver" ] && [ "$ver" != 0.5.0 ] || fail "measured nothing: the installed openwrt-mcp is '$ver'"
	apk_standin uci_get_redacts_credentials uci_apply_refuses_code_exec
	[ "$(mcp_status capabilities.apk_add_official_feed_only)" = true ] || fail "measured nothing: the stand-in does not report apk_add_official_feed_only"
	[ -z "$(mcp_status capabilities.uci_apply_refuses_code_exec)$(mcp_status capabilities.uci_get_redacts_credentials)" ] \
		|| fail "measured nothing: the stand-in still reports another capability, which alone would send the init to /health"
	health_standin 0.5.0
	[ "$(mcp_status running)" = true ] || { standin_stop; fail "measured nothing: openwrt-mcp status does not see the stand-in as a running daemon"; }
	started
	standin_stop
	uci -q get openwrt-mcp.hermes_main_packages >/dev/null && fail "a package policy was written while an openwrt-mcp 0.5.0 was the one serving: $(uci -q show openwrt-mcp.hermes_main_packages | tr '\n' ' ')"
	grep -q '^HERMES_OPENWRT_PACKAGES=off$' /tmp/envv || fail "the gateway is not told packages are off: $(grep PACKAGES /tmp/envv)"
	grep -q "the openwrt-mcp running is 0.5.0, not the installed $ver" /tmp/start.log || { cat /tmp/start.log; fail "the start did not say which daemon was running"; }
	n=$(grep -c 'apk_add' /tmp/start.log)
	[ "$n" = 0 ] || { cat /tmp/start.log; fail "beside the line naming the daemon, the start said $n more about apk_add"; }
	# Not vacuous: a daemon at the installed version, on the same address, gets the package policy.
	health_standin "$ver"
	started
	standin_stop
	[ "$(uci -q get openwrt-mcp.hermes_main_packages.tools)" = apk_add ] || { cat /tmp/start.log; fail "a daemon at the installed $ver did not get the package policy either, so the refusal above proves nothing"; }
	grep -q '^HERMES_OPENWRT_PACKAGES=granted$' /tmp/envv || fail "the policy was written and the gateway not told: $(grep PACKAGES /tmp/envv)"
	pass "opted in, factor pin, apk_add reported: no package policy while 0.5.0 served, said in one line; at $ver the policy and HERMES_OPENWRT_PACKAGES=granted"
}

# What the real apk_add does in the owner's opt-in, against the installed openwrt-mcp (0.5.0.4 on).
#
# Deterministic in CI, and why it never reaches the feed: apk_add runs `apk update` against the
# official feeds before every call, a dry run included, and this gate runs with the network down.
# What is proven needs no download, because openwrt-mcp decides in a fixed order: the policy (is
# apk_add granted for every package name named, with the window open when the policy asks for
# one), then apk_add's own name rules, then apk. So a call the policy stops answers "requires a
# second factor" or "no policy grants apk_add" whatever the name; a call the policy lets through
# with a name apk_add's rules refuse (a version, a file, an option, a tag, none with a '/' so the
# '*' scope covers it) answers with apk_add's own "refused: ... Nothing was installed", which is the
# proof it got past the policy, and nothing runs. A real dry run or install, which needs the feed,
# is not run here (openwrt-mcp's own tests hold its argv; see the package's docs for what is
# measured where).
PKG=wireguard-tools
DRY="{\"packages\":[\"$PKG\"],\"dry_run\":true}"
check_package_install_needs_the_unlock() {
	reset; configure - pin
	[ "$(mcp_status capabilities.apk_add_official_feed_only)" = true ] \
		|| fail "the installed openwrt-mcp $(mcp_status version) does not report apk_add_official_feed_only, so this measured nothing; build it from the commit CI pins"
	uci set hermes.security.packages=official; uci commit hermes
	started
	[ "$(uci -q get openwrt-mcp.hermes_main_packages.tools)" = apk_add ] || { cat /tmp/start.log; fail "opted in with a factor and an openwrt-mcp that has apk_add, and no package policy was written"; }
	grep -q '^HERMES_OPENWRT_PACKAGES=granted$' /tmp/envv || fail "the gateway is not told apk_add is granted"
	set_pin hermes-main 4821
	daemon_start
	[ -s "$TOKEN" ] || fail "the package left no router MCP token in $TOKEN"
	# Locked: refused for the second factor, a dry run included, before apk_add looks at anything.
	if out=$(mcp "$TOKEN" apk_add "$DRY"); then fail "apk_add answered with no unlock: $out"; fi
	echo "$out" | grep -q 'second factor' || fail "apk_add was refused, but not for the second factor: $out"
	if out=$(mcp "$TOKEN" apk_add '{"packages":["wireguard-tools=1.0"],"dry_run":true}'); then fail "apk_add answered with no unlock: $out"; fi
	echo "$out" | grep -q 'second factor' || fail "with no unlock a malformed name reached apk_add's own rules: $out"
	# Unlocked: the policy lets apk_add through, and apk_add's own rules refuse what is not a plain
	# package name, saying nothing was installed.
	mcp "$TOKEN" mfa_unlock '{"pin":"4821"}' >/dev/null || fail "could not unlock"
	for bad in 'wireguard-tools=1.0' 'x.apk' '--allow-untrusted' 'wireguard-tools@custom'; do
		if out=$(mcp "$TOKEN" apk_add "{\"packages\":[\"$bad\"],\"dry_run\":true}"); then fail "apk_add took '$bad' in an open window: $out"; fi
		echo "$out" | grep -q 'Nothing was installed' || fail "in an open window '$bad' was refused, but not by apk_add's own rules (the policy stopped it, or something else did): $out"
		echo "$out" | grep -qE 'second factor|no policy' && fail "in an open window '$bad' was refused by the policy: $out"
	done
	# A link carries a '/', which no package name has and the '*' scope does not cover: refused too.
	if out=$(mcp "$TOKEN" apk_add '{"packages":["https://example.invalid/x.apk"],"dry_run":true}'); then fail "apk_add took a link in an open window: $out"; fi
	apk info -e "$PKG" >/dev/null 2>&1 && fail "$PKG is installed after only refusals"
	# The model is offered apk_add, through upstream's own registry.
	probe_tools
	run_wrapper PROBE_OUT=/tmp/probe.out >/tmp/svc.log 2>&1 || { cat /tmp/svc.log; fail "the wrapper failed"; }
	grep -q 'mcp__openwrt__apk_add' /tmp/probe.out || fail "granted, and the model is not offered apk_add: $(cat /tmp/probe.out)"
	# Off: no policy, refused after an unlock for want of one, and hidden from the model.
	daemon_stop
	uci set hermes.security.packages=off; uci commit hermes
	started
	uci -q get openwrt-mcp.hermes_main_packages >/dev/null && fail "packages off and the package policy is still there"
	grep -q '^HERMES_OPENWRT_PACKAGES=off$' /tmp/envv || fail "packages off and the gateway is not told so"
	daemon_start
	mcp "$TOKEN" mfa_unlock '{"pin":"4821"}' >/dev/null || fail "could not unlock with packages off"
	if out=$(mcp "$TOKEN" apk_add "$DRY"); then fail "apk_add answered with packages off: $out"; fi
	echo "$out" | grep -q 'no policy grants apk_add' || fail "with packages off apk_add was refused, but not for want of a policy: $out"
	probe_tools
	run_wrapper PROBE_OUT=/tmp/probe.out >/tmp/svc.log 2>&1 || { cat /tmp/svc.log; fail "the wrapper failed with packages off"; }
	grep -q 'mcp__openwrt__uci_get' /tmp/probe.out || fail "with packages off upstream offers no openwrt tools at all, so the absence below proves nothing"
	grep -q 'mcp__openwrt__apk_add' /tmp/probe.out && fail "packages off and the model is offered apk_add"
	pass "opted in with a factor: apk_add refused for the factor while locked; in an open window past the policy to apk_add's own rules (a version, a file, an option, a tag refused, a link refused), nothing installed; offered to the model; off: no policy, refused after an unlock, hidden"
}

# ======================================================= the Hermes side: the real gateway

# The gateway, with Telegram on, against the two stand-ins in scripts/unlock-harness.py.
# What an operator writes themselves goes in config.yaml before the bridge runs (where
# Telegram is, and the most verbose logging); everything else is what the package wrote.
#   unlock_up <factor> [window]
TGTOKEN='123456789:AAHgateCanaryTokenNotRealAAHgateCanary'
harness() { python3 /harness.py "$@" 2>&1; }
last_line() { tail -n 1 | sed 's/^\(PASS\|FAIL\): //'; }

# A scheduled job, run by upstream's own scheduler code in a process of its own, with the
# gateway's environment and the agent's user: what the gateway's cron ticker would run.
cat > /tmp/cronrun.py <<'EOF'
import json, os, sys
sys.path.insert(0, "/usr/lib/hermes-agent/site-packages")
from tools.mcp_tool_discovery import discover_mcp_tools
discover_mcp_tools()
from cron.scheduler import run_job
res = run_job({"id": "gatejob", "name": "gate job", "prompt": "Change the router description.",
               "schedule": {"kind": "once"}, "deliver": "local", "enabled": True})
print("RESULT", json.dumps([str(x)[:120] for x in res]))
EOF
cat > /tmp/run-cron-job.sh <<'EOF'
#!/bin/sh
cd /srv/hermes
exec python3 -I -B /usr/libexec/hermes-drop hermes env $(cat /tmp/envv) \
	OPENWRT_MCP_TOKEN="$(cat /etc/hermes-agent/router-mcp.token)" OPENAI_API_KEY="$(cat /etc/hermes-agent/provider.key)" \
	HERMES_OPENWRT_UNLOCK_URL=http://127.0.0.1:8730/mcp PYTHONPATH=/usr/lib/hermes-agent/site-packages \
	python3 /tmp/cronrun.py
EOF

unlock_up() {
	factor=$1; window=${2:-}
	[ -f /usr/lib/hermes-agent/telegram.manifest ] || fail "the Telegram add-on is not installed, so the real adapter cannot run; build it: ./package/hermes-agent-telegram/build-in-container.sh"
	reset; configure - "$factor"
	uci set hermes.main.base_url=http://127.0.0.1:8742/v1
	uci set hermes.main.model=gate-model
	[ -z "$window" ] || uci set hermes.security.window="$window"
	uci set hermes.telegram.enabled=1
	uci -q delete hermes.telegram.allow_user_id || true
	uci add_list hermes.telegram.allow_user_id=4242
	uci commit hermes
	printf '%s' "$TGTOKEN" > /etc/hermes-agent/telegram.token
	chmod 600 /etc/hermes-agent/telegram.token
	mkdir -p /srv/hermes; chmod 700 /srv/hermes
	cat > /srv/hermes/config.yaml <<'EOF'
telegram:
  extra:
    base_url: http://127.0.0.1:8741/bot
logging:
  level: DEBUG
EOF
	chown -R hermes:hermes /srv/hermes
	rm -rf /tmp/fakes /tmp/totp.secret
	python3 /harness.py fakes >/tmp/fakes.log 2>&1 &
	echo $! > /tmp/fakes.pid
	started
	daemon_start
	harness factor "$factor" >/tmp/harness.out || fail "$(last_line < /tmp/harness.out)"
	sh -c 'exec env $(cat /tmp/envv) "$@"' sh $(cat /tmp/argv) >/tmp/svc.log 2>&1 &
	echo $! > /tmp/svc.pid
	harness ready >/tmp/harness.out || { tail -n 12 /tmp/svc.log; fail "$(last_line < /tmp/harness.out)"; }
}

# Stop what unlock_up started: the gateway, whatever it spawned, and the stand-ins. busybox has
# no pkill, and a process is found by its command line.
unlock_down() {
	for p in /proc/[0-9]*; do
		p=${p#/proc/}
		[ "$p" != "$$" ] || continue
		cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
		case "$cmd" in
			*"hermes_cli/main.py gateway run"*|*"/harness.py fakes"*|*"run-cron-job"*|*"rpcd"*|*"ubusd"*) kill -9 "$p" 2>/dev/null || true ;;
		esac
	done
	rm -f /tmp/svc.pid /tmp/fakes.pid
}

# One scenario of the harness, against a gateway started for it.
#   scenario <check> <factor> [window]
scenario() {
	unlock_up "$2" "${3:-}"
	if out=$(harness "$1"); then
		pass "$(echo "$out" | last_line)"
	else
		echo "$out" | tail -n 6 | grep -v '^FAIL' | cut -c1-200 >&2 || true
		fail "$(echo "$out" | last_line)"
	fi
}

check_pin_alone_unlocks()                                 { scenario "$CUR_NAME" pin; }
check_code_alone_unlocks()                                { scenario "$CUR_NAME" totp; }
check_pin_and_code_both_required()                        { scenario "$CUR_NAME" pin+totp; }
check_pin_stored_as_slow_hash()                           { scenario "$CUR_NAME" pin; }
check_wrong_attempts_lock_out()                           { scenario "$CUR_NAME" pin+totp; }
check_code_works_once()                                   { scenario "$CUR_NAME" totp; }
check_unlock_window_ends()                                { scenario "$CUR_NAME" pin 5s; }
check_lock_closes_at_once()                               { scenario "$CUR_NAME" pin; }
check_unlock_message_deleted_and_never_reaches_model()    { scenario "$CUR_NAME" pin+totp; }
check_unlock_while_busy_never_reaches_model()             { scenario "$CUR_NAME" pin; }
check_bare_code_is_an_unlock_attempt()                    { scenario "$CUR_NAME" pin+totp; }
check_edited_unlock_never_reaches_model()                 { scenario "$CUR_NAME" pin; }
check_secret_in_no_log()                                  { scenario "$CUR_NAME" pin+totp; }
check_unlock_refused_in_group()                           { scenario "$CUR_NAME" pin; }
check_unlock_only_from_allowlist()                        { scenario "$CUR_NAME" pin; }
check_agent_told_window_is_open()                        { scenario "$CUR_NAME" pin; }
check_agent_not_told_after_window_ends()                  { scenario "$CUR_NAME" pin 20s; }
check_scheduled_job_cannot_change()                       { scenario "$CUR_NAME" pin; }

# ======================================================= the LuCI Security page, and the SSH enrolment

# What the page calls: rpcd with the INSTALLED luci-app-hermes backend, on ubus, as LuCI reaches it.
# The real openwrt-mcp is behind it; only the browser is missing, and the page's own JavaScript is
# checked by scripts/test-luci-views.mjs. Each scenario below is scripts/security-harness.py.
rpc_up() {
	mkdir -p /var/run/ubus
	ubusd >/tmp/ubusd.log 2>&1 &
	sleep 1
	rpcd >/tmp/rpcd.log 2>&1 &
	i=0
	until ubus list 2>/dev/null | grep -qx hermes; do
		i=$((i + 1)); [ "$i" -lt 20 ] || { cat /tmp/rpcd.log; fail "rpcd did not register the hermes object"; }
		sleep 1
	done
	ubus list hermes 2>/dev/null | grep -q . || fail "ubus lists no hermes object"
	[ -x /usr/libexec/rpcd/hermes ] || fail "the luci-app-hermes backend is not installed"
}

# The harness's last line is its verdict; on a failure the lines before it say where.
security_scenario() {
	out=$(python3 /sec/security-harness.py "$@" 2>&1) && return 0
	echo "$out" | tail -n 8 | grep -v '^FAIL' | cut -c1-200 >&2 || true
	fail "$(echo "$out" | last_line)"
}

# A recorder in front of the four programs the backend can hand a message to: what each was run
# with, and the environment it carried, appended to /tmp/shim.log, and for `openwrt-mcp pin set`
# also a hash of what it read on standard input, never the PIN itself. Each passes everything
# through. The real program moves to <path>.real and the runner puts it back after every check.
RECORDED='/usr/bin/jshn /usr/bin/jsonfilter /sbin/uci /usr/bin/openwrt-mcp'
recorders_on() {
	: > /tmp/shim.log; : > /tmp/mcp-shim.log
	for f in $RECORDED; do
		mv "$f" "$f.real"
		{
			echo '#!/bin/sh'
			echo "{ printf 'ARGV %s' \"\$0\"; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; env; printf 'END\\n'; } >> /tmp/shim.log"
			if [ "$f" = /usr/bin/openwrt-mcp ]; then
				cat <<'EOF'
if [ "$1" = pin ] && [ "$2" = set ]; then
	in=$(cat)
	sha=$(printf '%s\n' "$in" | sha256sum | cut -d' ' -f1)
	printf '%s\t%s\n' "$*" "$sha" >> /tmp/mcp-shim.log
	printf '%s\n' "$in" | /usr/bin/openwrt-mcp.real "$@"
	exit $?
fi
printf '%s\t-\n' "$*" >> /tmp/mcp-shim.log
EOF
			fi
			echo "exec $f.real \"\$@\""
		} > "$f"
		chmod 755 "$f"
	done
}
recorders_off() {
	for f in $RECORDED; do [ ! -f "$f.real" ] || mv -f "$f.real" "$f"; done
}

check_luci_enrol_shows_qr_and_verifies() {
	reset; configure - -
	started
	recorders_on
	rpc_up
	security_scenario "$CUR_NAME"
	summary=$(echo "$out" | last_line)
	recorders_off
	# What the owner does next: the agent restarts, which writes the change policy from
	# hermes.security, and the code from the phone enrolled on the page unlocks. The second phone,
	# which was never activated, does not.
	started
	daemon_start
	[ "$(uci -q get openwrt-mcp.hermes_main_change.mfa_factor)" = totp ] || fail "the factor chosen on the page did not reach the change policy: $(uci -q get openwrt-mcp.hermes_main_change.mfa_factor)"
	if out=$(mcp "$TOKEN" mfa_unlock "{\"code\":\"$(python3 /sec/security-harness.py code pending)\"}"); then fail "the second phone, never activated, unlocked changes: $out"; fi
	out=$(mcp "$TOKEN" mfa_unlock "{\"code\":\"$(python3 /sec/security-harness.py code active)\"}") || fail "the code from the phone enrolled on the page did not unlock: $out"
	out=$(mcp "$TOKEN" uci_apply "$CHANGE") || fail "a change was refused after that unlock: $out"
	pass "$summary; after the restart its code opened changes and the unactivated phone's did not"
}

check_cli_enrol_prints_qr() {
	reset; configure - -
	started
	security_scenario "$CUR_NAME"
	pass "$(echo "$out" | last_line)"
}

check_luci_pin_write_only() {
	reset; configure - -
	started
	recorders_on
	rpc_up
	security_scenario "$CUR_NAME"
	summary=$(echo "$out" | last_line)
	recorders_off
	# And the PIN the page set is the PIN the daemon asks for.
	started
	daemon_start
	[ "$(uci -q get openwrt-mcp.hermes_main_change.mfa_factor)" = pin ] || fail "the factor chosen on the page did not reach the change policy"
	if out=$(mcp "$TOKEN" mfa_unlock '{"pin":"07310529"}'); then fail "a wrong PIN unlocked changes: $out"; fi
	out=$(mcp "$TOKEN" mfa_unlock '{"pin":"07310528"}') || fail "the PIN set through the page did not unlock: $out"
	security_scenario scan 07310528
	pass "$summary; it then unlocked, a PIN one digit off did not, and still no file held it"
}

# ---- what this stage does not prove yet ----
not_implemented() { fail "NOT IMPLEMENTED ($1)"; }

# ======================================================================= the runner
SELECTED=" ${ONLY:-} "
n=0; passed=0; failed=0; pending=0
run_check() {
	name=$1; kind=$2
	n=$((n + 1))
	if [ -n "${ONLY:-}" ]; then case "$SELECTED" in *" $name "*) ;; *) return 0 ;; esac; fi
	CUR="[$n/$TOTAL] $name"; CUR_NAME=$name
	rm -f /tmp/verdict
	if [ "$kind" = implemented ]; then
		( "$name" ); rc=$?
	else
		( not_implemented "$kind" ); rc=$?
	fi
	unlock_down
	daemon_stop
	[ ! -f /tmp/standin.pid ] || { kill "$(cat /tmp/standin.pid)" 2>/dev/null || true; rm -f /tmp/standin.pid; }
	cp /tmp/pristine/hermes.bin /usr/bin/hermes
	recorders_off
	if [ "$rc" -eq 0 ] && [ -f /tmp/verdict ]; then
		passed=$((passed + 1))
	else
		[ "$rc" -ne 0 ] || echo "FAIL $CUR: ended without a verdict"
		failed=$((failed + 1))
		case "$kind" in implemented) ;; *) pending=$((pending + 1)) ;; esac
	fi
}
for c in $IMPLEMENTED; do run_check "$c" implemented; done
for c in $STAGE4; do run_check "$c" "stage 4"; done
for c in $STAGE5; do run_check "$c" "stage 5"; done

if [ -n "${ONLY:-}" ]; then
	ran=$((passed + failed))
	[ "$ran" -gt 0 ] || { echo "measured nothing: ONLY names no check"; exit 1; }
fi
echo "gate-unlock: $passed passed, $failed failed ($pending of them NOT IMPLEMENTED)"
[ "$failed" -eq 0 ]
CONTAINER
