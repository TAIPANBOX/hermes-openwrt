#!/bin/sh
# teeth-unlock.sh -- prove gate-unlock.sh can fail, and fail at the right check.
#
# One planted fault for each check the gate implements, and more for the ones that guard a secret
# or have several ways to go wrong (forty-two in all, over thirty-five checks). Each is a change a
# real edit could make, applied to a copy of the installed file and laid over the
# installation inside the gate's container (OVERLAY), and each must turn ITS check red and
# no other: the gate is run with ONLY naming that one check, and the FAIL line has to be
# there. A fault that leaves its check green, or turns it red for a reason that has nothing
# to do with the fault, means the check is thinner than its name says.
#
# And the three things around the faults, so that the reds above were the faults and not the
# harness: every implemented check passes with nothing planted, a name that matches no check is
# "measured nothing" and not a pass, and a scenario whose check does not exist yet fails with
# NOT IMPLEMENTED instead of being skipped (none is left, so a name is made up for the control).
#
# The faults go into files copied out of the BUILT tree, never into the build tree itself, so
# a run that goes red partway leaves nothing behind for the next build to inherit.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
LINE=${LINE:-25.12}
TREE="$ROOT/build/$LINE/$ARCH/tree"
# The LuCI app's own tree: the Security page's rpcd backend is what stage 5's checks run.
LUCI_TREE="$ROOT/build/luci-app-hermes-apk/tree"
[ -d "$TREE" ] || { echo "teeth-unlock: no build tree at $TREE; build the package first:"
	echo "  ./package/hermes-agent/build-in-container.sh $ARCH"; exit 1; }

# The tree must be the repository's: a stale build would plant faults in files the gate
# then does not install.
for pair in hermes-agent.init:etc/init.d/hermes-agent hermes-agent.config:etc/config/hermes hermes-gateway:usr/sbin/hermes-gateway \
	set-toolsets.py:usr/libexec/hermes-set-toolsets hermes-drop.py:usr/libexec/hermes-drop \
	openwrt_unlock.py:usr/lib/hermes-agent/site-packages/openwrt_unlock.py; do
	cmp -s "$ROOT/package/hermes-agent/files/${pair%%:*}" "$TREE/${pair##*:}" || {
		echo "teeth-unlock: ${pair##*:} in the build tree differs from the repository's; rebuild first:" >&2
		echo "  ./package/hermes-agent/build-in-container.sh $ARCH" >&2
		exit 1; }
done

cmp -s "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$LUCI_TREE/usr/libexec/rpcd/hermes" || {
	echo "teeth-unlock: usr/libexec/rpcd/hermes in the LuCI build tree differs from the repository's; rebuild first:" >&2
	echo "  ./package/luci-app-hermes/build.sh" >&2
	exit 1; }

