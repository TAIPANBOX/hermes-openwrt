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
    ('UCI model ignored', 'set-toolsets.py', '        if len(sys.argv) == 6:',
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
