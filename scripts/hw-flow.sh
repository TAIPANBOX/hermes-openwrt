#!/bin/sh
# hw-flow.sh -- the path a person takes, from a router with no Hermes to an agent that answers in
# Telegram, run on real hardware over SSH with every step checked. Run it before every feed
# publish, on a Flint 2 and a Brume 2.
#
# Why it exists. The gates install into a container and check what each change changed. None of
# them is a person following the README on a clean router, and on 2026-10-08 the first such run in
# a week found the agent unable to ping (BusyBox's ping needs root; the agent had stopped being
# root at r3), the hourly watch pointing at a script nobody was given, and an install that needs
# re-running when OpenWrt's server cuts a download. Each was invisible to every green gate.
#
# Usage, from a workstation that can reach the router:
#
#   ROUTER=root@192.168.1.24 \
#   KEY_CMD='security find-generic-password -s <provider key item> -w' \
#   TG_CMD='security find-generic-password -s <bot token item> -w' TG_ID=<your numeric id> \
#   ./scripts/hw-flow.sh [step ...]
#
# Steps, in order when none are named: clean install model start telegram ask watch admin upgrade.
# `admin` probes the agent's own openwrt-mcp token: reads, a refused change, and with FLOW_PIN (a
# throwaway PIN it sets and clears) the unlock window and the rollback of an unconfirmed change.
# FEED_BASE=http://<host>:<port> installs from a release candidate signed with the feed's key and
# served from that address, before it is published; the step `clean` also drops that line.
# `reboot` runs only when named and REBOOT_OK=1, and `remove` only when named: one cuts the
# router's network for a minute, the other leaves it without Hermes.
#
# Secrets go to the router on standard input only, never on a command line or in this log. The
# old state is not kept: `clean` removes everything the package made, data and keys included, so
# take a copy first if the router's Hermes matters (the README's sysupgrade -b, or a tar of
# /srv/hermes and /etc/hermes-agent).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROUTER=${ROUTER:?ROUTER=root@<address> is required}
BASE_URL=${BASE_URL:-https://openrouter.ai/api/v1}
MODEL=${MODEL:-openai/gpt-4o-mini}
OUT=${OUT:-$ROOT/build/hw-flow/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
LOG="$OUT/flow.log"
FAILED=0

say()  { echo "$*" | tee -a "$LOG"; }
pass() { say "PASS $1: $2"; }
fail() { say "FAIL $1: $2"; FAILED=$((FAILED + 1)); }
on()   { ssh -o BatchMode=yes -o ConnectTimeout=10 "$ROUTER" "$@"; }
# a script sent on stdin, so nothing in it is matched by a pgrep on the router's own sh -c
run()  { ssh -o BatchMode=yes -o ConnectTimeout=10 "$ROUTER" 'sh -s' >>"$LOG" 2>&1; }
mark() { on "logger -t hw-flow $1"; }
since(){ on "logread | sed -n '/hw-flow: $1/,\$p'"; }
gateway_up() { # seconds to wait
	i=0; while [ "$i" -lt "$1" ]; do
		on "pgrep -f '[m]ain.py gateway' >/dev/null" && return 0; sleep 2; i=$((i + 2)); done; return 1; }

step_clean() {
	run <<'EOF'
/etc/init.d/hermes-agent stop 2>/dev/null
apk del luci-app-hermes hermes-agent-telegram hermes-agent openwrt-mcp iputils-ping 2>&1 | tail -n 1
d=$(uci -q get hermes.main.data_dir); rm -rf "${d:-/srv/hermes}"
rm -rf /etc/hermes-agent /etc/openwrt-mcp
rm -f /etc/config/hermes /etc/config/openwrt-mcp /etc/apk/keys/hermes-openwrt.pem
sed -i '/taipanbox.github.io\/hermes-openwrt/d; /\/25.12\/aarch64[a-z0-9_-]*\/packages.adb/d' /etc/apk/repositories.d/customfeeds.list
sed -i '/^hermes:/d' /etc/passwd /etc/shadow /etc/group
/etc/init.d/rpcd restart
EOF
	left=$(on "apk info 2>/dev/null | grep -cE '^(hermes|luci-app-hermes|openwrt-mcp|python3-base)'; ls /etc/rc.d | grep -c hermes; id hermes >/dev/null 2>&1 && echo user; ls -d /srv/hermes 2>/dev/null" | tr '\n' ' ')
	[ "$left" = "0 0 " ] && pass clean "no package, start link, account or data left" || fail clean "left behind: $left"
}

step_install() {
	# The README's own block, as written, so this checks the document and not a paraphrase of it.
	awk '/^\*\*1\. Trust the feed and install\.\*\*/ {f=1} f && /^```sh/ {b=1; next} b && /^```/ {exit} b' \
		"$ROOT/README.md" > "$OUT/install.sh"
	grep -q 'apk add hermes-agent' "$OUT/install.sh" || { fail install "measured nothing: no install block found in README.md"; return; }
	# FEED_BASE: a feed signed with the same key but served from elsewhere (a release candidate
	# checked before it is published). Only the packages' address changes; the key the router
	# trusts is still fetched from where the README says.
	if [ -n "${FEED_BASE:-}" ]; then
		sed -i.bak "s|https://taipanbox.github.io/hermes-openwrt/25.12/|$FEED_BASE/25.12/|" "$OUT/install.sh"
		grep -q "$FEED_BASE/25.12/" "$OUT/install.sh" || { fail install "FEED_BASE given but the README's feed line was not found to point at it"; return; }
		say "install: packages from $FEED_BASE (release candidate), key from the README's address"
	fi
	t0=$(date +%s)
	ssh -o BatchMode=yes "$ROUTER" 'sh -s' < "$OUT/install.sh" > "$OUT/install.out" 2>&1
	tries=1
	# the README's own instruction for a cut-off download: run the same apk add again
	while ! tail -n 1 "$OUT/install.out" | grep -q '^OK:' && [ "$tries" -lt 5 ]; do
		tries=$((tries + 1)); on 'apk add hermes-agent luci-app-hermes' > "$OUT/install.out" 2>&1
	done
	secs=$(( $(date +%s) - t0 ))
	ver=$(on "apk list --installed 2>/dev/null | grep -o '^hermes-agent-[0-9][^ ]*'")
	untrusted=$(on 'apk update 2>&1 | grep -ci untrusted')
	if tail -n 1 "$OUT/install.out" | grep -q '^OK:' && [ -n "$ver" ] && [ "$untrusted" = 0 ]; then
		pass install "$ver in ${secs} s, $tries run(s) of apk add, $(tail -n 1 "$OUT/install.out")"
	else
		fail install "after $tries tries: $(tail -n 2 "$OUT/install.out" | tr '\n' ' ') untrusted=$untrusted"
	fi
	[ -n "${EXPECT:-}" ] && { case "$ver" in *"$EXPECT"*) pass install-version "$ver is $EXPECT" ;; *) fail install-version "$ver, expected $EXPECT" ;; esac; }
}

