#!/usr/bin/env python3
"""Prove gate-network.sh can fail, and fail at the right check. Runs inside the gate's container.

@claude 2026-11-07. Each mutant is a change a real edit could make to a disposable copy of the
product, and each must turn its one named test red. The first four are the faults this design exists
to refuse: the negative skuid form, a rule in a fw4 chain, a `fw4 zone` call in the include and an
allow read from config.yaml. Around them, as in every gate here: the same checks stay green on a
near miss (a word in a comment, a positive match, a refusal where it belongs), discovery of no
tests and a product with no hermes-net both say "measured nothing", and green comes back at the end.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = Path(os.environ["PRODUCT_FILES"])
NET = "hermes-net.py"
REAPPLY = "hermes-net-reapply"
HOTPLUG = "hermes-net.hotplug"


def run(test=None, product=None):
    command = [sys.executable, str(ROOT / "scripts/test-network.py")]
    if test:
        command += ["NetworkTests." + test]
    env = dict(os.environ, PRODUCT_FILES=str(product or PRODUCT))
    return subprocess.run(command, check=False, capture_output=True, text=True, env=env)


# title, file, before, after, the test that must go red
mutants = [
    ("the negative skuid form", NET,
     'f"\\t\\tmeta skuid {plan[\'uid\']} jump agent"',
     'f"\\t\\tmeta skuid != {plan[\'uid\']} return", "\\t\\tjump agent"',
     "test_packets_with_no_socket_still_leave"),
    ("a rule in a fw4 chain", NET,
     'return "\\n".join(lines + ["\\t}", "}", ""])',
     'return "\\n".join(lines + ["\\t}", "}", "add rule inet fw4 output meta skuid " + str(plan["uid"]) + " counter", ""])',
     "test_rules_stay_out_of_fw4"),
    ("a fw4 zone call in the include", REAPPLY,
     "[ ! -r /var/run/hermes-agent/net.nft ]", "fw4 zone lan >/dev/null\n[ ! -r /var/run/hermes-agent/net.nft ]",
     "test_include_never_calls_fw4"),
    ("an allow read from config.yaml", NET,
     '    answers = resolve({host for _, host, _, _ in wanted})',
     '    import glob\n'
     '    for path in glob.glob("/srv/hermes/config.yaml"):\n'
     '        found = re.search(r"https?://[^ \\n]+", open(path, encoding="utf-8").read())\n'
     '        if found:\n'
     '            endpoint("config.yaml", found.group(0))\n'
     '    answers = resolve({host for _, host, _, _ in wanted})',
     "test_allow_list_ignores_the_agents_own_files"),
    ("the router's own addresses not refused", NET,
     '    lines += refuse("fib daddr type local")\n', '',
     "test_agent_cannot_reach_router_ports"),
    ("what UCI names can open SSH on the router", NET,
     '    lines += refuse("fib daddr type local tcp dport @router_ports")\n', '',
     "test_router_ports_stay_closed_whatever_uci_names"),
    ("the router's settings for SSH and LuCI not read", NET,
     '"router": router_service_ports(),', '"router": list(ROUTER_PORTS),',
     "test_router_ports_stay_closed_whatever_uci_names"),
    ("the devices of the house not refused", NET,
     '    lines += refuse("oifname @house_if")\n', '',
     "test_agent_cannot_reach_other_lan_hosts"),
    ("IPv4 private ranges not refused", NET,
     '    lines += refuse("ip daddr @deny4")\n', '',
     "test_private_ranges_and_the_tailnet_are_closed"),
    ("IPv6 private ranges not refused", NET,
     '    lines += refuse("ip6 daddr @deny6")\n', '',
     "test_private_ranges_and_the_tailnet_are_closed"),
    ("the tailnet's range forgotten", NET, '"100.64.0.0/10", ', '',
     "test_private_ranges_and_the_tailnet_are_closed"),
    ("the ULA range forgotten", NET, '"fc00::/7", ', '',
     "test_private_ranges_and_the_tailnet_are_closed"),
    ("the wrong side of the router counted as the house", NET,
     '(outside_devices if name in outside else inside_devices).update(names)',
     'inside_devices.update(names)',
     "test_public_internet_stays_reachable"),
    ("a second network of the house missed", NET,
     'found.append(device)', 'found.append(device) if device == "br-lan" else None',
     "test_zones_decide_what_counts_as_the_house"),
    ("an endpoint in UCI not allowed", NET,
     '            allow.update((address, proto, port) for proto in protocols)', '            pass',
     "test_lan_endpoint_from_uci_works_without_a_step"),
    ("IPv6 allow rule missing", NET,
     '"\\t\\tip6 daddr . meta l4proto . th dport @allow6 accept"', '"\\t\\tcounter"',
     "test_lan_endpoint_from_uci_works_without_a_step"),
    ("a provider's endpoint not read", NET,
     'if section.get(".type") == "provider" and', 'if False and',
     "test_lan_endpoint_from_uci_works_without_a_step"),
    ("a switched-off provider's endpoint opened", NET,
     ' and is_on(section, "enabled", "1") and first(section, "base_url")', ' and first(section, "base_url")',
     "test_lan_endpoint_from_uci_works_without_a_step"),
    ("openwrt-mcp's port not opened", NET,
     '            local.add(("tcp", parsed[1]))', '            pass',
     "test_mcp_and_gateway_stay_reachable"),
    ("llm-gateway's port not opened", NET,
     '            local.add(("tcp", int(port)))', '            pass',
     "test_mcp_and_gateway_stay_reachable"),
    ("llm-gateway's port always opened", NET, '    if gateway:\n', '    if True:\n',
     "test_mcp_and_gateway_stay_reachable"),
    ("the router's resolver closed", NET, 'local = {("tcp", 53), ("udp", 53)}', 'local = set()',
     "test_dns_reaches_the_resolver"),
    ("a resolver on the LAN not read", NET,
     'allow = {(address, proto, 53) for address in resolvers() for proto in ("tcp", "udp")}', 'allow = set()',
     "test_dns_reaches_the_resolver"),
    ("off leaves the table", NET, '        result = run(["nft", "delete", "table", "inet", TABLE])',
     '        result = run(["true"])', "test_open_turns_the_limits_off"),
    ("off leaves the file for the firewall to load", NET, 'for path in (RULES, RULES + ".new"):', 'for path in ():',
     "test_open_turns_the_limits_off"),
    ("lan_allow not read", NET, 'security.get("lan_allow", ())', '()', "test_lan_allow_adds_a_host"),
    ("lan_allow opens TCP only", NET, 'wanted.append(("hermes.security.lan_allow", parsed[0], parsed[1], ("tcp", "udp")))',
     'wanted.append(("hermes.security.lan_allow", parsed[0], parsed[1], ("tcp",)))', "test_lan_allow_adds_a_host"),
    ("no include section", NET, '    ensure_include()\n    return 0', '    return 0',
     "test_firewall_stop_start_restores_it"),
    ("the include loads nothing", REAPPLY, 'nft -f /var/run/hermes-agent/net.nft', 'true',
     "test_firewall_stop_start_restores_it"),
    ("nft -c skipped", NET, 'result = run(["nft", "-c", "-f", path])', 'result = run(["true"])',
     "test_bad_rules_leave_the_firewall_alone"),
    ("no minimal rules", NET, '        if not load(uid, render(minimal_plan(uid, house))):',
     '        if True:', "test_bad_rules_leave_the_firewall_alone"),
    ("a refusal in the base chain", NET,
     '"\\t\\ttype filter hook output priority filter; policy accept;",',
     '"\\t\\ttype filter hook output priority filter; policy accept;", "\\t\\tmeta skuid 65533 drop",',
     "test_every_refusal_sits_in_chain_agent"),
    ("a base chain that drops by default", NET,
     'hook output priority filter; policy accept;', 'hook output priority filter; policy drop;',
     "test_packets_with_no_socket_still_leave"),
    ("the uid fixed in the program", NET, 'uid = pwd.getpwnam(USER).pw_uid\n', 'uid = 32768\n',
     "test_uid_is_read_at_apply_time"),
    ("the agent may serve the house", NET,
     "    lines += refuse('ct direction reply oif != \"lo\"')\n", '',
     "test_agent_is_no_server_for_the_house"),
    ("no drop counter", NET, 'REFUSE = \'counter name "dropped" reject', 'REFUSE = \'reject',
     "test_drop_counter_and_log_line"),
    ("no log line", NET, 'return [f"\\t\\t{match} {LOG}", f"\\t\\t{match} {REFUSE}"]', 'return [f"\\t\\t{match} {REFUSE}"]',
     "test_drop_counter_and_log_line"),
    ("a device name written as it stands", NET, '        if DEVICE.match(device):\n', '        if True:\n',
     "test_hostile_uci_values_write_no_rule"),
    ("a name nobody answers for holds the start up", NET, 'thread.join(max(0.0, deadline - time.monotonic()))', 'thread.join()',
     "test_a_name_that_does_not_resolve_is_named_and_left_out"),
    ("an unresolved name said nowhere", NET,
     'say(f"{label} names {host}, which does not resolve now, so it opens nothing until it does")', 'pass',
     "test_a_name_that_does_not_resolve_is_named_and_left_out"),
    ("the hotplug script applies nothing", HOTPLUG, '/usr/libexec/hermes-net apply', '/usr/libexec/hermes-net status',
     "test_interface_event_reapplies_the_rules"),
    ("the hotplug script starts the limits on its own", HOTPLUG,
     '[ -e /var/run/hermes-agent/net.nft ] || exit 0\n', '', "test_interface_event_reapplies_the_rules"),
    ("the hotplug script answers every event", HOTPLUG,
     'case "$ACTION" in ifup|ifupdate|add|update) ;; *) exit 0 ;; esac\n', '', "test_interface_event_reapplies_the_rules"),
    ("a lease brings nothing", HOTPLUG, 'ifup|ifupdate|add|update', 'ifup|ifupdate',
     "test_a_lease_gives_a_name_in_uci_its_address"),
    ("every start reloads the table", NET, '    if same and table_loaded():\n        return True\n', '',
     "test_a_start_that_changes_nothing_writes_nothing"),
    ("every start writes the firewall's file", NET,
     '    have = uci_show("firewall").get(INCLUDE, {})\n    if have.get(".type") == "include"',
     '    have = uci_show("firewall").get(INCLUDE, {})\n    if False and have.get(".type") == "include"',
     "test_a_start_that_changes_nothing_writes_nothing"),
    ("the include written over someone's staged changes", NET,
     'copy = "hermes_net_firewall"', 'copy = "firewall"',
     "test_include_section_leaves_staged_changes_alone"),
]

only = [part for part in os.environ.get("TEETH_ONLY", "").split(",") if part]
for title, filename, before, after, test in mutants:
    if only and not any(part in title for part in only):
        continue
    path = PRODUCT / filename
    original = path.read_text()
    if original.count(before) != 1:
        sys.exit("measured nothing: mutation target missing or ambiguous: " + title)
    try:
        path.write_text(original.replace(before, after))
        result = run(test)
        if result.returncode == 0 or "FAILED (" not in result.stderr:
            sys.exit("TEETH FAIL: " + title + "\n" + result.stdout + result.stderr)
        print("teeth ok: " + title + " -> " + test, flush=True)
    finally:
        path.write_text(original)

# A near miss must not fire: the same words where they do no harm. A comment that names fw4 in the
# include, a word in a comment of the program, a refusal where it belongs (the control run above
# already has those, and a comment is the one thing it does not have).
controls = [
    ("the include's comment says fw4 zone", REAPPLY, "# fw4 runs this", "# fw4 zone runs this, says nobody\n# fw4 runs this",
     "test_include_never_calls_fw4"),
    ("a comment in the program names config.yaml", NET, "def house_devices():\n",
     "# config.yaml is the agent's, and never read here.\ndef house_devices():\n",
     "test_allow_list_ignores_the_agents_own_files"),
]
for title, filename, before, after, test in controls:
    if only and not any(part in title for part in only):
        continue
    path = PRODUCT / filename
    original = path.read_text()
    if original.count(before) < 1:
        sys.exit("measured nothing: control target missing: " + title)
    try:
        path.write_text(original.replace(before, after, 1))
        result = run(test)
        if result.returncode != 0:
            sys.exit("TEETH FAIL: fired on a non-fault: " + title + "\n" + result.stdout + result.stderr)
        print("teeth ok: no fault, no red: " + title, flush=True)
    finally:
        path.write_text(original)

# The subject gone: a product with no hermes-net, and a test file with no tests.
with tempfile.TemporaryDirectory() as tmp:
    gone = Path(tmp) / "product"
    shutil.copytree(PRODUCT, gone)
    (gone / NET).unlink()
    result = run(product=gone)
    if result.returncode == 0 or "measured nothing" not in result.stdout + result.stderr:
        sys.exit("TEETH FAIL: a product with no hermes-net was not reported as measuring nothing\n" + result.stdout + result.stderr)
    scripts = Path(tmp) / "scripts"
    scripts.mkdir()
    shutil.copyfile(ROOT / "scripts/gate-network.sh", scripts / "gate-network.sh")
    (scripts / "test-network.py").write_text("# no subjects\n")
    empty = subprocess.run(["sh", str(scripts / "gate-network.sh"), "--selftest"],
                           check=False, capture_output=True, text=True)
    if empty.returncode == 0 or "measured nothing" not in empty.stderr:
        sys.exit("TEETH FAIL: no subjects was not reported")
print("teeth ok: missing subjects -> measured nothing", flush=True)

restored = run()
sys.stdout.write(restored.stdout)
sys.stderr.write(restored.stderr)
if restored.returncode:
    sys.exit("TEETH FAIL: restored product is not green")
print(f'teeth: {len(mutants) if not only else "selected"} faults caught; no red on a non-fault; missing subject refused; green restored')
