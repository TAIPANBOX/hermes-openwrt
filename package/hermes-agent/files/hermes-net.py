#!/usr/bin/env python3
"""hermes-net: what the agent's own connections may reach. Runs as root, before the gateway starts.

@decided 2026-11-07: the agent keeps the internet, its model, DNS and openwrt-mcp, and does not reach
SSH, LuCI or ubus on any address of the router, other services of the router, other hosts of the
house over IPv4 or IPv6, or the tailnet. It costs the owner no step: `hermes.security.agent_network`
set to open turns it off, and `list lan_allow 'host:port'` adds a host. The root profile runs
outside it by definition, and the init says so. `hermes-net apply` is the whole of it:

    /usr/libexec/hermes-net apply    write the rules, check them, load them
    /usr/libexec/hermes-net off      delete the table and the file
    /usr/libexec/hermes-net remove   that and the firewall's include, when the package leaves
    /usr/libexec/hermes-net status   one line: in force or not, the uid, what was refused

@claude 2026-11-07, why it is shaped this way. Every point below is a way this goes silently wrong.

A table of its own, `inet hermes_agent`, with a base chain of its own at the output hook, and never
a rule of fw4's: fw4's output chain opens with `oif "lo" accept` (ruleset.uc), so a rule there
cannot see traffic to the router itself, which goes through lo, and that traffic is the point. An
accept in one base chain does not undo a refusal in another. A file under /etc/nftables.d would be
compiled into fw4's own ruleset, so a defect here would take the router's firewall down at boot.

Loaded by nft on its own, after `nft -c`, so what can fail is this table and nothing else.

A positive match, `meta skuid <uid> jump agent`, and every refusal inside chain agent. The kernel
answers meta skuid only for a packet with a full socket, and a rule whose match cannot be evaluated
does not match: `meta skuid != N return` would send every reset and ICMP error the router makes to
whatever comes next. Nothing but the agent's own sockets ever enters chain agent.

Refused with `reject`, not `drop`. @measured 2026-11-07 in openwrt/rootfs:x86-64-25.12.5 and on a
vlab node (25.12.5, kernel 6.12.94), a socket of an unprivileged user and a rule in a base chain at
the output hook: a TCP connect under `drop` was still waiting after 6 s (the kernel retries a SYN it
was not allowed to send, for about two minutes by default), and under `reject with icmpx
admin-prohibited` failed with EHOSTUNREACH at once over IPv4 and EACCES after a second over IPv6;
UDP answered EPERM either way. An agent waiting two minutes per call on a dead endpoint is not
diagnosable. Nothing leaves the router: the answer goes to the local socket.

The uid is read here, each time, because `group_add_next` gives whichever id is free.

Allow rules come from UCI only. This program never opens the agent's data directory: config.yaml
and .env are the agent's to write, so an address read from them would be the agent allowing itself
a host. UCI's hermes config is out of the agent's reach (openwrt-mcp refuses it, invariant 18).

What UCI names cannot open the router's own doors: chain agent refuses SSH and LuCI on every address
of the router before it looks at any allow rule, by the kernel's own view of what is local, so a
name that resolves to the router, an agent's window spent on dnsmasq included, opens nothing there.

The firewall's include runs /usr/libexec/hermes-net-reapply, which only loads the file this program
wrote: fw4 holds its lock while includes run, so a `fw4 zone` there would wait on it until fw4 gives
up on the script. That is why zones are read here from UCI and devices from ubus, and not from fw4.

Nothing here can be held up for long: a name nobody answers for costs RESOLVE_SECONDS, every command
has a timeout, and ALL_SECONDS ends the program, because OpenWrt ships no `timeout` command for the
hotplug script to use (@measured 2026-11-07, 25.12.5).
"""
import fcntl
import ipaddress
import json
import os
import pwd
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit

USER = "hermes"
TABLE = "hermes_agent"
RUN_DIR = "/var/run/hermes-agent"
RULES = RUN_DIR + "/net.nft"
LOCK = RUN_DIR + "/net.lock"
REAPPLY = "/usr/libexec/hermes-net-reapply"
INCLUDE = "hermes_net"
FIREWALL_FILE = "/etc/config/firewall"
RESOLV_FILES = ("/etc/resolv.conf", "/tmp/resolv.conf")

MCP_URL_DEFAULT = "http://127.0.0.1:8730/mcp"
GATEWAY_PORT_DEFAULT = "8761"
# SSH, and uhttpd, which serves LuCI and /ubus; the ports the router's own settings give them are
# added to these. Closed on every address of the router, whatever UCI names.
ROUTER_PORTS = (22, 80, 443)
# What a public address is not. Everything in here is refused unless UCI names it. 0.0.0.0/8 and ::
# reach the router itself on Linux, and fib sees those as local first; the rest matter when the
# address does not sit behind an interface of the house, as a modem's on the WAN side does not.
DENY4 = ("0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
         "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/3")
DENY6 = ("::1/128", "64:ff9b::/96", "fc00::/7", "fe80::/10", "fec0::/10", "ff00::/8")
# rollcall_zone_kind in TAIPANBOX/rollcall reads a zone the same way.
EXTERNAL_NETWORKS = ("wan", "wan6", "wwan")
OFF_WORDS = ("0", "no", "off", "false", "disabled")
# Linux allows anything but '/' and whitespace in 15 bytes; these end up between quotes in a rule.
DEVICE = re.compile(r"^[A-Za-z0-9_.-]{1,15}$")

RESOLVE_SECONDS = 3
COMMAND_SECONDS = 10
LOCK_SECONDS = 10
ALL_SECONDS = 40
# One line per way of being refused, at most six a minute each: enough to name a dead endpoint, and
# not a way for the agent to fill the log.
LOG = 'limit rate 6/minute log prefix "hermes-net: "'
REFUSE = 'counter name "dropped" reject with icmpx admin-prohibited'


def say(text):
    print("hermes-net: " + text, file=sys.stderr, flush=True)


def run(argv, stdin=None, seconds=COMMAND_SECONDS):
    """A command's result, never an exception: one that is missing or stuck is a failed one."""
    try:
        return subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=seconds, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        return subprocess.CompletedProcess(argv, 127, "", str(error))


def uci_show(package):
    """One config as {section: {".type": type, option: [values]}}; {} when there is none."""
    sections = {}
    for line in run(["uci", "-q", "show", package]).stdout.splitlines():
        key, found, value = line.partition("=")
        parts = key.split(".")
        if not found or parts[0] != package or len(parts) not in (2, 3):
            continue
        try:
            words = shlex.split(value)
        except ValueError:
            continue
        section = sections.setdefault(parts[1], {})
        if len(parts) == 2:
            section[".type"] = words[0] if words else ""
        else:
            section[parts[2]] = words
    return sections


def first(section, option, default=None):
    values = section.get(option)
    return values[0] if values else default


def is_on(section, option, default):
    return first(section, option, default).lower() not in OFF_WORDS


def split_endpoint(text):
    """(host, port) of a URL, port taken from the scheme when it names none, or None."""
    try:
        parts = urlsplit(text)
        host, port = parts.hostname, parts.port
    except ValueError:
        return None
    if port is None:
        port = {"http": 80, "https": 443}.get(parts.scheme)
    return (host, port) if host and port else None


def split_allow(text):
    """(host, port) of a lan_allow entry, `host:port` or `[v6]:port`, or None."""
    try:
        parts = urlsplit("//" + text)
        host, port = parts.hostname, parts.port
    except ValueError:
        return None
    return (host, port) if host and port and not parts.path and not parts.query and not parts.fragment else None


def address_of(text):
    """A literal address as ipaddress has it, its %zone dropped, or None for anything else."""
    try:
        return ipaddress.ip_address(text.split("%")[0])
    except ValueError:
        return None


def is_loopback(host):
    address = address_of(host)
    return host == "localhost" or (address is not None and address.is_loopback)