W=$(mktemp -d "${TMPDIR:-/tmp}/teeth-unlock.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
OUT="$W/out"

# plant <path in the installation> <before> <after> [tree]: copy that file out of the build tree
# (the agent's, or the LuCI app's when named) with `before` replaced by `after`, into the overlay.
# Exactly one occurrence, or nothing was measured.
plant() {
	rel=$1; before=$2; after=$3; from=${4:-$TREE}
	mkdir -p "$W/overlay/$(dirname "$rel")"
	python3 - "$from/$rel" "$W/overlay/$rel" "$before" "$after" <<'PY'
import os, shutil, sys
src, dst, before, after = sys.argv[1:5]
text = open(src).read()
if text.count(before) != 1:
    sys.exit("teeth-unlock: planted nothing: the target is missing or ambiguous: " + before[:90])
open(dst, "w").write(text.replace(before, after))
shutil.copymode(src, dst)
PY
}

expect_red() {
	name=$1; check=$2
	if ONLY="$check" OVERLAY="$W/overlay" ARCH="$ARCH" "$ROOT/scripts/gate-unlock.sh" >"$OUT" 2>&1; then
		echo "TEETH FAIL: $name left $check green"; tail -n 15 "$OUT"; exit 1
	fi
	grep -q "^FAIL .*$check:" "$OUT" || {
		echo "TEETH FAIL: $name turned the gate red, but not at $check"; grep -E '^(FAIL|overlay)' "$OUT" | head -5; exit 1; }
	echo "teeth ok: $name -> $check ($(grep "^FAIL .*$check:" "$OUT" | sed 's/^FAIL [^:]*: //' | cut -c1-110))"
	rm -rf "$W/overlay"
}

INIT=etc/init.d/hermes-agent
WRAP=usr/sbin/hermes-gateway

# ---- 1. the wrapper starts the gateway as root again ----
# Everything else in the wrapper still runs: the keys, the ceiling, the bridge. Only the last
# line goes back to a plain exec, which is the shape the package had until 0.21.5-r2.
plant "$WRAP" 'exec $DROP "$run_user" /usr/bin/hermes gateway run --external-supervisor' \
	'exec /usr/bin/hermes gateway run --external-supervisor'
expect_red "the gateway started without the drop" check_gateway_runs_as_hermes_user

# ---- 2. /etc/hermes-agent opened up so the dropped gateway can read its key ----
# The natural bug once the agent is not root: the wrapper cannot read the key as hermes, so
# somebody makes the directory and the files readable. This one does it where the router MCP
# token is made.
plant "$INIT" 'chmod 0600 "$tmp" && mv "$tmp" "$token_file" || return 1' \
	'chmod 0644 "$tmp" && mv "$tmp" "$token_file" || return 1; chmod 0755 "$CONF"'
expect_red "the key directory opened to everyone" check_key_files_root_only

# ---- 3. the memory ceiling applied after the drop ----
# The ceiling is a write to the cgroup, which only root may make. Moved behind the drop it
# is refused, and the start with it, or worse, skipped by whoever then makes it optional.
plant "$WRAP" '/usr/bin/python3 /usr/libexec/hermes-memory "${HERMES_MEM_MAX_MB:-512}"' \
	'$DROP "$run_user" /usr/bin/python3 /usr/libexec/hermes-memory "${HERMES_MEM_MAX_MB:-512}"'
expect_red "the ceiling applied as hermes" check_memory_ceiling_non_root

# ---- 4. the data directory of the root-era release never handed over ----
plant "$INIT" 'if [ "$owner" != "$uid" ]; then' 'if false; then'
expect_red "the data directory left with root" check_upgrade_hands_data_dir_to_hermes

# ---- 5. no profile set means root again ----
# The most expensive one-word mistake in the package: an unset profile on an upgraded router
# running the agent as root with no unlock, and saying so nowhere.
plant "$INIT" 'hermes_profile_canonical "${profile_set:-owner}"' 'hermes_profile_canonical "${profile_set:-root}"'
expect_red "an unset profile means root" check_root_profile_is_opt_in_and_warned

# ---- 6. the change policy written ahead of the reads ----
# openwrt-mcp takes the first policy of a client that covers a call, so a change policy that
# comes first and covers everything asks for the second factor on a plain read of the board.
plant "$INIT" 'uci -q batch < "$scratch/batch" && uci -q commit openwrt-mcp || {' \
	'uci -q batch < "$scratch/batch" && { uci -q reorder "openwrt-mcp.${prefix}change=0"; true; } && uci -q commit openwrt-mcp || {'
expect_red "the change policy ahead of the read policies" check_reads_need_no_unlock

# ---- 7. a change policy that asks for no second factor ----
# Present, granting every change, and never consulting the factor: the shape of a control that
# is there and protects nothing.
plant "$INIT" 'add_list openwrt-mcp.%schange.scopes='"'*'"'\nadd_list openwrt-mcp.%schange.mfa_tools='"'*'"'\n" "$prefix" "$prefix"' \
	'add_list openwrt-mcp.%schange.scopes='"'*'"'\n" "$prefix"'
expect_red "the change policy without mfa_tools" check_change_refused_while_locked

# ---- 8. no factor configured treated as a PIN ----
# What an unset factor must never mean: a change policy written, so that changes wait for an
# unlock the owner never set up, instead of finding no policy at all.
plant "$INIT" '[ "$factor" = none ] && return 0' '[ "$factor" = none ] && factor=pin'
expect_red "no factor written as a PIN" check_no_factor_means_no_changes

# ---- 9. the unlock tools offered to the model ----
plant usr/libexec/hermes-set-toolsets \
	'expected = {"url": url, "headers": headers, "tools": {"exclude": list(MCP_HIDDEN)}}' \
	'expected = {"url": url, "headers": headers}'
expect_red "mfa_unlock and mfa_lock not excluded" check_unlock_tools_hidden_from_model

# ---- 10. every agent paired under one client name ----
# Unlocking is per client, so agents that share a name share an unlock.
plant "$INIT" 'local client="hermes-$agent" tmp tok' 'local client="hermes-main" tmp tok'
expect_red "every agent paired as hermes-main" check_unlock_is_per_agent

# ---- 11. the state directory moved into RAM ----
# The rollback snapshot is only as durable as the directory it is in. A link from
# /etc/openwrt-mcp to a tmpfs keeps every path the same and loses the point, and a reboot
# empties it, along with the one record that the change was never confirmed.
mkdir -p "$W/overlay/tmp/owmcp-state" "$W/overlay/etc"
ln -s /tmp/owmcp-state "$W/overlay/etc/openwrt-mcp"
expect_red "the openwrt-mcp state directory in RAM" check_rollback_survives_reboot

# ---- 12. the change policy grants the tool that answers with a private key ----
plant "$INIT" '	for tool in ubus_call uci_apply uci_confirm; do' '	for tool in ubus_call uci_apply uci_confirm wg_new_client; do'
expect_red "wg_new_client back in the change policy" check_change_policy_hands_out_no_private_key

# ---- the Hermes-side half: the plugin, and the init lines that tell the daemon what to ask ----
# Faults in the plugin are planted in the copy of site-packages/openwrt_unlock.py of the built
# tree, laid over the installation by OVERLAY exactly as the faults above are.
PLUGIN=usr/lib/hermes-agent/site-packages/openwrt_unlock.py

# ---- 13. a scheduled job's change let through ----
plant "$PLUGIN" '        if not _is_scheduled(ctx):
            return None' '        if True:
            return None'
expect_red "a scheduled job told apart from nobody" check_scheduled_job_cannot_change

# ---- 14. the PIN sent to the daemon backwards ----
plant "$PLUGIN" '        return {"pin": tokens[0]}' '        return {"pin": tokens[0][::-1]}'
expect_red "the PIN reversed on its way to the daemon" check_pin_alone_unlocks

# ---- 15. the code sent to the daemon backwards ----
plant "$PLUGIN" '        return {"code": tokens[0]}' '        return {"code": tokens[0][::-1]}'
expect_red "the code reversed on its way to the daemon" check_code_alone_unlocks

# ---- 16. pin+totp written as a PIN alone ----
# Both factors configured, the daemon asked for one: a right PIN and a wrong code open changes.
plant "$INIT" '"$prefix" "$factor" "$prefix" "$window"' '"$prefix" "${factor%+totp}" "$prefix" "$window"'
expect_red "pin+totp written as pin" check_pin_and_code_both_required

# ---- 17. a PIN kept in the clear by the tool that sets it ----
# The daemon is a dependency, so the fault is a stand-in for it: a wrapper ahead of it on the
# PATH that sets the PIN and then writes the PIN down as typed.
mkdir -p "$W/overlay/usr/sbin"
cat > "$W/overlay/usr/sbin/openwrt-mcp" <<'SHIM'
#!/bin/sh
if [ "$1" = pin ] && [ "$2" = set ]; then
	pin=$(cat)
	printf '%s\n' "$pin" | /usr/bin/openwrt-mcp "$@"; rc=$?
	printf '%s pbkdf2-sha256$1$%s$%s\n' "$3" "$pin" "$pin" > /etc/openwrt-mcp/pin
	exit $rc
fi
exec /usr/bin/openwrt-mcp "$@"
SHIM
chmod 755 "$W/overlay/usr/sbin/openwrt-mcp"
expect_red "a PIN stored as typed" check_pin_stored_as_slow_hash

# ---- 18. no limit on wrong tries ----
plant "$INIT" '"$prefix" "$max_failures" "$prefix" "$lockout"' '"$prefix" "100000" "$prefix" "$lockout"'
expect_red "a limit of a hundred thousand wrong tries" check_wrong_attempts_lock_out

# ---- 19. the owner is not told a code was used ----
# The replay itself is the daemon's. What this reads is the state it reports and the words the
# owner is given, so a plugin that stops saying why is caught here.
plant "$PLUGIN" '    if "already used" in low and factor == "totp":' '    if False:'
expect_red "a used code refused without saying so" check_code_works_once

# ---- 20. a window that does not end ----
plant "$INIT" '"$prefix" "$window" "$prefix" "$max_failures"' '"$prefix" "24h" "$prefix" "$max_failures"'
expect_red "a window of a day" check_unlock_window_ends

# ---- 21. /lock that asks for nothing ----
plant "$PLUGIN" '            tool, arguments = "mfa_lock", {}' '            tool, arguments = "ubus_list", {}'
expect_red "/lock that does not lock" check_lock_closes_at_once

# ---- 22. the message left in the chat ----
plant "$PLUGIN" '            deleted = bool(await delete())' '            deleted = True'
expect_red "the unlock message never deleted" check_unlock_message_deleted_and_never_reaches_model

# ---- 23. the request to the model sent as it is ----
plant "$PLUGIN" '        fixed = _walk(request, factor)
        if fixed is request:
            return None' '        return None'
expect_red "the model's request not scrubbed" check_unlock_while_busy_never_reaches_model

# ---- 24. a bare PIN and code treated as an ordinary message ----
plant "$PLUGIN" '    if factor in FACTORS and BARE.match(text):' '    if False and BARE.match(text):'
expect_red "a bare PIN and code not recognised" check_bare_code_is_an_unlock_attempt

# ---- 25. the Telegram library left at DEBUG ----
plant "$PLUGIN" '    logging.getLogger("telegram").setLevel(logging.INFO)' '    pass'
expect_red "the Telegram library left printing every update" check_secret_in_no_log

# ---- 26. a group let unlock ----
plant "$PLUGIN" '        if not private:' '        if False:'
expect_red "a group treated as the private chat" check_unlock_refused_in_group

# ---- 27. anyone let try ----
plant "$PLUGIN" '        if not authorized(user_id):' '        if False:'
expect_red "the allowlist not consulted" check_unlock_only_from_allowlist

# ---- 28. the gateway hook gone: an edit into /unlock is seen by nothing that deletes it ----
# Telegram sends an edit as edited_message, which the plugin's own Telegram handler does not
# take; the gateway turns it into a message event, and line 2 is what catches it there.
plant "$PLUGIN" '        if platform != "telegram":
            return None' '        if True:
            return None'
expect_red "the gateway hook passing every message" check_edited_unlock_never_reaches_model

# ---- the LuCI Security page's backend and the SSH enrolment (stage 5) ----
# The rpcd backend is the LuCI app's own file, laid over the installation like the others.
RPCD=usr/libexec/rpcd/hermes

# ---- 29. a phone in force the moment it is asked for ----
# enrol_start without --pending: the scan has not been proven to work, and the phone that was in
# force is already gone.
plant "$RPCD" 'mfa enrol "$SEC_CLIENT" --pending --json' 'mfa enrol "$SEC_CLIENT" --json' "$LUCI_TREE"
expect_red "enrol_start without --pending" check_luci_enrol_shows_qr_and_verifies

# ---- 30. the phone's address handed to a program as an argument ----
# jsonfilter -s takes the text as an argument, which any account on the router can read from /proc.
plant "$RPCD" "uri=\$(echo \"\$out\" | jsonfilter -e '@.uri' 2>/dev/null)" "uri=\$(jsonfilter -s \"\$out\" -e '@.uri' 2>/dev/null)" "$LUCI_TREE"
expect_red "the phone's secret given to jsonfilter as an argument" check_luci_enrol_shows_qr_and_verifies

# ---- 31. the terminal enrolment printing no QR ----
# A stand-in for openwrt-mcp ahead of it on the PATH that drops --qr, which is what the command
# would do if the flag were renamed under the README.
mkdir -p "$W/overlay/usr/sbin"
cat > "$W/overlay/usr/sbin/openwrt-mcp" <<'SHIM'
#!/bin/sh
if [ "$1 $2" = "mfa enrol" ]; then
	n=$#; i=0
	while [ "$i" -lt "$n" ]; do a=$1; shift; [ "$a" = --qr ] || set -- "$@" "$a"; i=$((i + 1)); done
fi
exec /usr/bin/openwrt-mcp "$@"
SHIM
chmod 755 "$W/overlay/usr/sbin/openwrt-mcp"
expect_red "mfa enrol printing no QR" check_cli_enrol_prints_qr

# ---- 32. the PIN left in a file ----
# A debugging line in set_pin, the commonest way a secret gets onto flash.
plant "$RPCD" 'if ! echo "$pin" | "$MCP_BIN" pin set "$SEC_CLIENT" >/dev/null 2>&1; then' \
	'echo "$pin" > /tmp/hermes-last-pin; if ! echo "$pin" | "$MCP_BIN" pin set "$SEC_CLIENT" >/dev/null 2>&1; then' "$LUCI_TREE"
expect_red "the PIN written to a file" check_luci_pin_write_only

# ---- 33. the PIN read with jshn's own loader ----
# What every rpcd backend in the tree did until LuCI r13: json_load puts the whole message on a
# `jshn` command line and json_get_var exports what it reads to every program started afterwards.
plant "$RPCD" 'pin=$(msg_get pin)' 'json_load "$MSG"; json_get_var pin pin' "$LUCI_TREE"
expect_red "the PIN read with json_load and json_get_var" check_luci_pin_write_only

# ---- r5: a router with no /srv, and the agent told the window is open ----

# ---- 34. the parents of a missing data directory made closed to everyone but root again ----
# What the init did until 0.21.5-r5, under the umask a boot starts it with.
plant "$INIT" '( umask 022; mkdir -p' '( umask 077; mkdir -p'
expect_red "the parents of the data directory made 0700" check_fresh_router_without_srv_starts

# ---- 35. a parent the agent cannot enter not named ----
# The check that names it is gone, so the start still stops, and says "cannot write", which sends the
# reader to the data directory and not to the one that stands in the way.
plant "$INIT" '	[ -n "$blocked" ] || return 0' '	return 0'
expect_red "an unreachable parent not named" check_unreachable_parent_is_named

# ---- 36. the hook never registered ----
# The plugin remembers the window and nothing ever asks it: the agent is told nothing.
plant "$PLUGIN" '    ctx.register_hook("pre_llm_call", pre_llm_call)' '    pass'
expect_red "the pre_llm_call hook not registered" check_agent_told_window_is_open

# ---- 37. /lock that leaves the agent being told ----
plant "$PLUGIN" '        if tool == "mfa_lock":
            end = None' '        if tool == "mfa_lock":
            return'
expect_red "/lock that does not end the telling" check_agent_told_window_is_open

# ---- 38. a lockout that leaves the agent being told ----
plant "$PLUGIN" '        elif tool == "mfa_unlock" and "locked out" in low:
            end = None' '        elif tool == "mfa_unlock" and "locked out" in low:
            return'
expect_red "a lockout that does not end the telling" check_agent_told_window_is_open

# ---- 39. the line left in the history the request replays ----
# New turns are not told after /lock, but the earlier turns still carry "do it now".
plant "$PLUGIN" '    if bare:
        text = _drop_stale_notes(text)' '    if False:
        text = _drop_stale_notes(text)'
expect_red "the line left in the replayed history" check_agent_told_window_is_open

# ---- 40. a scheduled job told the window is open ----
plant "$PLUGIN" '        if note is None or _is_scheduled(ctx):' '        if note is None:'
expect_red "a scheduled job told the window is open" check_agent_told_window_is_open

# ---- 41. a window that never runs out for the agent ----
plant "$PLUGIN" '    if end is None or time.time() >= end:' '    if end is None:'
expect_red "the end of the window ignored" check_agent_not_told_after_window_ends

# ---- 42. the config file showing the one-step enrolment again ----
# The shipped config is what an owner reads on the router first. It once still gave `enrol` without
# --pending, which puts the new phone in force before a code of it was ever entered.
plant etc/config/hermes 'openwrt-mcp mfa enrol hermes-main --pending --qr' 'openwrt-mcp mfa enrol hermes-main --qr'
expect_red "the config file's enrol command without --pending" check_cli_enrol_prints_qr

# ---- and the controls ----
# Nothing planted: every implemented check passes, so the reds above were the faults and not the harness.
# Counted from the gate's own list, so this cannot go stale when a check is added.
IMPLEMENTED=$(sed -n "s/^IMPLEMENTED='\(.*\)'$/\1/p" "$ROOT/scripts/gate-unlock.sh")
N=$(echo $IMPLEMENTED | wc -w | tr -d ' ')
[ "$N" -gt 0 ] || { echo "TEETH FAIL: read no implemented check from gate-unlock.sh; measured nothing"; exit 1; }
if ! ONLY="$IMPLEMENTED" ARCH="$ARCH" "$ROOT/scripts/gate-unlock.sh" >"$OUT" 2>&1; then
	echo "TEETH FAIL: with nothing planted the implemented checks are not green, so a fault was not undone"
	grep -E '^FAIL' "$OUT"; exit 1
fi
grep -q "^gate-unlock: $N passed, 0 failed" "$OUT" || { echo "TEETH FAIL: the clean run did not pass all $N"; tail -n 3 "$OUT"; exit 1; }
echo "teeth ok: nothing planted -> all $N pass"

# A name that matches no check measures nothing, and says so.
if ONLY=check_that_does_not_exist ARCH="$ARCH" "$ROOT/scripts/gate-unlock.sh" >"$OUT" 2>&1; then
	echo "TEETH FAIL: a name that matches no check passed"; exit 1
fi
grep -q 'measured nothing' "$OUT" || { echo "TEETH FAIL: no check named, but the gate did not say it measured nothing"; tail -n 3 "$OUT"; exit 1; }
echo "teeth ok: no such check -> measured nothing"

# A scenario with no check behind it yet is red, not skipped. Every scenario has one now, so the
# gate is told of a name that has none.
if NOT_BUILT=check_a_scenario_with_no_check ONLY=check_a_scenario_with_no_check ARCH="$ARCH" "$ROOT/scripts/gate-unlock.sh" >"$OUT" 2>&1; then
	echo "TEETH FAIL: a check that is not implemented passed"; exit 1; fi
grep -q 'NOT IMPLEMENTED' "$OUT" || { echo "TEETH FAIL: an unimplemented check failed, but not as NOT IMPLEMENTED"; tail -n 3 "$OUT"; exit 1; }
echo "teeth ok: an unimplemented check -> NOT IMPLEMENTED"

echo "teeth-unlock: 42 faults, $N distinct checks, controls green"
