#!/usr/bin/env python3
"""What the agent's own connections reach, proved with real nft and real sockets.

@claude 2026-11-07. Runs inside OpenWrt's own rootfs (scripts/gate-network.sh): real nft, real fw4
and the kernel's netfilter. The container is the router. Three network namespaces stand for a host
of the house, a host on a guest network and the WAN side; every probe is a real connection from a
forked process that has given up root for the account hermes, to a real listener.

Stood in for: the `ubus` command (a container has no netifd), which answers `network.interface
dump` from a file a test writes; fw4 itself talks to the real ubusd the gate starts.

`test-network.py --listen tcp,ports udp,ports` is the listener, in whatever namespace it is started.
"""
import errno
import json
import os
import pwd
import re
import selectors
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = Path(os.environ.get("PRODUCT_FILES", str(ROOT / "package/hermes-agent/files")))
NET = "/usr/libexec/hermes-net"
REAPPLY = "/usr/libexec/hermes-net-reapply"
HOTPLUG = "/etc/hotplug.d/iface/60-hermes-net"
RUN_DIR = "/var/run/hermes-agent"
RULES = RUN_DIR + "/net.nft"
TABLE = "inet hermes_agent"
AGENT = "hermes"
DATA_DIR = "/srv/hermes"

# The router's own addresses, and what stands on the other side of each cable.
ROUTER_ADDRESSES = ("127.0.0.1", "::1", "0.0.0.0", "::", "192.168.1.1", "fd00:1::1", "2001:db8:1::1",
                    "203.0.113.1", "2001:db8:f::1")
LAN_HOST = ("192.168.1.50", "fd00:1::50", "2001:db8:1::50")
GUEST_HOST = ("192.168.2.50", "2001:db8:2::50")
PUBLIC_HOSTS = ("203.0.113.10", "198.51.100.10", "2001:db8:f::10", "2001:db8:e::5")
# Reachable through the WAN side, none of them public.
NOT_PUBLIC = ("10.0.0.5", "172.16.0.5", "100.64.0.5", "100.100.100.100", "169.254.1.5",
              "fd7a:115c:a1e0::5", "fd00:2::5")

ROUTER_TCP = (22, 53, 80, 443, 7432, 8730, 8760, 8761, 9100, 11434)
ROUTER_UDP = (53, 7432)
FAR_TCP = (22, 53, 80, 443, 445, 8080, 11434)
FAR_UDP = (53, 445, 8080)

NETWORK = """config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1/8'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.1.1/24'

config interface 'wan'
	option device 'wan0'
	option proto 'static'

config interface 'wan6'
	option device 'wan0'
	option proto 'static'
"""
DUMP = {"interface": [
    {"interface": "lan", "up": True, "device": "br-lan", "l3_device": "br-lan", "route": []},
    {"interface": "wan", "up": True, "device": "wan0", "l3_device": "wan0",
     "route": [{"target": "0.0.0.0", "mask": 0, "nexthop": "203.0.113.10"}]},
    {"interface": "wan6", "up": True, "device": "wan0", "l3_device": "wan0",
     "route": [{"target": "::", "mask": 0, "nexthop": "2001:db8:f::10"}]},
    {"interface": "loopback", "up": True, "device": "lo", "l3_device": "lo", "route": []},
]}
UBUS_DUMP = Path("/tmp/net-dump.json")
UBUS_STANDIN = """#!/bin/sh
case "$*" in
	*"network.interface dump"*) cat /tmp/net-dump.json ;;
	*) exit 4 ;;
esac
"""


def sh(command, check=True, timeout=60):
    result = subprocess.run(["sh", "-c", command], capture_output=True, text=True, timeout=timeout, check=False)
    if check and result.returncode != 0:
        raise RuntimeError(f"{command}: rc {result.returncode}\n{result.stdout}{result.stderr}")
    return result


def listen(tcp, udp):
    """Answers on every address of the namespace it runs in, IPv4 and IPv6: one line for a TCP
    client, the datagram back for a UDP one. A port taken (the rootfs has nothing there) is fatal."""
    picker = selectors.DefaultSelector()
    for kind, ports in ((socket.SOCK_STREAM, tcp), (socket.SOCK_DGRAM, udp)):
        for port in ports:
            server = socket.socket(socket.AF_INET6, kind)
            server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("::", port))
            if kind == socket.SOCK_STREAM:
                server.listen(16)
            picker.register(server, selectors.EVENT_READ, kind)
    while True:
        for key, _ in picker.select():
            if key.data == socket.SOCK_STREAM:
                client, _ = key.fileobj.accept()
                try:
                    client.send(b"hello\n")
                finally:
                    client.close()
            else:
                data, peer = key.fileobj.recvfrom(512)
                key.fileobj.sendto(data, peer)


def as_user(user):
    """Become `user` for good, as hermes-drop does for the agent. In a forked child only."""
    entry = pwd.getpwnam(user)
    os.setgroups([])
    os.setgid(entry.pw_gid)
    os.setuid(entry.pw_uid)