def resolve(hosts):
    """{host: {addresses}} for what answers within RESOLVE_SECONDS, all hosts at once. A host that
    does not answer is left out; the caller says so."""
    answers = {}

    def one(host):
        try:
            found = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
        except OSError:
            return
        answers[host] = {address for address in (address_of(entry[4][0]) for entry in found) if address}

    pending = []
    for host in hosts:
        literal = address_of(host)
        if literal:
            answers[host] = {literal}
        else:
            thread = threading.Thread(target=one, args=(host,), daemon=True)
            thread.start()
            pending.append(thread)
    deadline = time.monotonic() + RESOLVE_SECONDS
    for thread in pending:
        thread.join(max(0.0, deadline - time.monotonic()))
    return dict(answers)


def router_service_ports():
    """ROUTER_PORTS and the ports the router's own settings give SSH and uhttpd."""
    ports = set(ROUTER_PORTS)
    for section in uci_show("dropbear").values():
        ports.update(int(value) for value in section.get("Port", ()) if value.isdigit())
    for section in uci_show("uhttpd").values():
        for option in ("listen_http", "listen_https"):
            for value in section.get(option, ()):
                port = value.rsplit(":", 1)[-1]
                if port.isdigit():
                    ports.add(int(port))
    return sorted(port for port in ports if 0 < port < 65536)


def interfaces():
    """netifd's interfaces, or nothing when ubus does not answer: UCI then says what it can."""
    result = run(["ubus", "-t", "3", "call", "network.interface", "dump"])
    try:
        return json.loads(result.stdout).get("interface", []) if result.returncode == 0 else []
    except ValueError:
        return []


def house_devices():
    """The devices of every interface that does not face the internet: br-lan, a guest bridge, a VPN
    of the house. A zone faces the internet as rollcall reads it, and an interface that carries the
    default route faces it whatever its zone says, so the agent never loses the way out. A device
    that is on both sides is the way out for the same reason."""
    devices = {}
    for name, section in uci_show("network").items():
        if section.get(".type") == "interface":
            devices.setdefault(name, set()).update(section.get("device", ()))
    outside = set(EXTERNAL_NETWORKS)
    for entry in interfaces():
        name = entry.get("interface")
        if not isinstance(name, str):
            continue
        devices.setdefault(name, set()).update(
            entry[key] for key in ("l3_device", "device") if entry.get(key) and isinstance(entry[key], str))
        for route in entry.get("route") or ():
            if isinstance(route, dict) and route.get("mask") == 0:
                outside.add(name)
    inside_devices, outside_devices = set(), set()
    for section in uci_show("firewall").values():
        if section.get(".type") != "zone":
            continue
        networks = [word for value in section.get("network", ()) for word in value.split()]
        faces_out = first(section, "name") in EXTERNAL_NETWORKS or any(net in EXTERNAL_NETWORKS for net in networks) \
            or is_on(section, "masq", "0") or is_on(section, "masq6", "0")
        if faces_out:
            outside.update(networks)
        (outside_devices if faces_out else inside_devices).update(section.get("device", ()))
    for name, names in devices.items():
        if name != "loopback":
            (outside_devices if name in outside else inside_devices).update(names)
    found = []
    for device in sorted(inside_devices - outside_devices - {"lo"}):
        # An alias (@wan) and a wildcard (tun+) name no device; anything else that fails here is a
        # value that would otherwise be written into a rule.
        if DEVICE.match(device):
            found.append(device)
        elif not device.startswith("@") and not device.endswith("+"):
            say(f"{device!r} is not a device name, so it is left out of the devices of the house")
    return found


def resolvers():
    """The addresses libc will ask, when they are not the router's own: on a router without dnsmasq
    the resolver is on the LAN, and an agent that cannot ask it reaches nothing by name."""
    found = set()
    for path in RESOLV_FILES:
        try:
            with open(path, encoding="utf-8", errors="replace") as lines:
                words = [line.split() for line in lines]
        except OSError:
            continue
        for line in words:
            if len(line) >= 2 and line[0] == "nameserver":
                address = address_of(line[1])
                if address and not address.is_loopback:
                    found.add(address)
    return found