step_model() {
	: "${KEY_CMD:?KEY_CMD is required for the model step}"
	sh -c "$KEY_CMD" | tr -d '\n' | on 'umask 077; cat > /etc/hermes-agent/provider.key'
	on "uci set hermes.main.base_url='$BASE_URL'; uci set hermes.main.model='$MODEL'; uci set hermes.main.enabled=1; uci commit hermes"
	m=$(on "ls -l /etc/hermes-agent/provider.key | awk '{print \$1, \$3}'; wc -c < /etc/hermes-agent/provider.key" | tr '\n' ' ')
	case "$m" in "-rw------- root "[1-9]*) pass model "key file $m bytes, $MODEL at $BASE_URL" ;; *) fail model "key file: $m" ;; esac
}

step_start() {
	g0=$(on "wc -l < /srv/hermes/logs/gateway.log 2>/dev/null || echo 0")
	mark start; on '/etc/init.d/hermes-agent restart' >>"$LOG" 2>&1
	# up means warmed, not merely forked: the gateway holds ~20 MB at exec and ~190 MB once warm
	i=0; while [ "$i" -lt 120 ] && ! on "tail -n +$((g0 + 1)) /srv/hermes/logs/gateway.log 2>/dev/null | grep -q 'Turn machinery warmed'"; do sleep 3; i=$((i + 3)); done
	if gateway_up 90; then
		run <<'EOF'
p=$(pgrep -f '[m]ain.py gateway' | head -n 1)
echo "uid=$(awk '/^Uid/ {print $2}' /proc/$p/status) hermes=$(id -u hermes) rss=$(awk '/VmRSS/ {print int($2/1024)}' /proc/$p/status)"
EOF
		ids=$(tail -n 1 "$LOG")
		refused=$(since start | grep -ciE 'refus|not starting')
		case "$ids" in "uid="*) u=${ids#uid=}; u=${u%% *}; h=${ids#*hermes=}; h=${h%% *} ;; *) u=x; h=y ;; esac
		[ "$u" = "$h" ] && [ "$refused" = 0 ] && pass start "gateway up as hermes, ${ids##*rss=} MB resident, no refusal" \
			|| fail start "$ids, refusals since start: $refused"
	else
		fail start "no gateway within 90 s: $(since start | grep -i hermes | tail -n 3 | tr '\n' ' ')"
	fi
	on '/usr/bin/python3 -I -B /usr/libexec/hermes-drop hermes /bin/sh -c "ping -c 1 -W 2 1.1.1.1"' > "$OUT/ping.out" 2>&1 \
		&& pass ping-as-hermes "$(tail -n 1 "$OUT/ping.out")" || fail ping-as-hermes "$(tail -n 1 "$OUT/ping.out")"
}

