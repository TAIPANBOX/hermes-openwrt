#!/usr/bin/env python3
"""@codex 2026-09-19: mutate only disposable-container copies, require targeted reds."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = Path(os.environ['PRODUCT_FILES'])


def run(test=None):
    command = [sys.executable, str(ROOT / 'scripts/test-runtime.py')]
    if test:
        command += ['RuntimeTests.' + test]
    return subprocess.run(command, check=False, capture_output=True, text=True)


mutants = [
    ('UCI model ignored', 'set-toolsets.py', '        if len(sys.argv) in (6, 7):',
     '        if False:', 'test_model_endpoint_produces_agent_reply'),
    ('runtime conflicts ignored', 'runtime-check.py', '        return 1',
     '        return 0', 'test_runtime_override_conflicts_are_refused'),
    ('platform defaults ignored', 'set-toolsets.py', 'platforms[platform] = list(dict.fromkeys(wanted + extras))',
     'config["toolsets"] = wanted.copy()', 'test_gateway_selection'),
    ('plugin selection erased', 'set-toolsets.py', 'wanted + extras',
     'wanted', 'test_existing_plugin_and_mcp_selection_survives'),
    ('invalid configuration ignored', 'set-toolsets.py', '        return 1',
     '        return 0', 'test_bad_yaml_is_fatal_and_preserved'),
    ('MCP connection ignored', 'set-toolsets.py', '        if len(sys.argv) >= 4:',
     '        if False:', 'test_mcp_configuration'),
    ('Telegram secret stored by procd', 'hermes-agent.init', 'HERMES_TELEGRAM_TOKEN_FILE="$tg_token_file"',
     'TELEGRAM_BOT_TOKEN="$tg_token"', 'test_all_secrets_absent_from_procd'),
    ('MCP secret stored by procd', 'hermes-agent.init', 'HERMES_MCP_TOKEN_FILE="$mcp_token_file"',
     'OPENWRT_MCP_TOKEN="$(read_secret "$mcp_token_file")"', 'test_all_secrets_absent_from_procd'),
    ('MCP token not delivered', 'hermes-gateway', 'export OPENWRT_MCP_TOKEN="$token"',
     ': # omitted export', 'test_wrapper_rotation_and_disabled_credentials'),
    ('ceiling not applied', 'memory-limit.py', '        apply(sys.argv[1])',
     '        pass', 'test_memory_kernel_and_fail_closed'),
    ('wrong cgroup accepted', 'memory-limit.py', '    if membership != [INSTANCE]:',
     '    if False:', 'test_memory_validation_and_identity'),
    ('limits not written', 'memory-limit.py', '    target.write_text(value)',
     '    pass  # limits not written', 'test_memory_kernel_and_fail_closed'),
    ('UCI not re-applied at exec', 'hermes-gateway',
     '$DROP "$run_user" /usr/bin/python3 /usr/libexec/hermes-set-toolsets "$HERMES_HOME" '
     '"$HERMES_OPENWRT_TOOLSETS" "$mcp_effective" "$OPENAI_BASE_URL" "$HERMES_MODEL" "$profile"',
     ': # bridge skipped', 'test_wrapper_reapplies_uci_after_model_switch'),
    ('LAN endpoint left to bare custom', 'hermes-gateway', 'export CUSTOM_BASE_URL="$OPENAI_BASE_URL"',
     ': # not exported', 'test_endpoint_on_the_lan_starts_and_answers'),
    ('CUSTOM_BASE_URL left to .env', 'runtime-check.py', '                 "CUSTOM_BASE_URL",\n', '',
     'test_dotenv_cannot_move_the_endpoint_the_wrapper_names'),
    ('respawn unbounded', 'hermes-agent.init', 'procd_set_param respawn 3600 5 5',
     'procd_set_param respawn 3600 5 0', 'test_procd_respawn_is_bounded'),
    ('zero keeps the old ceiling', 'memory-limit.py', '        _lift_previous_ceiling()',
     '        pass  # zero keeps the old ceiling', 'test_memory_zero_lifts_previous_ceiling'),
    ('text compared, not data', 'set-toolsets.py', '        if path.exists() and config == original:',
     '        if False:', 'test_config_untouched_when_already_current'),
    ('missing MCP token fatal', 'hermes-gateway',
     'echo "hermes-gateway: router MCP token file ${HERMES_MCP_TOKEN_FILE:-} is missing or empty; '
     'starting without the MCP connection" >&2',
     'echo "hermes-gateway: router MCP token file ${HERMES_MCP_TOKEN_FILE:-} is missing or empty; '
     'starting without the MCP connection" >&2; exit 1',
     'test_wrapper_drops_mcp_when_token_missing'),
    ('zero lifts a cgroup it is not in', 'memory-limit.py', '    if _instance_membership() != [INSTANCE]:',
     '    if False:', 'test_memory_zero_lifts_previous_ceiling'),
    ('bridge ignores the profile', 'set-toolsets.py',
     '    profile = sys.argv[6] if len(sys.argv) == 7 else None',
     '    profile = None',
     'test_assistant_profile_removes_command_and_file_tools'),
    ('admin also strips operator entries', 'set-toolsets.py',
     '                    kept = [name for name in disabled if name not in GOVERNED]',
     '                    kept = []',
     'test_admin_profile_restores_them_and_keeps_operator_entries'),
    ('init default flips to root', 'hermes-agent.init',
     'hermes_profile_canonical "${profile_set:-owner}"',
     'hermes_profile_canonical "${profile_set:-root}"',
     'test_profile_defaults_to_owner_and_refuses_unknown'),
    ('wrapper default flips to root', 'hermes-gateway',
     '"${HERMES_OPENWRT_PROFILE:-owner}"', '"${HERMES_OPENWRT_PROFILE:-root}"',
     'test_wrapper_reapplies_profile_at_exec'),
    ('wrapper default flips to assistant', 'hermes-gateway',
     '"${HERMES_OPENWRT_PROFILE:-owner}"', '"${HERMES_OPENWRT_PROFILE:-assistant}"',
     'test_wrapper_reapplies_profile_at_exec'),
    ('profile note not written', 'set-toolsets.py',
     '                    agent_cfg["system_prompt"] = (own + NOTE_SEP + note) if own else note',
     '                    pass',
     'test_assistant_profile_tells_the_agent_what_it_cannot_do'),
    ("operator's prompt replaced by the note", 'set-toolsets.py',
     '(own + NOTE_SEP + note) if own else note', 'note',
     'test_assistant_profile_tells_the_agent_what_it_cannot_do'),
    ("operator's prompt trimmed on the way back", 'set-toolsets.py',
     '        text = before + after', '        text = (before + after).strip()',
     'test_assistant_profile_tells_the_agent_what_it_cannot_do'),
    ('the unlock plugin never enabled', 'set-toolsets.py',
     '                plugins["enabled"] = list(listed) + [UNLOCK_PLUGIN]', '                pass',
     'test_owner_profile_enables_the_unlock_plugin_and_the_others_take_it_out_again'),
    ('the unlock plugin left in the operator\'s deny list', 'set-toolsets.py',
     '                kept = [n for n in denied if n != UNLOCK_PLUGIN]', '                kept = list(denied)',
     'test_owner_profile_enables_the_unlock_plugin_and_the_others_take_it_out_again'),
    ('the operator\'s own listing of the plugin taken out', 'set-toolsets.py',
     'elif profile is not None and config.get(UNLOCK_MARKER) is True:', 'elif profile is not None:',
     'test_owner_profile_enables_the_unlock_plugin_and_the_others_take_it_out_again'),
    ('max_turns ignored', 'set-toolsets.py',
     '            config["agent"]["max_turns"] = int(turns)', '            pass',
     'test_max_turns_comes_from_uci'),
    ('max_turns not handed to procd', 'hermes-agent.init',
     '\t\tHERMES_OPENWRT_MAX_TURNS="$max_turns" \\\n\t\tHERMES_OPENWRT_PROVIDERS="${providers#;}"\n',
     '\t\tHERMES_OPENWRT_PROVIDERS="${providers#;}"\n',
     'test_max_turns_comes_from_uci'),
    ('gateway at the router\'s own priority', 'hermes-agent.init', 'procd_set_param nice 10',
     'true', 'test_gateway_runs_below_the_routers_own_work'),
    ('an empty restriction refused', 'set-toolsets.py', '            if disabled is None:\n                disabled = []\n',
     '', 'test_assistant_profile_reads_an_empty_restriction_as_empty'),
    ('wrapper stops passing the profile', 'hermes-gateway',
     '"$OPENAI_BASE_URL" "$HERMES_MODEL" "$profile"', '"$OPENAI_BASE_URL" "$HERMES_MODEL"',
     'test_wrapper_reapplies_profile_at_exec'),
    # ---- further providers ----
    ('providers not written', 'set-toolsets.py',
     '                providers[name] = entry', '                pass',
     'test_extra_providers_reach_upstream'),
    ('a name upstream owns accepted', 'set-toolsets.py',
     '        if _builtin_provider(name):', '        if False:',
     'test_provider_names_upstream_owns_are_refused'),
    ("an operator's same-named entry overwritten", 'set-toolsets.py',
     '                if name in providers and not ours(providers[name]) and providers[name] != entry:',
     '                if False:',
     'test_operator_provider_entries_survive'),
    ('a provider dropped from UCI kept', 'set-toolsets.py',
     '                if ours(providers[name]) and name not in wanted:', '                if False:',
     'test_operator_provider_entries_survive'),
    ('provider keys not exported', 'hermes-gateway',
     '\t\t\texport "HERMES_PROVIDER_$(printf \'%s\' "$p_name" | tr \'a-z-\' \'A-Z_\')_KEY=$value"',
     '\t\t\ttrue',
     'test_wrapper_exports_provider_keys_and_drops_missing_ones'),
    ('a provider kept without its key', 'hermes-gateway',
     '\t\tif value=$(read_required "$p_key_file" "provider $p_name key file" 2>/dev/null); then',
     '\t\tif value=$(read_required "$p_key_file" "provider $p_name key file" 2>/dev/null) || true; then',
     'test_wrapper_exports_provider_keys_and_drops_missing_ones'),
    ('stale provider keys inherited', 'hermes-gateway', '\tunset "$stale"', '\ttrue',
     'test_wrapper_exports_provider_keys_and_drops_missing_ones'),
    ('provider key files not handed to procd', 'hermes-agent.init',
     '\t\tHERMES_OPENWRT_PROVIDERS="${providers#;}"\n', '\t\tHERMES_OPENWRT_PROVIDERS=""\n',
     'test_provider_keys_absent_from_procd'),
    ('a bad provider section before the last ignored', 'hermes-agent.init',
     '\t[ -z "$providers_bad" ] || return 1', '\ttrue',
     'test_bad_provider_section_refuses_the_start'),
    ('provider keys unguarded by the preflight', 'runtime-check.py',
     'if name.startswith("HERMES_PROVIDER_") and name.endswith("_KEY")', 'if False',
     'test_preflight_protects_provider_keys'),
    ('openai-api offered in /model', 'set-toolsets.py',
     '                catalog["excluded_providers"] = list(excluded) + ["openai-api"]', '                pass',
     'test_openai_api_is_hidden_from_the_picker'),
    ("the login helper ignores the service's data directory", 'hermes-login',
     "config_get data_dir main data_dir '/srv/hermes'", 'data_dir=/srv/hermes',
     'test_login_helper_uses_the_service_home'),
    ('sign-out does nothing', 'hermes-login',
     "from types import SimpleNamespace; from hermes_cli.auth import logout_command; logout_command(SimpleNamespace(provider=\"openai-codex\"))",
     'pass',
     'test_login_helper_signs_out'),
    ('the preflight checks the subscription instead of the main key', 'runtime-check.py',
     '        for runtime in (resolve_runtime_provider(), ',
     '        for runtime in (resolve_runtime_provider(requested="openai-codex"), ',
     'test_chatgpt_login_does_not_trip_the_preflight'),
    # Not provider="custom" alone: with the uci entry still written, the picker ticks that
    # entry (same address) and the fix holds, so that mutant is equivalent. The entry is
    # what carries the key.
    ('the main model written without its uci entry', 'set-toolsets.py',
     '            config["providers"] = dict(providers, **{MAIN_PROVIDER: main_entry})',
     '            config["providers"] = providers',
     'test_model_switch_keeps_the_main_key'),
    ('the preflight checks the uci route only', 'runtime-check.py',
     '        for runtime in (resolve_runtime_provider(), resolve_runtime_provider(requested="custom")):',
     '        for runtime in (resolve_runtime_provider(),):',
     'test_runtime_override_conflicts_are_refused'),
    ("an operator's uci entry taken for the main model's", 'set-toolsets.py',
     '    return isinstance(entry, dict) and entry.get("key_env") == "OPENAI_API_KEY"',
     '    return True',
     'test_operator_provider_entries_survive'),
    # ---- the owner profile: no root, and the router only through openwrt-mcp ----
    ('the gateway runs as root', 'hermes-gateway',
     'exec $DROP "$run_user" /usr/bin/hermes gateway run --external-supervisor',
     'exec /usr/bin/hermes gateway run --external-supervisor',
     'test_wrapper_reapplies_profile_at_exec'),
    ('the root profile does not tell the launcher', 'hermes-gateway',
     '[ "$run_user" != root ] || export HERMES_OPENWRT_AS_ROOT=1', ': # not exported',
     'test_wrapper_reapplies_profile_at_exec'),
    ('the wrapper runs the bridge as root', 'hermes-gateway',
     '$DROP "$run_user" /usr/bin/python3 /usr/libexec/hermes-set-toolsets',
     '/usr/bin/python3 /usr/libexec/hermes-set-toolsets',
     'test_wrapper_runs_everything_after_the_credentials_as_the_agents_user'),
    ('the wrapper runs the preflight as root', 'hermes-gateway',
     '$DROP "$run_user" /usr/bin/python3 /usr/libexec/hermes-runtime-check',
     '/usr/bin/python3 /usr/libexec/hermes-runtime-check',
     'test_wrapper_runs_everything_after_the_credentials_as_the_agents_user'),
    ('admin is not an alias of root', 'hermes-profile', "\t\tadmin) printf 'root\\n' ;;", '\t\tadmin) return 1 ;;',
     'test_profile_defaults_to_owner_and_refuses_unknown'),
    ('owner leaves the governed tools disabled', 'set-toolsets.py',
     '        elif profile in ("owner", "root", "admin"):', '        elif profile in ("root", "admin"):',
     'test_owner_profile_keeps_tools_and_its_note_follows_the_factor'),
    ("owner's note ignores the factor", 'set-toolsets.py',
     '        text = OWNER_NOTE + (OWNER_NOTE_NO_FACTOR if factor == "none" else OWNER_NOTE_LOCKED)',
     '        text = OWNER_NOTE + OWNER_NOTE_LOCKED',
     'test_owner_profile_keeps_tools_and_its_note_follows_the_factor'),
    ('a factor that is none of them accepted', 'set-toolsets.py',
     '            if factor not in FACTORS:', '            if False:',
     'test_owner_profile_keeps_tools_and_its_note_follows_the_factor'),
    ('the unlock tools offered to the model', 'set-toolsets.py',
     '                expected = {"url": url, "headers": headers, "tools": {"exclude": list(MCP_HIDDEN)}}',
     '                expected = {"url": url, "headers": headers}',
     'test_mcp_entry_hides_the_unlock_tools_and_adopts_the_earlier_shape'),
    ('the earlier entry of the package refused', 'set-toolsets.py',
     'servers["openwrt"] not in (expected, earlier)', 'servers["openwrt"] != expected',
     'test_mcp_entry_hides_the_unlock_tools_and_adopts_the_earlier_shape'),
    # ---- 0.21.5-r10: what a person-level run on three routers found on 2026-10-08 ----
    ('exec and wg_new_client offered to the model', 'set-toolsets.py',
     'MCP_HIDDEN = ("mfa_unlock", "mfa_lock", "exec", "wg_new_client")', 'MCP_HIDDEN = ("mfa_unlock", "mfa_lock")',
     'test_mcp_entry_hides_exec_and_wg_new_client_in_every_profile'),
    ("the r9 entry of the package refused", 'set-toolsets.py',
     'and servers["openwrt"] != earlier_r9):', 'and True):',
     'test_mcp_entry_hides_the_unlock_tools_and_adopts_the_earlier_shape'),
    ('tool search left to defer the MCP tools', 'set-toolsets.py',
     '                tools_cfg["tool_search"] = dict(search, enabled=TOOL_SEARCH_OFF)', '                pass',
     'test_tool_search_is_off_unless_the_operator_set_it'),
    ("the operator's tool search overwritten", 'set-toolsets.py',
     '            if isinstance(search, dict) and search.get("enabled") is None:',
     '            if isinstance(search, dict):',
     'test_tool_search_is_off_unless_the_operator_set_it'),
    ('the owner note without UCI names, port forwards and the read-back', 'set-toolsets.py',
     '              "A UCI section name holds only letters, digits and underscores; put a readable "\n'
     '              "name in the section\'s `name` option. A port forward is a firewall section of "\n'
     '              "type redirect (DNAT), not a rule. After a change, read it back with uci_get and "\n'
     '              "tell the owner only what the router actually holds. What you may read and change "',
     '              "What you may read and change "',
     'test_owner_note_teaches_section_names_port_forwards_and_reading_back'),
    ('the owner note without the rule against widening its own access', 'set-toolsets.py',
     '              "is the owner\'s decision, made on purpose: never ask the owner to widen it, to run "\n'
     '              "openwrt-mcp allow, or to grant you access any other way. When something is out "\n'
     '              "of your reach, say so and what the owner could do by hand instead. ")',
     '              "is the owner\'s decision. ")',
     'test_owner_note_teaches_section_names_port_forwards_and_reading_back'),
    ('the owner note without the terminal for diagnostics', 'set-toolsets.py',
     '"ip, ifconfig) use your own terminal: they work there as your user. "',
     '"ip, ifconfig) are not for you. "',
     'test_owner_note_teaches_section_names_port_forwards_and_reading_back'),
    ('a config written as root stays root', 'set-toolsets.py',
     '                    os.fchown(stream.fileno(), owner.st_uid, owner.st_gid)', '                    pass',
     'test_config_written_by_root_takes_the_data_dir_owner'),
    ('the drop keeps the supplementary groups', 'hermes-drop', '        os.setgroups([])', '        pass',
     'test_hermes_drop_gives_up_root_and_refuses_what_it_cannot_do'),
    ('the drop changes the effective user only', 'hermes-drop',
     '        os.setresuid(entry.pw_uid, entry.pw_uid, entry.pw_uid)', '        os.seteuid(entry.pw_uid)',
     'test_hermes_drop_gives_up_root_and_refuses_what_it_cannot_do'),
    ('a drop to uid 0 accepted', 'hermes-drop', '    if entry.pw_uid == 0:', '    if False:',
     'test_hermes_drop_gives_up_root_and_refuses_what_it_cannot_do'),
    ('an unenterable directory kept', 'hermes-drop',
     '        if not os.access(".", os.X_OK) or not os.access(".", os.R_OK):', '        if False:',
     'test_hermes_drop_gives_up_root_and_refuses_what_it_cannot_do'),
    ('HOME from the password file only', 'hermes-drop',
     '        os.environ["HOME"] = home if home and os.path.isdir(home) else entry.pw_dir',
     '        os.environ["HOME"] = entry.pw_dir',
     'test_hermes_drop_gives_up_root_and_refuses_what_it_cannot_do'),
    ('the launcher keeps root', 'hermes-launcher',
     '\t\texec /usr/bin/python3 -I -B /usr/libexec/hermes-drop hermes /usr/bin/python3 "$SITE/hermes_cli/main.py" "$@"',
     '\t\ttrue',
     'test_launcher_runs_as_the_user_who_owns_the_data_directory'),
    ('the launcher ignores the opt-out', 'hermes-launcher',
     '[ -z "${HERMES_OPENWRT_AS_ROOT:-}" ]', 'true',
     'test_launcher_runs_as_the_user_who_owns_the_data_directory'),
    ('the launcher drops whoever owns the directory', 'hermes-launcher',
     '= "$(id -u hermes 2>/dev/null)" ]; then\n\t\tPYTHONPATH', '!= "$(id -u hermes 2>/dev/null)" ]; then\n\t\tPYTHONPATH',
     'test_launcher_runs_as_the_user_who_owns_the_data_directory'),
    ('the sign-in runs as root', 'hermes-login',
     '\t\t/usr/bin/python3 -I -B /usr/libexec/hermes-drop hermes "$@"', '\t\t"$@"',
     'test_login_helper_signs_out'),
    ('the read grants include a whole object', 'hermes-agent.init',
     "MCP_READ_UBUS='system.board system.info ", "MCP_READ_UBUS='system.* ",
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('wireless readable', 'hermes-agent.init',
     "MCP_READ_UCI='system system.* ", "MCP_READ_UCI='wireless wireless.* system system.* ",
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('the whole network config readable', 'hermes-agent.init',
     "network.loopback* network.globals*", "network network.* network.loopback* network.globals*",
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('wireless read whatever openwrt-mcp says', 'hermes-agent.init',
     '\tif [ "$cap" != true ]; then', '\tif false; then',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('wireless never read, even from a daemon that redacts', 'hermes-agent.init',
     '\techo "$MCP_READ_UCI_WIDE"', '\techo "$MCP_READ_UCI"',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('the change policies ask for no factor', 'hermes-agent.init',
     '\t\tprintf "add_list openwrt-mcp.%s%s.mfa_tools=\'*\'\\n" "$prefix" "$sect"\n',
     '\t\t:\n',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('ubus_call on everything in an open window', 'hermes-agent.init',
     "MCP_CHANGE_UBUS='network.reload ", "MCP_CHANGE_UBUS='* network.reload ",
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('rpcd file object in an open window', 'hermes-agent.init',
     "MCP_CHANGE_UBUS='network.reload ", "MCP_CHANGE_UBUS='file.* network.reload ",
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('a change policy with no factor configured', 'hermes-agent.init',
     '\t[ "$factor" = none ] && return 0\n', '\ttrue\n',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('the policies rewritten on every start', 'hermes-agent.init',
     '\tif [ "$want" != "$have" ]; then', '\tif true; then',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('the policies never rewritten', 'hermes-agent.init',
     '\tif [ "$want" != "$have" ]; then', '\tif false; then',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('an old policy section kept', 'hermes-agent.init',
     '\t\t\tuci -q delete "openwrt-mcp.$sect"', '\t\t\ttrue',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('the token paired on every start', 'hermes-agent.init',
     '\tif [ -z "$(read_secret "$token_file")" ]; then', '\tif true; then',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('the token left readable', 'hermes-agent.init',
     '\t\tchmod 0600 "$tmp" && mv "$tmp" "$token_file" || return 1',
     '\t\tchmod 0644 "$tmp" && mv "$tmp" "$token_file" || return 1',
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('an agent name that is no section name accepted', 'hermes-agent.init',
     "\tcase \"$agent\" in ''|*[!a-z0-9]*) echo", "\tcase \"$agent\" in ZZZ) echo",
     'test_owner_policies_are_ordered_idempotent_and_leave_other_sections_alone'),
    ('any factor accepted', 'hermes-agent.init',
     '\t\t\tnone|pin|totp|pin+totp) ;;', '\t\t\t*) ;;',
     'test_security_options_refuse_bad_values'),
    ('durations unchecked', 'hermes-agent.init',
     '\t\tfor v in "$sec_window" "$sec_lockout"; do', '\t\tfor v in; do',
     'test_security_options_refuse_bad_values'),
    ('the failure limit unchecked', 'hermes-agent.init',
     '\t\tcase "$sec_max" in \'\'|*[!0-9]*|0)', '\t\tcase "$sec_max" in ZZZ)',
     'test_security_options_refuse_bad_values'),
    ('the data directory never handed over', 'hermes-agent.init',
     '\t\tchown -hR "$uid:$gid" "$dir" || {', '\t\ttrue || {',
     'test_start_refuses_a_data_dir_it_cannot_give_to_the_agent'),
    ('a data directory the agent cannot write accepted', 'hermes-agent.init',
     '\tif [ "$user" != root ] && ! $DROP "$user" /bin/sh -c', '\tif false && ! $DROP "$user" /bin/sh -c',
     'test_start_refuses_a_data_dir_it_cannot_give_to_the_agent'),
    ('the bridge in the init runs as root', 'hermes-agent.init',
     'PYTHONDONTWRITEBYTECODE=1 $DROP "$run_user" /usr/bin/python3 /usr/libexec/hermes-set-toolsets',
     'PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 /usr/libexec/hermes-set-toolsets',
     'test_init_runs_the_bridge_as_the_agents_user'),
]
installed = {'set-toolsets.py': Path('/usr/libexec/hermes-set-toolsets'),
             'memory-limit.py': Path('/usr/libexec/hermes-memory'),
             'runtime-check.py': Path('/usr/libexec/hermes-runtime-check'),
             'hermes-drop': Path('/usr/libexec/hermes-drop'),
             'hermes-launcher': Path('/usr/bin/hermes'),
             'hermes-profile': Path('/usr/lib/hermes-agent/hermes-profile')}
# TEETH_ONLY="part of a title,another" runs just those mutants, for iterating on new ones; the
# empty-discovery refusal and the restored-green run below still happen.
only = [part for part in os.environ.get('TEETH_ONLY', '').split(',') if part]
for title, filename, before, after, test in mutants:
    if only and not any(part in title for part in only):
        continue
    path = PRODUCT / filename
    original = path.read_text()
    if original.count(before) != 1:
        sys.exit('measured nothing: mutation target missing or ambiguous: ' + title)
    counterpart = installed.get(filename)
    original_installed = counterpart.read_text() if counterpart else None
    try:
        path.write_text(original.replace(before, after))
        if counterpart:
            counterpart.write_text(path.read_text())
        result = run(test)
        if result.returncode == 0 or 'FAILED (' not in result.stderr:
            sys.exit('TEETH FAIL: ' + title + '\n' + result.stdout + result.stderr)
        print('teeth ok: ' + title + ' -> ' + test, flush=True)
    finally:
        path.write_text(original)
        if counterpart:
            counterpart.write_text(original_installed)

# Discovering no tests must fail, not report an empty green suite.
with tempfile.TemporaryDirectory() as tmp:
    scripts = Path(tmp) / 'scripts'
    scripts.mkdir()
    shutil.copyfile(ROOT / 'scripts/gate-runtime.sh', scripts / 'gate-runtime.sh')
    (scripts / 'test-runtime.py').write_text('# no subjects\n')
    empty = subprocess.run(['sh', str(scripts / 'gate-runtime.sh'), '--selftest'],
                           check=False, capture_output=True, text=True)
    if empty.returncode == 0 or 'measured nothing' not in empty.stderr:
        sys.exit('TEETH FAIL: no subjects was not reported')
print('teeth ok: missing subjects -> measured nothing', flush=True)
restored = run()
sys.stdout.write(restored.stdout)
sys.stderr.write(restored.stderr)
if restored.returncode:
    sys.exit('TEETH FAIL: restored product is not green')
print(f'teeth: {len(mutants) if not only else "selected"} product mutations caught; empty discovery refused; green restored')