def minimal_plan(uid, house=()):
    """What goes in when the full rules cannot: the router's resolver, openwrt-mcp and llm-gateway
    at their default ports, and no host of the LAN."""
    return {"uid": uid, "local": [("tcp", 53), ("udp", 53), ("tcp", 8730), ("tcp", 8761)],
            "router": list(ROUTER_PORTS), "allow": [], "house": list(house)}


def collect(uid):
    """Everything the rules are made from. UCI and what the router's own programs say, and nothing
    the agent can write."""
    hermes = uci_show("hermes")
    main, security = hermes.get("main", {}), hermes.get("security", {})
    gateway = uci_show("llm-gateway")
    local = {("tcp", 53), ("udp", 53)}
    wanted = []  # (setting, host, port, protocols)

    def endpoint(label, url):
        parsed = split_endpoint(url)
        if parsed is None:
            say(f"{label} {url!r} names no host and port, so it opens nothing")
        elif is_loopback(parsed[0]):
            local.add(("tcp", parsed[1]))
        else:
            wanted.append((label, parsed[0], parsed[1], ("tcp",)))

    # With hermes.main.llm_gateway on, base_url stays in UCI and is not used.
    if not is_on(main, "llm_gateway", "0") and first(main, "base_url"):
        endpoint("hermes.main.base_url", first(main, "base_url"))
    endpoint("hermes.main.router_mcp_url", first(main, "router_mcp_url", MCP_URL_DEFAULT))
    if gateway:
        port = first(gateway.get("main", {}), "loopback_port", GATEWAY_PORT_DEFAULT)
        if port.isdigit() and 0 < int(port) < 65536:
            local.add(("tcp", int(port)))
        else:
            say(f"llm-gateway.main.loopback_port {port!r} is not a port, so it opens nothing")
    for name, section in sorted(hermes.items()):
        if section.get(".type") == "provider" and is_on(section, "enabled", "1") and first(section, "base_url"):
            endpoint(f"hermes.{name}.base_url", first(section, "base_url"))
    for value in security.get("lan_allow", ()):
        parsed = split_allow(value)
        if parsed is None:
            say(f"hermes.security.lan_allow {value!r} is not host:port, so it opens nothing")
        else:
            wanted.append(("hermes.security.lan_allow", parsed[0], parsed[1], ("tcp", "udp")))

    answers = resolve({host for _, host, _, _ in wanted})
    allow = {(address, proto, 53) for address in resolvers() for proto in ("tcp", "udp")}
    for label, host, port, protocols in wanted:
        if host not in answers:
            say(f"{label} names {host}, which does not resolve now, so it opens nothing until it does")
        for address in answers.get(host, ()):
            allow.update((address, proto, port) for proto in protocols)
    return {"uid": uid, "local": sorted(local), "router": router_service_ports(),
            "allow": sorted(allow, key=lambda item: (item[0].version, int(item[0]), item[1], item[2])),
            "house": house_devices()}


