#!/bin/sh
# teeth-unlock.sh -- prove gate-unlock.sh can fail, and fail at the right check.
#
# One planted fault for each check the gate implements, twelve in all. Each is a change a
# real edit could make, applied to a copy of the installed file and laid over the
# installation inside the gate's container (OVERLAY), and each must turn ITS check red and
# no other: the gate is run with ONLY naming that one check, and the FAIL line has to be
# there. A fault that leaves its check green, or turns it red for a reason that has nothing
# to do with the fault, means the check is thinner than its name says.
#
# And the three things around the faults, so that the reds above were the faults and not the
# harness: every implemented check passes with nothing planted, a name that matches no check is
# "measured nothing" and not a pass, and a scenario whose check does not exist yet (stage 4
# and 5) fails with NOT IMPLEMENTED instead of being skipped.
#
# The faults go into files copied out of the BUILT tree, never into the build tree itself, so
# a run that goes red partway leaves nothing behind for the next build to inherit.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
LINE=${LINE:-25.12}
TREE="$ROOT/build/$LINE/$ARCH/tree"
[ -d "$TREE" ] || { echo "teeth-unlock: no build tree at $TREE; build the package first:"
	echo "  ./package/hermes-agent/build-in-container.sh $ARCH"; exit 1; }

# The tree must be the repository's: a stale build would plant faults in files the gate
# then does not install.
for pair in hermes-agent.init:etc/init.d/hermes-agent hermes-gateway:usr/sbin/hermes-gateway \
	set-toolsets.py:usr/libexec/hermes-set-toolsets hermes-drop.py:usr/libexec/hermes-drop; do
	cmp -s "$ROOT/package/hermes-agent/files/${pair%%:*}" "$TREE/${pair##*:}" || {
		echo "teeth-unlock: ${pair##*:} in the build tree differs from the repository's; rebuild first:" >&2
		echo "  ./package/hermes-agent/build-in-container.sh $ARCH" >&2
		exit 1; }
done

W=$(mktemp -d "${TMPDIR:-/tmp}/teeth-unlock.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
OUT="$W/out"

# plant <path in the installation> <before> <after>: copy that file out of the build tree
# with `before` replaced by `after`, into the overlay. Exactly one occurrence, or nothing was
# measured.
plant() {
	rel=$1; before=$2; after=$3
	mkdir -p "$W/overlay/$(dirname "$rel")"
	python3 - "$TREE/$rel" "$W/overlay/$rel" "$before" "$after" <<'PY'
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

# A scenario with no check behind it yet is red, not skipped.
if ONLY=check_pin_alone_unlocks ARCH="$ARCH" "$ROOT/scripts/gate-unlock.sh" >"$OUT" 2>&1; then
	echo "TEETH FAIL: a check that is not implemented passed"; exit 1
fi
grep -q 'NOT IMPLEMENTED' "$OUT" || { echo "TEETH FAIL: an unimplemented check failed, but not as NOT IMPLEMENTED"; tail -n 3 "$OUT"; exit 1; }
echo "teeth ok: an unimplemented check -> NOT IMPLEMENTED"

echo "teeth-unlock: 12 faults, 12 distinct checks, controls green"