def probe(host, port, proto="tcp", user=AGENT, scope=0, timeout=1.5):
    """A real connection, made from a fork that is `user`: "open", "blocked" (the rules refused it),
    "refused" (nothing listens there), "timeout", or an errno's name."""
    read_end, write_end = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_end)
        try:
            if user != "root":
                as_user(user)
            info = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM)
            family, kind, _, _, address = info[0]
            if scope and family == socket.AF_INET6:
                address = (address[0], address[1], 0, scope)
            client = socket.socket(family, kind)
            client.settimeout(timeout)
            client.connect(address)
            if proto == "udp":
                client.send(b"ping")
            answer = client.recv(16)
            outcome = "open" if answer else "timeout"
        except TimeoutError:
            outcome = "timeout"
        except OSError as error:
            outcome = {errno.EPERM: "blocked", errno.EACCES: "blocked", errno.EHOSTUNREACH: "blocked",
                       errno.ECONNREFUSED: "refused"}.get(error.errno, errno.errorcode.get(error.errno, str(error)))
        os.write(write_end, outcome.encode())
        os._exit(0)
    os.close(write_end)
    os.waitpid(pid, 0)
    outcome = os.read(read_end, 64).decode()
    os.close(read_end)
    return outcome


def in_namespace(ns, code, timeout=15):
    """Python run as root in a namespace, its stdout returned."""
    result = subprocess.run(["ip", "netns", "exec", ns, sys.executable, "-c", code],
                            capture_output=True, text=True, timeout=timeout, check=False)
    return result.stdout.strip() + result.stderr.strip()


def topology():
    """The router's cables, once per container; a mutant's run finds them there."""
    if Path("/var/run/netns/lan").exists():
        return
    enable = ("echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6; echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6; "
              "echo 0 > /proc/sys/net/ipv6/conf/all/accept_dad; echo 0 > /proc/sys/net/ipv6/conf/default/accept_dad; "
              "ip link set lo up")
    sh(f"""set -e
{enable}
ip link add br-lan type bridge; ip link set br-lan up
ip link add br-guest type bridge; ip link set br-guest up
ip addr add 192.168.1.1/24 dev br-lan
ip -6 addr add fd00:1::1/64 dev br-lan nodad
ip -6 addr add 2001:db8:1::1/64 dev br-lan nodad
ip addr add 192.168.2.1/24 dev br-guest
ip -6 addr add 2001:db8:2::1/64 dev br-guest nodad
for ns in lan guest wan; do ip netns add $ns; ip netns exec $ns sh -c '{enable}'; done
ip link add lan-port type veth peer name eth0 netns lan
ip link set lan-port master br-lan up
ip link add guest-port type veth peer name eth0 netns guest
ip link set guest-port master br-guest up
ip link add wan0 type veth peer name eth0 netns wan
ip link set wan0 up
ip addr add 203.0.113.1/24 dev wan0
ip -6 addr add 2001:db8:f::1/64 dev wan0 nodad
ip route add default via 203.0.113.10
ip -6 route add default via 2001:db8:f::10
ip netns exec lan sh -c 'ip link set eth0 up; ip addr add 192.168.1.50/24 dev eth0
	ip -6 addr add fd00:1::50/64 dev eth0 nodad; ip -6 addr add 2001:db8:1::50/64 dev eth0 nodad
	ip route add default via 192.168.1.1; ip -6 route add default via 2001:db8:1::1'
ip netns exec guest sh -c 'ip link set eth0 up; ip addr add 192.168.2.50/24 dev eth0
	ip -6 addr add 2001:db8:2::50/64 dev eth0 nodad
	ip route add default via 192.168.2.1; ip -6 route add default via 2001:db8:2::1'
ip netns exec wan sh -c 'ip link set eth0 up; ip addr add 203.0.113.10/24 dev eth0
	ip -6 addr add 2001:db8:f::10/64 dev eth0 nodad
	for a in 198.51.100.10 10.0.0.5 172.16.0.5 100.64.0.5 100.100.100.100 169.254.1.5; do ip addr add $a/32 dev lo; done
	for a in 2001:db8:e::5 fd7a:115c:a1e0::5 fd00:2::5; do ip -6 addr add $a/128 dev lo nodad; done
	ip route add 192.168.0.0/16 via 203.0.113.1; ip -6 route add default via 2001:db8:f::1'
""")
    me = [sys.executable, str(Path(__file__).resolve()), "--listen"]
    for ns, tcp, udp in ((None, ROUTER_TCP, ROUTER_UDP), ("lan", FAR_TCP, FAR_UDP), ("guest", FAR_TCP, FAR_UDP),
                         ("wan", FAR_TCP, FAR_UDP)):
        command = me + [",".join(map(str, tcp)), ",".join(map(str, udp))]
        if ns:
            command = ["ip", "netns", "exec", ns] + command
        subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    for _ in range(50):
        if probe("127.0.0.1", 22, user="root") == "open" and probe("192.168.1.50", 22, user="root") == "open" \
                and probe("198.51.100.10", 22, user="root") == "open":
            break
        time.sleep(0.2)
    else:
        raise RuntimeError("measured nothing: the listeners did not answer")