def render(plan):
    """The file nft loads, one transaction: the first two lines make `delete table` work whether or
    not the table is there, so the table is replaced with no moment between."""
    def named_set(name, kind, members, flags=""):
        lines = [f"\tset {name} {{", f"\t\ttype {kind}"]
        if flags:
            lines.append(f"\t\tflags {flags}")
        if members:
            lines.append(f"\t\telements = {{ {', '.join(members)} }}")
        return lines + ["\t}"]

    def entries(version):
        return [f"{item[0]} . {item[1]} . {item[2]}" for item in plan["allow"] if item[0].version == version]

    lines = ["# Written by hermes-net at every start; see /usr/libexec/hermes-net. Edits here do not last.",
             f"table inet {TABLE}", f"delete table inet {TABLE}", f"table inet {TABLE} {{",
             "\tcounter dropped {", "\t}"]
    lines += named_set("router_ports", "inet_service", [str(port) for port in plan["router"]])
    lines += named_set("local_ports", "inet_proto . inet_service", [f"{proto} . {port}" for proto, port in plan["local"]])
    lines += named_set("allow4", "ipv4_addr . inet_proto . inet_service", entries(4))
    lines += named_set("allow6", "ipv6_addr . inet_proto . inet_service", entries(6))
    lines += named_set("house_if", "ifname", [f'"{device}"' for device in plan["house"]])
    lines += named_set("deny4", "ipv4_addr", list(DENY4), "interval")
    lines += named_set("deny6", "ipv6_addr", list(DENY6), "interval")
    lines += ["", "\tchain output {", "\t\ttype filter hook output priority filter; policy accept;",
              f"\t\tmeta skuid {plan['uid']} jump agent", "\t}", "", "\tchain agent {"]

    def refuse(match):
        return [f"\t\t{match} {LOG}", f"\t\t{match} {REFUSE}"]

    # The agent is no server: anything but loopback is a reply to someone else's connection.
    lines += refuse('ct direction reply oif != "lo"')
    lines += ["\t\tct state established,related accept"]
    lines += refuse("fib daddr type local tcp dport @router_ports")
    lines += ["\t\tfib daddr type local meta l4proto . th dport @local_ports accept",
              "\t\tip daddr . meta l4proto . th dport @allow4 accept",
              "\t\tip6 daddr . meta l4proto . th dport @allow6 accept"]
    lines += refuse("fib daddr type local")
    # The global addresses of the house are not in any list of private ranges.
    lines += refuse("oifname @house_if")
    lines += refuse("ip daddr @deny4")
    lines += refuse("ip6 daddr @deny6")
    return "\n".join(lines + ["\t}", "}", ""])


def table_loaded():
    return run(["nft", "list", "table", "inet", TABLE]).returncode == 0


def checked(text):
    """Writes `text` beside the rules in force and asks nft about it, loading nothing. The file's
    path, or None with the reason said."""
    path = RULES + ".new"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(text)
    result = run(["nft", "-c", "-f", path])
    if result.returncode == 0:
        return path
    os.unlink(path)
    say("nft refused the rules: " + " ".join((result.stderr or result.stdout).split())[:200])
    return None


def load(uid, text):
    """Puts checked rules in force. Rules already in force and the same as `text` are left alone, so
    the drop counter keeps its count."""
    try:
        with open(RULES, encoding="utf-8") as current:
            same = current.read() == text
    except OSError:
        same = False
    if same and table_loaded():
        return True
    path = checked(text)
    if path is None:
        return False
    os.replace(path, RULES)
    result = run(["nft", "-f", RULES])
    if result.returncode != 0:
        say("nft would not load the rules: " + " ".join(result.stderr.split())[:200])
        return False
    shown = run(["nft", "list", "chain", "inet", TABLE, "output"]).stdout
    if f"meta skuid {uid} jump agent" not in shown:
        say("the rules did not read back from the kernel")
        return False
    return True


def edit_firewall(statements):
    """Runs uci statements on /etc/config/firewall, `firewall.` written as `{copy}.`. Through a copy
    of the file under another name, as LuCI's Security page writes hermes: uci reads what is staged
    for `firewall`, so a plain commit would take whatever else someone staged there. Raises OSError."""
    os.makedirs(RUN_DIR, mode=0o700, exist_ok=True)
    work = tempfile.mkdtemp(dir=RUN_DIR)
    try:
        copy = "hermes_net_firewall"
        shutil.copy2(FIREWALL_FILE, f"{work}/{copy}")
        batch = "".join(statement.format(copy=copy) + "\n" for statement in statements) + f"commit {copy}\n"
        result = run(["uci", "-q", "-c", work, "-t", work + "/delta", "batch"], stdin=batch)
        if result.returncode != 0:
            raise OSError(result.stderr.strip() or "uci refused it")
        beside = FIREWALL_FILE + ".hermes-net"
        shutil.copyfile(f"{work}/{copy}", beside)
        shutil.copystat(FIREWALL_FILE, beside)
        os.replace(beside, FIREWALL_FILE)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def ensure_include():
    """The section that brings the table back after `service firewall stop` and start, written once."""
    have = uci_show("firewall").get(INCLUDE, {})
    if have.get(".type") == "include" and first(have, "type") == "script" and first(have, "path") == REAPPLY \
            and is_on(have, "enabled", "1"):
        return
    try:
        edit_firewall((f"set {{copy}}.{INCLUDE}=include", f"set {{copy}}.{INCLUDE}.type=script",
                       f"set {{copy}}.{INCLUDE}.path={REAPPLY}", f"set {{copy}}.{INCLUDE}.enabled=1"))
    except OSError as error:
        say(f"could not write firewall.{INCLUDE} ({error}): the rules are in force, and a firewall "
            "stop and start would leave them out until the service starts again")


