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
     'PYTHONPATH=/usr/lib/hermes-agent/site-packages PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 '
     '/usr/libexec/hermes-set-toolsets "$HERMES_HOME" "$HERMES_OPENWRT_TOOLSETS" "$mcp_effective" '
     '"$OPENAI_BASE_URL" "$HERMES_MODEL"',
     ': # bridge skipped', 'test_wrapper_reapplies_uci_after_model_switch'),
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
    ('init default flips to assistant', 'hermes-agent.init',
     "config_get profile        main profile 'admin'",
     "config_get profile        main profile 'assistant'",
     'test_profile_defaults_to_admin_and_refuses_unknown'),
    ('wrapper default flips to assistant', 'hermes-gateway',
     '"${HERMES_OPENWRT_PROFILE:-admin}"', '"${HERMES_OPENWRT_PROFILE:-assistant}"',
     'test_wrapper_reapplies_profile_at_exec'),
    ('profile note not written', 'set-toolsets.py',
     '                    agent_cfg["system_prompt"] = (own + NOTE_SEP + NOTE) if own else NOTE',
     '                    pass',
     'test_assistant_profile_tells_the_agent_what_it_cannot_do'),
    ("operator's prompt replaced by the note", 'set-toolsets.py',
     '(own + NOTE_SEP + NOTE) if own else NOTE', 'NOTE',
     'test_assistant_profile_tells_the_agent_what_it_cannot_do'),
    ("operator's prompt trimmed on the way back", 'set-toolsets.py',
     '    return before + after', '    return (before + after).strip()',
     'test_assistant_profile_tells_the_agent_what_it_cannot_do'),
    ('max_turns ignored', 'set-toolsets.py',
     '            config["agent"]["max_turns"] = int(turns)', '            pass',
     'test_max_turns_comes_from_uci'),
    ('max_turns not handed to procd', 'hermes-agent.init',
     '\t\tHERMES_OPENWRT_PROFILE="$profile" \\\n\t\tHERMES_OPENWRT_MAX_TURNS="$max_turns"',
     '\t\tHERMES_OPENWRT_PROFILE="$profile"',
     'test_max_turns_comes_from_uci'),
    ('gateway at the router\'s own priority', 'hermes-agent.init', 'procd_set_param nice 10',
     'true', 'test_gateway_runs_below_the_routers_own_work'),
    ('an empty restriction refused', 'set-toolsets.py', '            if disabled is None:\n                disabled = []\n',
     '', 'test_assistant_profile_reads_an_empty_restriction_as_empty'),
    ('wrapper stops passing the profile', 'hermes-gateway',
     'PYTHONPATH=/usr/lib/hermes-agent/site-packages PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 '
     '/usr/libexec/hermes-set-toolsets "$HERMES_HOME" "$HERMES_OPENWRT_TOOLSETS" "$mcp_effective" '
     '"$OPENAI_BASE_URL" "$HERMES_MODEL" "${HERMES_OPENWRT_PROFILE:-admin}"',
     'PYTHONPATH=/usr/lib/hermes-agent/site-packages PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 '
     '/usr/libexec/hermes-set-toolsets "$HERMES_HOME" "$HERMES_OPENWRT_TOOLSETS" "$mcp_effective" '
     '"$OPENAI_BASE_URL" "$HERMES_MODEL"',
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
    ('the preflight checks the subscription instead of the main key', 'runtime-check.py',
     '        runtime = resolve_runtime_provider()', '        runtime = resolve_runtime_provider(requested="openai-codex")',
     'test_chatgpt_login_does_not_trip_the_preflight'),
]
installed = {'set-toolsets.py': Path('/usr/libexec/hermes-set-toolsets'),
             'memory-limit.py': Path('/usr/libexec/hermes-memory'),
             'runtime-check.py': Path('/usr/libexec/hermes-runtime-check')}
for title, filename, before, after, test in mutants:
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
print(f'teeth: {len(mutants)} product mutations caught; empty discovery refused; green restored')