def account():
    """The account the package makes, the way its post-install makes it."""
    try:
        pwd.getpwnam(AGENT)
    except KeyError:
        sh(". /lib/functions.sh; gid=$(group_add_next hermes); user_add hermes $gid $gid 'Hermes Agent' /srv/hermes /bin/false")
    Path(DATA_DIR).mkdir(parents=True, exist_ok=True)
    shutil.chown(DATA_DIR, AGENT, AGENT)


def install_product():
    for source, target, mode in (("hermes-net.py", NET, 0o755), ("hermes-net-reapply", REAPPLY, 0o755),
                                 ("hermes-net.hotplug", HOTPLUG, 0o644)):
        path = FILES / source
        if path.exists():
            Path(target).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            os.chmod(target, mode)


def stand_in_ubus():
    ubus = Path(shutil.which("ubus"))
    if ubus.read_bytes().startswith(b"#!"):
        return
    ubus.rename(ubus.with_name("ubus.real"))
    ubus.write_text(UBUS_STANDIN)
    ubus.chmod(0o755)


def apply(*extra, check=True):
    """What the init and the wrapper run. On the unchanged code (RED_FIRST) there is nothing to run,
    and every check then says what the router does without it."""
    if not Path(NET).exists():
        return subprocess.CompletedProcess([], 127, "", "")
    result = subprocess.run(["python3", "-I", "-B", NET, *extra], capture_output=True, text=True, timeout=60, check=False)
    if check and result.returncode != 0 and extra[:1] == ("apply",):
        raise AssertionError(f"hermes-net {extra}: rc {result.returncode}\n{result.stdout}{result.stderr}")
    return result


def loaded():
    return sh(f"nft list table {TABLE}", check=False)


def fw4_rules():
    """fw4's own table without what moves by itself: its counters and rule handles."""
    text = sh("nft list table inet fw4").stdout
    return re.sub(r"packets \d+ bytes \d+", "", text)


def chains(text):
    """The rules of each chain in `nft list table`'s text, comments and declarations left out."""
    found, name = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        match = re.match(r"chain (\S+) \{", line)
        if match:
            name = match.group(1)
            found[name] = []
        elif line == "}":
            name = None
        elif name and line:
            found[name].append(line)
    return found


class NetworkTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        install_product()
        sh(f"nft delete table {TABLE} 2>/dev/null; rm -rf {RUN_DIR}; rm -f /tmp/.uci/firewall", check=False)
        shutil.copyfile("/tmp/pristine/firewall", "/etc/config/firewall")
        shutil.copyfile("/tmp/pristine/hosts", "/etc/hosts")
        shutil.copyfile(FILES / "hermes-agent.config", "/etc/config/hermes")
        for name in ("/etc/config/llm-gateway", DATA_DIR + "/config.yaml", DATA_DIR + "/.env"):
            Path(name).unlink(missing_ok=True)
        Path("/etc/config/network").write_text(NETWORK)
        Path("/etc/resolv.conf").write_text("nameserver 127.0.0.1\nnameserver ::1\n")
        Path("/tmp/resolv.conf").write_text("nameserver 127.0.0.1\nnameserver ::1\n")
        UBUS_DUMP.write_text(json.dumps(DUMP))
        if sh("nft list table inet fw4", check=False).returncode != 0:
            sh("rm -f /var/run/fw4.state; fw4 -q start")

    def uci(self, *statements):
        batch = "".join(statement + "\n" for statement in statements) + "commit hermes\n"
        result = subprocess.run(["uci", "batch"], input=batch, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def assertClosed(self, host, port, proto="tcp", scope=0):
        self.assertEqual(probe(host, port, proto, scope=scope), "blocked", f"the agent, to {host} port {port}/{proto}")

    def assertOpen(self, host, port, proto="tcp", user=AGENT):
        self.assertEqual(probe(host, port, proto, user=user), "open", f"{user}, to {host} port {port}/{proto}")

    def test_agent_cannot_reach_router_ports(self):
        apply("apply")
        for address in ROUTER_ADDRESSES:
            for port in (22, 80, 443, 7432, 9100):
                with self.subTest(address=address, port=port):
                    self.assertClosed(address, port)
                    self.assertOpen(address, port, user="root")
        self.assertClosed("127.0.0.1", 7432, "udp")
        self.assertClosed("192.168.1.1", 7432, "udp")

    def test_agent_cannot_reach_other_lan_hosts(self):
        apply("apply")
        for address in LAN_HOST:
            for port in (22, 80, 8080):
                with self.subTest(address=address, port=port):
                    self.assertClosed(address, port)
                    self.assertOpen(address, port, user="root")
        self.assertClosed("192.168.1.50", 8080, "udp")
        self.assertClosed("2001:db8:1::50", 8080, "udp")
        # A link-local address, which only the interface says how to reach.
        local = sh("ip netns exec lan ip -6 -o addr show dev eth0 scope link").stdout.split()[3].split("/")[0]
        bridge = socket.if_nametoindex("br-lan")
        self.assertEqual(probe(local, 22, scope=bridge), "blocked")
        self.assertEqual(probe(local, 22, user="root", scope=bridge), "open")

    def test_zones_decide_what_counts_as_the_house(self):
        with open("/etc/config/network", "a", encoding="utf-8") as network:
            network.write("\nconfig interface 'guest'\n\toption device 'br-guest'\n\toption proto 'static'\n")
        sh("uci add firewall zone; uci set firewall.@zone[-1].name=guest; uci add_list firewall.@zone[-1].network=guest; "
           "uci commit firewall")
        dump = json.loads(json.dumps(DUMP))
        dump["interface"].append({"interface": "guest", "up": True, "device": "br-guest", "l3_device": "br-guest", "route": []})
        UBUS_DUMP.write_text(json.dumps(dump))
        apply("apply")
        self.assertClosed("192.168.2.50", 8080)
        self.assertClosed("2001:db8:2::50", 8080)
        self.assertOpen("2001:db8:2::50", 8080, user="root")
        self.assertOpen("2001:db8:f::10", 8080)
        # An interface that carries the default route is the way out, whatever its zone says: a
        # travel router's uplink put in the lan zone keeps the agent on the internet.
        text = Path(RULES).read_text()
        self.assertIn('"br-guest"', text)
        self.assertNotIn('"wan0"', text)
        sh("uci add_list firewall.@zone[0].network=wan; uci commit firewall")
        apply("apply")
        self.assertOpen("2001:db8:f::10", 8080)

    def test_private_ranges_and_the_tailnet_are_closed(self):
        apply("apply")
        for address in NOT_PUBLIC:
            with self.subTest(address=address):
                self.assertClosed(address, 8080)
                self.assertOpen(address, 8080, user="root")
        self.assertClosed("100.64.0.5", 8080, "udp")
        self.assertClosed("fd7a:115c:a1e0::5", 8080, "udp")

    def test_public_internet_stays_reachable(self):
        apply("apply")
        for address in PUBLIC_HOSTS:
            for port in (443, 80):
                with self.subTest(address=address, port=port):
                    self.assertOpen(address, port)
            self.assertOpen(address, 8080, "udp")
        self.assertTrue(Path(RULES).exists(), "measured nothing: no rules were written")

    def test_lan_endpoint_from_uci_works_without_a_step(self):
        Path("/etc/hosts").write_text(Path("/tmp/pristine/hosts").read_text() + "192.168.1.50 ollama.lan\n")
        cases = (
            ("hermes.main.base_url=http://192.168.1.50:11434/v1", "192.168.1.50", 11434),
            ("hermes.main.base_url=http://ollama.lan:11434/v1", "192.168.1.50", 11434),
            ("hermes.main.base_url=http://[2001:db8:1::50]:11434/v1", "2001:db8:1::50", 11434),
            ("hermes.main.base_url=http://192.168.1.50/v1", "192.168.1.50", 80),
        )
        for statement, host, port in cases:
            with self.subTest(statement=statement):
                self.uci("set " + statement)
                apply("apply")
                self.assertOpen(host, port)
                self.assertClosed(host, 8080 if port != 8080 else 22)
        # A further provider's endpoint counts like the main one, and a switched-off one does not.
        self.uci("set hermes.main.base_url=https://openrouter.ai/api/v1", "set hermes.house=provider",
                 "set hermes.house.base_url=http://192.168.1.50:8080/v1", "set hermes.house.model=m",
                 "set hermes.off=provider", "set hermes.off.base_url=http://192.168.1.50:445/v1",
                 "set hermes.off.model=m", "set hermes.off.enabled=0")
        apply("apply")
        self.assertOpen("192.168.1.50", 8080)
        self.assertClosed("192.168.1.50", 445)
        self.assertClosed("192.168.1.50", 11434)

    def test_mcp_and_gateway_stay_reachable(self):
        apply("apply")
        self.assertOpen("127.0.0.1", 8730)
        # No llm-gateway on this router: its port is nothing the agent needs.
        self.assertClosed("127.0.0.1", 8761)
        Path("/etc/config/llm-gateway").write_text("config llm-gateway 'main'\n\toption enabled '1'\n")
        apply("apply")
        self.assertOpen("127.0.0.1", 8761)
        Path("/etc/config/llm-gateway").write_text("config llm-gateway 'main'\n\toption loopback_port '9100'\n")
        apply("apply")
        self.assertOpen("127.0.0.1", 9100)
        self.assertClosed("127.0.0.1", 8761)
        # The port the settings name for openwrt-mcp, and none when they name no connection.
        self.uci("set hermes.main.router_mcp_url=http://127.0.0.1:7432/mcp")
        apply("apply")
        self.assertOpen("127.0.0.1", 7432)
        self.assertClosed("127.0.0.1", 8730)
        self.uci("set hermes.main.router_mcp_url=")
        apply("apply")
        self.assertClosed("127.0.0.1", 7432)
        self.assertClosed("127.0.0.1", 8730)
        # A loopback model the settings name, which is how a tunnel to one looks.
        self.uci("set hermes.main.base_url=http://localhost:11434/v1")
        apply("apply")
        self.assertOpen("127.0.0.1", 11434)

    def test_dns_reaches_the_resolver(self):
        apply("apply")
        for address in ("127.0.0.1", "::1"):
            self.assertOpen(address, 53)
            self.assertOpen(address, 53, "udp")
        self.assertClosed("192.168.1.50", 53)
        Path("/tmp/resolv.conf").write_text("nameserver 192.168.1.50\nnameserver fd00:1::50\n")
        apply("apply")
        for address in ("192.168.1.50", "fd00:1::50"):
            self.assertOpen(address, 53)
            self.assertOpen(address, 53, "udp")
            self.assertClosed(address, 80)

    def test_allow_list_ignores_the_agents_own_files(self):
        Path(DATA_DIR + "/config.yaml").write_text(
            "model:\n  base_url: http://192.168.1.50:8080/v1\nproviders:\n  x:\n    base_url: http://192.168.1.50:8080/v1\n")
        Path(DATA_DIR + "/.env").write_text("OPENAI_BASE_URL=http://192.168.1.50:8080/v1\n")
        apply("apply")
        self.assertClosed("192.168.1.50", 8080)
        self.assertNotIn("192.168.1.50", Path(RULES).read_text())
        # The program opens neither file: its text names no such path.
        source = Path(NET).read_text()
        for word in ("config.yaml", "HERMES_HOME", ".env"):
            self.assertNotIn(word, source)

    def test_open_turns_the_limits_off(self):
        apply("apply")
        self.assertEqual(loaded().returncode, 0)
        self.assertEqual(apply("off").returncode, 0)
        self.assertNotEqual(loaded().returncode, 0)
        self.assertFalse(Path(RULES).exists())
        self.assertOpen("192.168.1.50", 8080)
        self.assertOpen("127.0.0.1", 22)
        # And once more, with nothing there: it says nothing failed.
        self.assertEqual(apply("off").returncode, 0)

    def test_lan_allow_adds_a_host(self):
        Path("/etc/hosts").write_text(Path("/tmp/pristine/hosts").read_text() + "192.168.1.50 nas.lan\n")
        self.uci("add_list hermes.security.lan_allow=nas.lan:445", "add_list hermes.security.lan_allow=[fd00:1::50]:8080",
                 "add_list hermes.security.lan_allow=192.168.1.50", "add_list hermes.security.lan_allow=x:y")
        result = apply("apply")
        self.assertOpen("192.168.1.50", 445)
        self.assertOpen("192.168.1.50", 445, "udp")
        self.assertOpen("fd00:1::50", 8080)
        self.assertClosed("192.168.1.50", 8080)
        self.assertClosed("fd00:1::50", 80)
        for bad in ("'192.168.1.50'", "'x:y'"):
            self.assertIn(bad, result.stderr, "an entry that makes no sense is named")

    def test_router_ports_stay_closed_whatever_uci_names(self):
        Path("/etc/hosts").write_text(Path("/tmp/pristine/hosts").read_text() + "192.168.1.1 sneaky.lan\n")
        self.uci("set hermes.main.base_url=http://192.168.1.1:22/v1", "set hermes.main.router_mcp_url=http://127.0.0.1:22/mcp",
                 "add_list hermes.security.lan_allow=127.0.0.1:443", "add_list hermes.security.lan_allow=sneaky.lan:80",
                 "add_list hermes.security.lan_allow=[::1]:22")
        apply("apply")
        for address, port in (("192.168.1.1", 22), ("127.0.0.1", 22), ("127.0.0.1", 443), ("192.168.1.1", 80), ("::1", 22)):
            self.assertClosed(address, port)
        # LuCI and SSH moved to other ports by their own settings are the same doors.
        Path("/etc/config/dropbear").write_text("config dropbear\n\toption Port '9100'\n")
        Path("/etc/config/uhttpd").write_text("config uhttpd 'main'\n\tlist listen_http '0.0.0.0:11434'\n\tlist listen_https '[::]:7432'\n")
        self.addCleanup(shutil.copyfile, "/tmp/pristine/dropbear", "/etc/config/dropbear")
        self.addCleanup(shutil.copyfile, "/tmp/pristine/uhttpd", "/etc/config/uhttpd")
        self.uci("set hermes.main.base_url=http://192.168.1.1:9100/v1", "add_list hermes.security.lan_allow=192.168.1.1:11434",
                 "add_list hermes.security.lan_allow=[::1]:7432")
        apply("apply")
        for address, port in (("192.168.1.1", 9100), ("192.168.1.1", 11434), ("::1", 7432)):
            self.assertClosed(address, port)
        # The doors are the router's: the same port on a host of the house is the owner's to name.
        self.uci("set hermes.main.base_url=http://192.168.1.50:80/v1")
        apply("apply")
        self.assertOpen("192.168.1.50", 80)

    def agent_is_still_limited(self):
        self.assertEqual(loaded().returncode, 0, "the table is gone")
        self.assertClosed("127.0.0.1", 22)
        self.assertClosed("192.168.1.50", 22)
        self.assertOpen("198.51.100.10", 22)

    def test_firewall_reload_keeps_the_table(self):
        apply("apply")
        sh("fw4 -q reload")
        self.agent_is_still_limited()

    def test_firewall_restart_keeps_the_table(self):
        apply("apply")
        sh("fw4 -q restart")
        self.agent_is_still_limited()

    def test_firewall_stop_start_restores_it(self):
        apply("apply")
        self.assertEqual(sh("uci -q get firewall.hermes_net.path", check=False).stdout.strip(), REAPPLY)
        # What `service firewall stop` runs: every table of the router goes, ours with it.
        sh("fw4 -q flush")
        self.assertNotEqual(loaded().returncode, 0)
        self.assertOpen("127.0.0.1", 22)
        sh("fw4 -q start")
        self.agent_is_still_limited()

    def test_bad_rules_leave_the_firewall_alone(self):
        apply("apply")
        good = Path(RULES).read_text()
        before = fw4_rules()
        source = Path(NET).read_text()
        self.addCleanup(install_product)
        # A defect in the full rules: the set of the house's devices gets a line nft refuses.
        self.assertIn("\t\ttype ifname\n", source, "measured nothing: the planted line has no place")
        Path(NET).write_text(source.replace("\t\ttype ifname\n", "\t\ttype ifname\n\t\tthis is no nft\n")
                             .replace("def render(plan):", "def render(plan, _real=None):", 1))
        self.uci("set hermes.main.base_url=http://192.168.1.50:11434/v1")
        # Planted so that only the full plan is broken: the minimal one drops the allow rule's host.
        Path(NET).write_text(source.replace("elements = {{ {members} }}", "elements = {{ {members} }}\\n\\t\\tbroken here"))
        result = apply("apply", check=False)
        self.assertNotEqual(result.returncode, 0, "rules nft refuses reported as applied")
        self.assertIn("not", result.stderr)
        self.assertEqual(fw4_rules(), before, "fw4's own table changed")
        self.assertEqual(Path(RULES).read_text(), good, "a refused file took the place of the rules in force")
        # The full plan refused and the minimal one not: the fallback goes in, without the LAN host.
        install_product()
        Path(NET).write_text(source.replace("def render(plan):\n", "def render(plan):\n"
                                            "    if plan[\"allow\"]:\n        return 'table inet hermes_agent { this is no nft }'\n"))
        result = apply("apply", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(loaded().returncode, 0)
        self.assertIn("minimal", result.stderr)
        self.assertClosed("192.168.1.50", 11434)
        self.assertClosed("127.0.0.1", 22)
        self.assertOpen("127.0.0.1", 8730)
        self.assertEqual(fw4_rules(), before, "fw4's own table changed")

    def test_rules_stay_out_of_fw4(self):
        before = fw4_rules()
        self.assertEqual(sh("nft list tables").stdout.split(), ["table", "inet", "fw4"])
        apply("apply")
        self.assertEqual(fw4_rules(), before, "fw4's own table changed")
        self.assertEqual(sorted(sh("nft list tables").stdout.strip().splitlines()),
                         ["table inet fw4", "table inet hermes_agent"])
        text = Path(RULES).read_text()
        self.assertNotIn("fw4", text)
        tables = set(re.findall(r"^\s*(?:add |delete |flush )?(?:table|chain|rule) (\S+ \S+)", text, re.M))
        self.assertEqual(tables, {TABLE})

    def test_packets_with_no_socket_still_leave(self):
        apply("apply")
        # A reset the kernel sends for a closed port belongs to no socket of anyone, and neither does
        # an ICMP error. A negative match on the uid would send both to the refusals.
        script = ("import socket\ns=socket.socket(socket.AF_INET{f},socket.SOCK_STREAM);s.settimeout(3)\n"
                  "try:\n s.connect(('{a}',23));print('open')\nexcept ConnectionRefusedError:print('reset')\n"
                  "except OSError as e:print(repr(e))\n")
        self.assertEqual(in_namespace("lan", script.format(f="", a="192.168.1.1")), "reset")
        self.assertEqual(in_namespace("lan", script.format(f="6", a="fd00:1::1")), "reset")
        udp = ("import socket\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3);s.connect(('192.168.1.1',24))\n"
               "s.send(b'x')\ntry:\n s.recv(9);print('open')\nexcept ConnectionRefusedError:print('icmp')\n"
               "except OSError as e:print(repr(e))\n")
        self.assertEqual(in_namespace("lan", udp), "icmp")
        uid = pwd.getpwnam(AGENT).pw_uid
        output = chains(loaded().stdout)["output"]
        self.assertEqual(output[0], "type filter hook output priority filter; policy accept;")
        self.assertEqual(output[1:], [f"meta skuid {uid} jump agent"])
        self.assertNotIn("skuid !=", Path(RULES).read_text())

    def test_every_refusal_sits_in_chain_agent(self):
        apply("apply")
        found = chains(loaded().stdout)
        self.assertGreaterEqual(len(found.get("agent", [])), 8, "measured nothing: no rules in chain agent")
        for name, rules in found.items():
            refusals = [rule for rule in rules if re.search(r"\b(drop|reject)\b", rule) and "policy" not in rule]
            if name == "agent":
                self.assertGreaterEqual(len(refusals), 4)
            else:
                self.assertEqual(refusals, [], f"chain {name}")
        self.assertEqual([name for name, rules in found.items() if any(" hook " in rule for rule in rules)], ["output"])

    def test_include_never_calls_fw4(self):
        self.assertTrue(Path(REAPPLY).exists(), "measured nothing: no include script")
        lines = [line for line in Path(REAPPLY).read_text().splitlines() if line.strip() and not line.startswith("#")]
        self.assertGreater(len(lines), 0, "measured nothing: the include script runs nothing")
        words = re.findall(r"[A-Za-z0-9_./-]+", " ".join(lines))
        for word in ("fw4", "uci", "ubus", "config", "python3", "hermes-net"):
            self.assertNotIn(word, words, f"the include calls {word}")
        self.assertIn("nft", words)
        # By its effect too: fw4 holds its lock while includes run, so a `fw4 zone` in one would sit
        # there until fw4 gives up on the script after 30 seconds.
        apply("apply")
        started = time.monotonic()
        sh("fw4 -q reload", timeout=45)
        self.assertLess(time.monotonic() - started, 15, "fw4 reload waited on its include")

    def test_uid_is_read_at_apply_time(self):
        apply("apply")
        entry = pwd.getpwnam(AGENT)
        changed = entry.pw_uid + 7
        text = Path("/etc/passwd").read_text()
        self.addCleanup(Path("/etc/passwd").write_text, text)
        Path("/etc/passwd").write_text(text.replace(f"hermes:x:{entry.pw_uid}:", f"hermes:x:{changed}:")
                                       .replace(f"hermes:*:{entry.pw_uid}:", f"hermes:*:{changed}:"))
        self.assertEqual(pwd.getpwnam(AGENT).pw_uid, changed, "measured nothing: the account did not change")
        apply("apply")
        self.assertIn(f"meta skuid {changed} jump agent", loaded().stdout)
        self.assertNotIn(f"meta skuid {entry.pw_uid} jump agent", loaded().stdout)

    def test_limits_touch_no_other_user(self):
        apply("apply")
        for user in ("root", "nobody"):
            for host, port in (("127.0.0.1", 22), ("192.168.1.1", 80), ("192.168.1.50", 22), ("fd00:1::50", 8080),
                               ("100.64.0.5", 8080)):
                with self.subTest(user=user, host=host):
                    self.assertOpen(host, port, user=user)
        self.assertClosed("127.0.0.1", 22)

    def test_agent_is_no_server_for_the_house(self):
        apply("apply")
        read_end, write_end = os.pipe()
        pid = os.fork()
        if pid == 0:
            as_user(AGENT)
            server = socket.socket(socket.AF_INET6)
            server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("::", 4040))
            server.listen(8)
            os.write(write_end, b"up")
            while True:
                client, _ = server.accept()
                try:
                    client.send(b"hello\n")
                except OSError:
                    pass
                client.close()
        self.addCleanup(os.waitpid, pid, 0)
        self.addCleanup(os.kill, pid, 9)
        self.assertEqual(os.read(read_end, 2), b"up")
        script = ("import socket\ns=socket.create_connection(('{a}',4040),3);s.settimeout(3)\n"
                  "try:\n print(s.recv(9) or 'closed')\nexcept OSError as e:print(type(e).__name__)\n")
        answer = in_namespace("lan", script.format(a="192.168.1.1"))
        self.assertNotIn("hello", answer)
        self.assertEqual(probe("127.0.0.1", 4040, user="root"), "open")

    def test_drop_counter_and_log_line(self):
        apply("apply")
        status = apply("status")
        self.assertEqual(status.returncode, 0, status.stderr)
        uid = pwd.getpwnam(AGENT).pw_uid
        self.assertIn(f"uid {uid}", status.stdout)
        self.assertIn("0 ", status.stdout)
        self.assertClosed("192.168.1.50", 22)
        self.assertClosed("127.0.0.1", 22)
        self.assertClosed("fd00:2::5", 22)
        count = int(re.search(r"packets (\d+)", sh(f"nft list counter {TABLE} dropped").stdout).group(1))
        self.assertGreaterEqual(count, 3)
        self.assertIn(f" {count} ", apply("status").stdout)
        # Every way of being refused logs first: the line is what names the address.
        rules = chains(loaded().stdout)["agent"]
        refusals = [rule for rule in rules if "reject" in rule]
        logged = [rule for rule in rules if 'log prefix "hermes-net: "' in rule]
        self.assertEqual(len(logged), len(refusals))
        for rule in logged:
            self.assertIn("limit rate 6/minute", rule)
        apply("off")
        self.assertIn("off", apply("status").stdout)

    def test_hostile_uci_values_write_no_rule(self):
        apply("apply")
        clean = Path(RULES).read_text()
        hostile = 'x" } chain z { type filter hook input priority 0; policy drop; } set y { type ifname; elements = { "y'
        dump = json.loads(json.dumps(DUMP))
        dump["interface"].append({"interface": "evil", "up": True, "device": hostile, "l3_device": hostile, "route": []})
        UBUS_DUMP.write_text(json.dumps(dump))
        with open("/etc/config/network", "a", encoding="utf-8") as network:
            network.write("\nconfig interface 'evil2'\n\toption device 'a b;c'\n")
        self.uci("add_list hermes.security.lan_allow=1.2.3.4:99999", "add_list hermes.security.lan_allow=1.2.3.4:80;drop",
                 "set hermes.main.base_url=http://[::1%25eth0;]:80/v1")
        result = apply("apply")
        rules = Path(RULES).read_text()
        for marker in ("policy drop", "chain z", "99999", "a b;c", ";drop"):
            self.assertNotIn(marker, rules)
        self.assertEqual(loaded().returncode, 0)
        self.assertIn("evil", "".join(line for line in result.stderr.splitlines() if "not a device name" in line) or "evil")
        self.assertEqual(set(chains(rules)), set(chains(clean)), "the rules grew a chain")

    def test_a_name_that_does_not_resolve_is_named_and_left_out(self):
        self.uci("set hermes.main.base_url=http://no-such-host.invalid:8080/v1")
        started = time.monotonic()
        result = apply("apply")
        self.assertLess(time.monotonic() - started, 10, "a name nobody answers for held the start up")
        self.assertIn("hermes.main.base_url", result.stderr)
        self.assertIn("no-such-host.invalid", result.stderr)
        self.assertEqual(loaded().returncode, 0)
        self.assertClosed("127.0.0.1", 22)

    def test_interface_event_reapplies_the_rules(self):
        apply("apply")
        self.assertNotIn('"br-guest"', Path(RULES).read_text())
        dump = json.loads(json.dumps(DUMP))
        dump["interface"].append({"interface": "guest", "up": True, "device": "br-guest", "l3_device": "br-guest", "route": []})
        UBUS_DUMP.write_text(json.dumps(dump))
        for action, seen in (("ifdown-ignored", False), ("ifup", True)):
            sh(f"ACTION={action.split('-', maxsplit=1)[0] if action == 'ifup' else 'iflink'} INTERFACE=guest sh {shlex.quote(HOTPLUG)}")
            for _ in range(50):
                if ('"br-guest"' in Path(RULES).read_text()) == seen and seen:
                    break
                time.sleep(0.1)
            self.assertEqual('"br-guest"' in Path(RULES).read_text(), seen, action)
        self.assertIn('"br-guest"', loaded().stdout)
        # With no rules written the event does nothing: the limits are the service's to start.
        apply("off")
        sh(f"ACTION=ifup INTERFACE=lan sh {shlex.quote(HOTPLUG)}")
        time.sleep(1)
        self.assertNotEqual(loaded().returncode, 0)

    def test_a_start_that_changes_nothing_writes_nothing(self):
        apply("apply")
        before = os.stat("/etc/config/firewall")
        self.assertClosed("127.0.0.1", 22)
        count = sh(f"nft list counter {TABLE} dropped").stdout
        apply("apply")
        after = os.stat("/etc/config/firewall")
        self.assertEqual((before.st_mtime_ns, before.st_ino), (after.st_mtime_ns, after.st_ino))
        self.assertEqual(sh(f"nft list counter {TABLE} dropped").stdout, count)
        self.assertRegex(count, r"packets [1-9]")

    def test_include_section_leaves_staged_changes_alone(self):
        sh("uci set firewall.@defaults[0].forward=ACCEPT")
        apply("apply")
        self.assertEqual(sh("uci -q get firewall.hermes_net.type", check=False).stdout.strip(), "script")
        text = Path("/etc/config/firewall").read_text()
        self.assertIn("hermes_net", text)
        self.assertIn("option forward 'REJECT'", text, "someone's staged change went into the file")
        self.assertIn("forward", sh("uci changes firewall").stdout, "someone's staged change is gone")
        self.assertEqual(oct(os.stat("/etc/config/firewall").st_mode & 0o777),
                         oct(os.stat("/tmp/pristine/firewall").st_mode & 0o777))


def setup():
    account()
    Path("/tmp/pristine").mkdir(exist_ok=True)
    # fw4 learns which device a zone's network sits on from netifd, which a container lacks, so no
    # traffic matches a zone here and the default decides: without this, neighbour discovery to the
    # router's own addresses is rejected and every IPv6 host looks dead, to root as well.
    sh("uci set firewall.@defaults[0].input=ACCEPT; uci commit firewall")
    for name in ("firewall", "dropbear", "uhttpd"):
        target = Path("/tmp/pristine") / name
        if not target.exists():
            shutil.copyfile("/etc/config/" + name, target)
    if not Path("/tmp/pristine/hosts").exists():
        shutil.copyfile("/etc/hosts", "/tmp/pristine/hosts")
    stand_in_ubus()
    topology()


if __name__ == "__main__":
    if sys.argv[1:2] == ["--listen"]:
        listen([int(p) for p in sys.argv[2].split(",")], [int(p) for p in sys.argv[3].split(",")])
        sys.exit(0)
    if not (FILES / "hermes-agent.init").exists():
        sys.exit(f"measured nothing: no product files in {FILES}")
    if not (FILES / "hermes-net.py").exists() and not os.environ.get("RED_FIRST"):
        sys.exit(f"measured nothing: no hermes-net in {FILES}")
    setup()
    unittest.main()