step_telegram() {
	: "${TG_CMD:?TG_CMD is required for the telegram step}" "${TG_ID:?TG_ID is required}"
	out=$(on 'apk add hermes-agent-telegram 2>&1 | tail -n 1')
	sh -c "$TG_CMD" | tr -d '\n' | on 'umask 077; cat > /etc/hermes-agent/telegram.token'
	on "uci set hermes.telegram.enabled=1; uci -q del hermes.telegram.allow_user_id; uci add_list hermes.telegram.allow_user_id='$TG_ID'; uci commit hermes"
	mark telegram; on '/etc/init.d/hermes-agent restart' >>"$LOG" 2>&1
	gateway_up 90 && sleep 15
	bad=$(since telegram | grep -c 'telegram is enabled but')
	conn=$(on "grep -ciE 'telegram.*(connected|polling|started)' /srv/hermes/logs/gateway.log")
	[ "$bad" = 0 ] && [ "$conn" -gt 0 ] && pass telegram "$out; adapter up, only $TG_ID allowed" \
		|| fail telegram "$out; refusals $bad, adapter lines $conn"
}

step_ask() { # a person writes to the bot; nothing else can, since a bot cannot message itself
	n0=$(on "grep -c 'API call #' /srv/hermes/logs/agent.log")
	say "ASK: send the bot, from Telegram id $TG_ID: «Почему тормозит интернет? Проверь на роутере.»"
	say "     waiting up to ${ASK_WAIT:-300} s for the agent to answer"
	t0=$(date +%s); seen=0
	while [ $(( $(date +%s) - t0 )) -lt "${ASK_WAIT:-300}" ]; do
		n=$(on "grep -c 'API call #' /srv/hermes/logs/agent.log")
		if [ "$n" -gt "$n0" ]; then
			[ "$seen" = 0 ] && { seen=$(date +%s); }
			last=$n; sleep 20
			[ "$(on "grep -c 'API call #' /srv/hermes/logs/agent.log")" = "$last" ] && break
		else sleep 5; fi
	done
	[ "$seen" = 0 ] && { fail ask "no model call within ${ASK_WAIT:-300} s of asking"; return; }
	on "tail -n 400 /srv/hermes/logs/agent.log" > "$OUT/ask.log"
	denied=$(grep -c 'permission denied' "$OUT/ask.log")
	pings=$(grep -c 'packet loss' "$OUT/ask.log")
	[ "$denied" = 0 ] && pass ask "$((last - n0)) model calls, $pings ping result(s) read, no permission denied; read the reply in Telegram" \
		|| fail ask "$denied 'permission denied' in the agent's tool output"
}