def take_lock():
    """Two interface events, or one and a start, must not write the same file at once. The hold ends
    with this process."""
    descriptor = os.open(LOCK, os.O_WRONLY | os.O_CREAT, 0o600)
    deadline = time.monotonic() + LOCK_SECONDS
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            if time.monotonic() > deadline:
                return False
            time.sleep(0.1)


def apply():
    os.makedirs(RUN_DIR, mode=0o700, exist_ok=True)
    os.chmod(RUN_DIR, 0o700)
    if not take_lock():
        say("another run has held the lock too long; not applying")
        return 1
    try:
        uid = pwd.getpwnam(USER).pw_uid
    except KeyError:
        say(f"there is no user {USER}, so there is nothing to limit")
        return 1
    if uid == 0:
        say(f"the user {USER} has uid 0, and limiting it would limit root")
        return 1
    house = ()
    try:
        plan = collect(uid)
        house = plan["house"]
        full = load(uid, render(plan))
    # A defect in reading the settings must not leave the agent with no limits at all.
    except Exception as error:  # pylint: disable=broad-except
        say(f"could not work out the rules ({type(error).__name__}: {error})")
        full = False
    if not full:
        say("the agent gets the minimal rules: no host of the LAN, only the router's own resolver, openwrt-mcp and llm-gateway")
        if not load(uid, render(minimal_plan(uid, house))):
            say("not even the minimal rules could be loaded")
            return 1
    ensure_include()
    return 0


def off():
    if table_loaded():
        result = run(["nft", "delete", "table", "inet", TABLE])
        if result.returncode != 0:
            say("could not delete the table: " + result.stderr.strip())
            return 1
    for path in (RULES, RULES + ".new"):
        try:
            os.unlink(path)
        except OSError:
            pass
    return 0


def remove():
    """What leaves with the package: the table, the file and the include."""
    rc = off()
    if INCLUDE in uci_show("firewall"):
        try:
            edit_firewall((f"delete {{copy}}.{INCLUDE}",))
        except OSError as error:
            say(f"could not delete firewall.{INCLUDE}: {error}")
            rc = 1
    shutil.rmtree(RUN_DIR, ignore_errors=True)
    return rc


def status():
    if not table_loaded():
        print("limits off")
        return 0
    chain = run(["nft", "list", "chain", "inet", TABLE, "output"]).stdout
    uid = re.search(r"meta skuid (\d+)", chain)
    counter = run(["nft", "list", "counter", "inet", TABLE, "dropped"]).stdout
    count = re.search(r"packets (\d+)", counter)
    print(f"limits on: uid {uid.group(1) if uid else '?'}, {count.group(1) if count else '?'} packets refused "
          "since the rules were last loaded; logread -e hermes-net names the addresses")
    return 0


def main(argv):
    commands = {"apply": apply, "off": off, "remove": remove, "status": status}
    if len(argv) != 2 or argv[1] not in commands:
        print("usage: hermes-net apply|off|remove|status", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        say("this runs as root")
        return 1
    signal.alarm(ALL_SECONDS)
    return commands[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