step_watch() { # docs/use.md's hourly watch, with docs/examples/router_check.sh, run once now
	on 'mkdir -p /srv/hermes/scripts && cat > /srv/hermes/scripts/router_check.sh && chmod 755 /srv/hermes/scripts/router_check.sh && chown -R hermes:hermes /srv/hermes/scripts' \
		< "$ROOT/docs/examples/router_check.sh"
	id=$(on "HERMES_HOME=/srv/hermes hermes cron create 1m 'Below is the router data. If everything is normal, reply with exactly [SILENT]. Otherwise say in two lines what is wrong. Do not call any tools.' --name hw-flow-watch --script router_check.sh --repeat 1 --deliver telegram:$TG_ID --reasoning-effort none 2>&1" | sed -n 's/^Created job: //p')
	[ -n "$id" ] || { fail watch "the job was not created"; return; }
	i=0; while [ "$i" -lt 180 ] && ! on "ls /srv/hermes/cron/output/$id/*.md >/dev/null 2>&1"; do sleep 10; i=$((i + 10)); done
	f=$(on "ls -t /srv/hermes/cron/output/$id/*.md 2>/dev/null | head -n 1")
	[ -n "$f" ] || { fail watch "job $id produced no output in 180 s"; return; }
	on "cat '$f'" > "$OUT/watch.md"
	grep -q 'ping 1.1.1.1: loss' "$OUT/watch.md" && ! grep -q 'failed: ping' "$OUT/watch.md" \
		&& pass watch "job $id ran router_check.sh as hermes; reply: $(sed -n '/## Response/,$p' "$OUT/watch.md" | sed -n '3p' | cut -c1-120)" \
		|| fail watch "router_check.sh output not as expected (see $OUT/watch.md)"
}

step_admin() { # what the agent's own token may do to the router, through openwrt-mcp, as the agent would
	on 'cat > /tmp/mcp-probe.py' < "$ROOT/scripts/mcp-probe.py"
	probe() { on "python3 /tmp/mcp-probe.py '$1' '$2'"; }
	r=$(probe ubus_call '{"object":"luci-rpc","method":"getDHCPLeases"}')
	case "$r" in OK*) pass admin-read-clients "DHCP leases readable without unlocking" ;; *) fail admin-read-clients "$r" ;; esac
	r=$(probe ubus_call '{"object":"network.interface","method":"dump"}')
	case "$r" in OK*) pass admin-read-network "interfaces readable without unlocking" ;; *) fail admin-read-network "$r" ;; esac
	CHANGE='{"changes":[{"config":"system","section":"@system[0]","option":"description","value":"hw-flow"}]}'
	r=$(probe uci_apply "$CHANGE")
	case "$r" in ERROR*denied*) pass admin-locked "a change with no factor set is refused: ${r#ERROR }" ;; *) fail admin-locked "a change went through with no factor: $r" ;; esac
	# The policy as written, so the report says what an open window grants rather than what we hope.
	on "uci -q get openwrt-mcp.hermes_main_change.scopes; uci -q get openwrt-mcp.hermes_main_change.tools" > "$OUT/change-policy.txt" 2>&1 || true
	[ -n "${FLOW_PIN:-}" ] || { say "SKIP admin-unlock: FLOW_PIN (a throwaway test PIN) not given"; on 'rm -f /tmp/mcp-probe.py'; return; }
	printf '%s\n' "$FLOW_PIN" | on 'openwrt-mcp pin set hermes-main >/dev/null 2>&1'
	on 'uci set hermes.security.factor=pin; uci commit hermes; /etc/init.d/hermes-agent restart >/dev/null 2>&1'
	gateway_up 90; sleep 15
	scopes=$(on "uci -q get openwrt-mcp.hermes_main_change.scopes" 2>/dev/null)
	say "admin: the change policy written with factor pin grants scopes: ${scopes:-<none>}"
	r=$(probe uci_apply "$CHANGE")
	case "$r" in ERROR*"second factor"*) pass admin-needs-unlock "with a PIN set, a change waits for the owner's unlock" ;; *) fail admin-needs-unlock "$r" ;; esac
	r=$(probe mfa_unlock '{"pin":"00000000"}')
	case "$r" in ERROR*) pass admin-wrong-pin "a wrong PIN is refused" ;; *) fail admin-wrong-pin "$r" ;; esac
	r=$(probe mfa_unlock "{\"pin\":\"$FLOW_PIN\"}")
	case "$r" in OK*Unlocked*) pass admin-unlock "${r#OK }" ;; *) fail admin-unlock "$r" ;; esac
	r=$(probe uci_apply "$CHANGE")
	now=$(on "uci -q get system.@system[0].description")
	case "$r" in OK*"ROLLBACK ARMED"*) pass admin-change-in-window "applied (value now '$now'), rollback armed" ;; *) fail admin-change-in-window "$r" ;; esac
	secs=$(echo "$r" | sed -n 's/.*(in \([0-9]*\)m\([0-9]*\)s).*/\1 \2/p' | awk '{print $1*60+$2+20}')
	sleep "${secs:-110}"
	after=$(on "uci -q get system.@system[0].description || echo unset")
	[ "$after" != "hw-flow" ] && pass admin-rollback "unconfirmed change undone by itself (now '$after')" || fail admin-rollback "still '$after' after the deadline"
	probe mfa_lock '{}' >/dev/null
	on 'uci set hermes.security.factor=none; uci commit hermes; openwrt-mcp pin clear hermes-main >/dev/null 2>&1; /etc/init.d/hermes-agent restart >/dev/null 2>&1; rm -f /tmp/mcp-probe.py'
	say "admin: test PIN cleared, factor back to none"
}

step_reboot() {
	[ "${REBOOT_OK:-0}" = 1 ] || { say "SKIP reboot: needs REBOOT_OK=1, given for this router by its owner"; return; }
	on 'reboot' >/dev/null 2>&1; sleep 30
	i=0; while [ "$i" -lt 240 ] && ! on true 2>/dev/null; do sleep 5; i=$((i + 5)); done
	gateway_up 120 && pass reboot "the router came back and the gateway started by itself" || fail reboot "no gateway 2 min after the router came back"
}

step_upgrade() {
	before=$(on "uci export hermes | md5sum; ls /etc/rc.d | grep -c S95hermes-agent" | tr '\n' ' ')
	on 'apk update >/dev/null 2>&1; apk upgrade hermes-agent luci-app-hermes openwrt-mcp hermes-agent-telegram 2>&1 | tail -n 1' >>"$LOG" 2>&1
	after=$(on "uci export hermes | md5sum; ls /etc/rc.d | grep -c S95hermes-agent" | tr '\n' ' ')
	world=$(on "grep -c 'hermes-agent=' /etc/apk/world")
	[ "$before" = "$after" ] && [ "$world" = 0 ] && pass upgrade "configuration and start at boot as they were, world unpinned" \
		|| fail upgrade "before '$before' after '$after' pinned=$world"
}

step_remove() {
	on '/etc/init.d/hermes-agent stop; apk del luci-app-hermes hermes-agent-telegram hermes-agent openwrt-mcp 2>&1 | tail -n 1' >>"$LOG" 2>&1
	left=$(on "ls /usr/bin/hermes /etc/rc.d/S95hermes-agent /usr/lib/hermes-agent/site-packages 2>/dev/null | wc -l")
	[ "$left" = 0 ] && pass remove "programs and start link gone; data, keys and account kept, as docs/install-notes.md says" \
		|| fail remove "$left package paths left"
}

STEPS=${*:-clean install model start telegram ask watch admin upgrade}
say "hw-flow on $ROUTER, $(on 'cat /etc/apk/arch; . /etc/openwrt_release; echo $DISTRIB_RELEASE' | tr '\n' ' '), steps: $STEPS"
for s in $STEPS; do "step_$s"; done
say "hw-flow: $FAILED failed; log $LOG"
[ "$FAILED" = 0 ]
