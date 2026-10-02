#!/usr/bin/env python3
"""security-harness.py -- the three scenarios of the LuCI Security page and the SSH enrolment,
run inside OpenWrt's rootfs by scripts/gate-unlock.sh.

  security-harness.py <scenario> [args]

What is real here: rpcd with the INSTALLED luci-app-hermes backend, called through ubus the way
LuCI calls it, and the real openwrt-mcp, which holds the hashed PIN and the TOTP secrets. What is
a stand-in is only the browser, which is not needed to ask what the backend answers; the page's
own JavaScript is checked by scripts/test-luci-views.mjs.

Each scenario prints "PASS: <what it saw>" or "FAIL: <why>" as its last line. The shell side
(gate-unlock.sh) sets the router up first and does what needs the daemon afterwards.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qr_decode  # noqa: E402

CLIENT = "hermes-main"
SHIM_LOG = "/tmp/mcp-shim.log"
# Every program the backend ran, what it was run with and the environment it carried, as the
# recorders gate-unlock.sh puts in front of jshn, jsonfilter, uci and openwrt-mcp wrote it.
PROGRAM_LOG = "/tmp/shim.log"
# Where a secret could be written down: every place a router keeps files that change, and the
# directories of programs a call runs. /proc, /sys and /dev hold no files this gate wrote, and the
# agent's own 270 MB of Python is a package payload that no call of the backend writes into.
SCAN_ROOTS = ["/etc", "/tmp", "/var", "/run", "/srv", "/root", "/home", "/www", "/usr/libexec", "/usr/sbin", "/usr/bin", "/sbin", "/bin"]
SKIP_FILES = {"/etc/openwrt-mcp/pin"}  # openwrt-mcp's own hashed store; asserted to be a hash, not skipped blindly


class Fail(Exception):
    pass


def need(cond, message):
    if not cond:
        raise Fail(message)


# ------------------------------------------------------------------------------ talking to rpcd

def ubus(method, args=None, timeout=90):
    """(parsed reply, raw text) of `ubus call hermes <method>`, as LuCI's own call would make it."""
    cmd = ["ubus", "-t", str(timeout), "call", "hermes", method]
    if args is not None:
        cmd.append(json.dumps(args))
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10)
    raw = r.stdout + r.stderr
    if r.returncode != 0:
        raise Fail("ubus call hermes %s failed (%s): %s" % (method, r.returncode, raw.strip()[:200]))
    try:
        return json.loads(r.stdout), raw
    except ValueError:
        raise Fail("ubus call hermes %s did not answer JSON: %s" % (method, raw.strip()[:200]))


def status():
    return ubus("security_status")[0]


def cli(*argv, stdin=None, check=True):
    r = subprocess.run(["openwrt-mcp"] + list(argv), input=stdin, capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise Fail("openwrt-mcp %s failed: %s" % (" ".join(argv[:3]), (r.stdout + r.stderr).strip()[:200]))
    return r


def uci_get(name):
    return subprocess.run(["uci", "-q", "get", name], capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------------------------------- TOTP

def totp(secret, at=None):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    h = hmac.new(key, struct.pack(">Q", int((at or time.time()) // 30)), hashlib.sha1).digest()
    o = h[-1] & 15
    return "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** 6)


def wrong_code(secret):
    """A six-digit code that is valid at none of the steps the daemon accepts."""
    valid = {totp(secret, time.time() + d * 30) for d in (-2, -1, 0, 1, 2)}
    n = 123456
    while "%06d" % n in valid:
        n += 1
    return "%06d" % n


def secret_of(uri):
    m = re.search(r"[?&]secret=([A-Z2-7]+)", uri)
    need(m, "the otpauth URI carries no secret")
    return m.group(1)


# ------------------------------------------------------------------------- where a secret may be

def files_under(roots):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, _, names in os.walk(root, followlinks=False):
            for name in names:
                path = os.path.join(dirpath, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                yield path


def whole_token(needle):
    return re.compile(rb"(?<![0-9A-Za-z])" + re.escape(needle.encode()) + rb"(?![0-9A-Za-z])")


def find_in_files(needles, roots=SCAN_ROOTS, skip=SKIP_FILES):
    pats = [(n, whole_token(n)) for n in needles]
    hits = []
    for path in files_under(roots):
        if path in skip:
            continue
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        for n, p in pats:
            if p.search(data):
                hits.append(path)
                break
    return hits


def programs_hold_nothing(needles, what):
    """The needles are in the argument list or the environment of no program the backend started.
    Not sampled: every start of the four programs that could be handed a message is recorded."""
    log = open(PROGRAM_LOG).read() if os.path.exists(PROGRAM_LOG) else ""
    seen = {m.group(1) for m in re.finditer(r"^ARGV (\S+)", log, re.M)}
    for prog in ("/usr/bin/jshn", "/usr/bin/jsonfilter", "/sbin/uci", "/usr/bin/openwrt-mcp"):
        need(prog in seen, "the recorder never saw %s run, so the check measures nothing (saw %s)" % (prog, sorted(seen)))
    for n in needles:
        i = log.find(n)
        if i >= 0:
            start = log.rfind("ARGV ", 0, i)
            raise Fail("%s is in the arguments or environment of a program the backend ran: %s" % (what, log[start:start + 70].replace("\n", " | ")))


class ProcessWatch(threading.Thread):
    """Polls every process's argument list and environment for a needle while something runs,
    the way `ps` or /proc/<pid>/cmdline would show it to anyone on the router. The `ubus` client
    that made the call is the one place the caller's own message is bound to be, so it is the
    one exception; rpcd, the backend and everything the backend starts are not."""

    def __init__(self, needles):
        super().__init__(daemon=True)
        self.needles = [n.encode() for n in needles]
        self.hits, self.stop, self.samples = set(), False, 0

    def run(self):
        me = os.getpid()
        while not self.stop:
            for pid in os.listdir("/proc"):
                if not pid.isdigit() or int(pid) == me:
                    continue
                try:
                    comm = open("/proc/%s/comm" % pid).read().strip()
                    if comm == "ubus":
                        continue
                    blob = open("/proc/%s/cmdline" % pid, "rb").read() + open("/proc/%s/environ" % pid, "rb").read()
                except OSError:
                    continue
                self.samples += 1
                for n in self.needles:
                    if n in blob:
                        self.hits.add("%s (pid %s): %s" % (comm, pid, blob[:60].replace(b"\0", b" ").decode("utf-8", "replace")))
            time.sleep(0.001)


# ========================================================================= the three scenarios

def scenario_enrol():
    """check_luci_enrol_shows_qr_and_verifies, up to a daemon that has the new policy; the shell
    side then starts the agent (the init writes the policy from hermes.security) and unlocks."""
    st = status()
    need(st.get("paired") is True and st.get("applies") is True, "the Security page's backend cannot see hermes-main: %s" % json.dumps(st))
    need(st.get("totp_enrolled") is False and st.get("totp_pending") is False, "a phone was enrolled before anyone asked: %s" % json.dumps(st))

    # 1. the page asks to add a phone: the QR comes back, decodable, for this router's client
    first, raw = ubus("enrol_start")
    need(first.get("ok") is True, "enrol_start refused: %s" % json.dumps({k: v for k, v in first.items() if k not in ("secret", "uri", "qr_png_base64")}))
    uri, secret, png = first.get("uri", ""), first.get("secret", ""), first.get("qr_png_base64", "")
    need(uri.startswith("otpauth://totp/") and CLIENT in uri, "the URI is not an otpauth URI for %s: %r" % (CLIENT, uri[:60]))
    need(re.fullmatch(r"[A-Z2-7]{32}", secret) and secret_of(uri) == secret, "the secret shown for manual entry is not the one in the URI")
    open("/tmp/sec.png", "wb").write(base64.b64decode(png, validate=True))
    try:
        decoded = qr_decode.decode_png("/tmp/sec.png")
    except qr_decode.QRError as e:
        raise Fail("the QR the page is given does not decode: %s" % e)
    need(decoded == uri, "the QR decodes to %r, not to the URI the page was told" % decoded[:80])
    try:
        qr_decode.decode_png("/tmp/sec.png", flip=[(20, 20), (22, 25), (30, 31)])
        raise Fail("the decoder read a damaged QR, so 'decodable' proves nothing")
    except qr_decode.QRError:
        pass
    os.unlink("/tmp/sec.png")

    # 2. nothing is in force yet, and the factor cannot be set to what does not exist yet
    st = status()
    need(st["totp_pending"] is True and st["totp_enrolled"] is False, "after enrol_start: %s" % json.dumps(st))
    r, _ = ubus("set_factor", {"factor": "totp", "window": "15m", "max_failures": 5, "lockout": "15m"})
    need(r.get("ok") is False, "set_factor totp was accepted with the phone only pending")
    need(uci_get("hermes.security.factor") in ("", "none"), "the refused factor was written anyway: " + uci_get("hermes.security.factor"))

    # 3. a wrong or malformed code activates nothing and the enrolment stays pending
    for code in (wrong_code(secret), "12345", "1234567", "abcdef", "12 456", ""):
        r, _ = ubus("enrol_activate", {"code": code})
        need(r.get("ok") is False, "enrol_activate took %r" % code)
        st = status()
        need(st["totp_enrolled"] is False and st["totp_pending"] is True, "after the code %r: %s" % (code, json.dumps(st)))
    need(secret not in json.dumps(r), "a refused activation answered with the secret")

    # 4. the right code activates; the factor can then be chosen
    r, _ = ubus("enrol_activate", {"code": totp(secret)})
    need(r.get("ok") is True, "the current code was refused: %s" % json.dumps(r))
    st = status()
    need(st["totp_enrolled"] is True and st["totp_pending"] is False, "after activation: %s" % json.dumps(st))
    r, _ = ubus("set_factor", {"factor": "totp", "window": "15m", "max_failures": 5, "lockout": "15m"})
    need(r.get("ok") is True, "set_factor totp refused after activation: %s" % json.dumps(r))
    need(uci_get("hermes.security.factor") == "totp", "hermes.security.factor is %r after set_factor totp" % uci_get("hermes.security.factor"))

    # 5. adding a phone again gives new material, and leaves the one in force in force
    second, _ = ubus("enrol_start")
    need(second.get("ok") is True, "a second enrol_start refused")
    need(second["secret"] != secret and second["uri"] != uri and second["qr_png_base64"] != png,
         "a second enrol_start returned the first one's material")
    st = status()
    need(st["totp_enrolled"] is True and st["totp_pending"] is True, "with a second phone pending: %s" % json.dumps(st))

    # 6. once: no read method hands the material back, whatever it is asked
    for method in ("status", "logs", "security_status"):
        _, text = ubus(method)
        for what, needle in (("secret", secret), ("secret of the pending phone", second["secret"]), ("URI", uri)):
            need(needle not in text, "%s returned the %s" % (method, what))

    # and no program the backend ran was handed the secret, the address or the picture
    programs_hold_nothing([secret, second["secret"], png[300:340], second["qr_png_base64"][300:340]], "a phone's secret or QR")

    open("/tmp/totp.secret", "w").write(secret)
    open("/tmp/totp.pending", "w").write(second["secret"])
    return ("QR decodes to the otpauth URI for %s; nothing in force until a code is entered; a wrong code, a short, a long, a "
            "non-numeric and an empty one refused with the enrolment still pending; set_factor totp refused before and accepted "
            "after activation; a second enrol_start gives a different secret, URI and QR and leaves the active one in force; "
            "no read method returned any of it, and no program the backend ran was given it" % CLIENT)


def code():
    """A code from the secret of the phone in force (`active`) or the pending one (`pending`), for
    the step after the one activation spent."""
    which = sys.argv[2] if len(sys.argv) > 2 else "active"
    secret = open("/tmp/totp.secret" if which == "active" else "/tmp/totp.pending").read().strip()
    print(totp(secret, time.time() + 30))
    return None


def scenario_cli():
    """check_cli_enrol_prints_qr: the owner over SSH, with the commands the README gives."""
    readme = open("/README.md", encoding="utf-8").read()
    commands = ["openwrt-mcp mfa enrol %s --pending --qr" % CLIENT, "openwrt-mcp mfa activate %s <" % CLIENT,
                "openwrt-mcp pin set %s" % CLIENT]
    for c in commands:
        need(c in readme, "the README does not give the command: %s" % c)
    # The config file the package ships says it too, in the same two steps: it is what an owner
    # reads on the router before anything else, and it once still showed the one-step form. The
    # copy the gate took before uci rewrote the file (which drops comments) is the shipped one.
    shipped = open("/tmp/pristine/hermes.config", encoding="utf-8").read()
    for c in commands:
        need(c in shipped, "the config file the package ships does not give the command: %s" % c)
    st = cli("status", "--json", "--audit", "0").stdout
    mine = [c for c in json.loads(st)["clients"] if c["name"] == CLIENT]
    need(mine and mine[0]["mfa"]["totp_pending"] is False and mine[0]["mfa"]["totp_enrolled"] is False, "not a clean start: %s" % st[:200])

    r = cli("mfa", "enrol", CLIENT, "--pending", "--qr")
    out = r.stdout
    need("pending" in out.lower(), "the command does not say the enrolment is pending: %s" % out[:200])
    uris = [l.strip() for l in out.splitlines() if l.strip().startswith("otpauth://totp/")]
    need(len(uris) == 1 and CLIENT in uris[0], "the output has no otpauth URI for %s" % CLIENT)
    secret = secret_of(uris[0])
    need(("secret: " + secret) in out, "the secret is not printed for manual entry")
    try:
        art = qr_decode.decode_art(out)
    except qr_decode.QRError as e:
        raise Fail("the terminal shows no QR block that decodes: %s" % e)
    need(art == uris[0], "the QR block in the terminal decodes to %r, not to the URI printed above it" % art[:80])
    blocks = [l for l in out.splitlines() if l.startswith("  ") and any(c in l for c in "█▀▄")]
    need(len(blocks) >= 15, "the QR block is %d lines" % len(blocks))

    st = json.loads(cli("status", "--json", "--audit", "0").stdout)["clients"]
    mine = [c for c in st if c["name"] == CLIENT][0]["mfa"]
    need(mine["totp_pending"] is True and mine["totp_enrolled"] is False, "right after enrol --pending: %s" % mine)

    bad = cli("mfa", "activate", CLIENT, wrong_code(secret), check=False)
    need(bad.returncode != 0 and "pending" in (bad.stdout + bad.stderr).lower(), "a wrong code did not leave the enrolment pending: %s" % (bad.stdout + bad.stderr)[:200])
    mine = [c for c in json.loads(cli("status", "--json", "--audit", "0").stdout)["clients"] if c["name"] == CLIENT][0]["mfa"]
    need(mine["totp_enrolled"] is False, "a wrong code activated the enrolment")
    ok = cli("mfa", "activate", CLIENT, totp(secret))
    need("activated" in ok.stdout.lower(), "the current code did not activate: %s" % ok.stdout[:200])
    mine = [c for c in json.loads(cli("status", "--json", "--audit", "0").stdout)["clients"] if c["name"] == CLIENT][0]["mfa"]
    need(mine["totp_enrolled"] is True and mine["totp_pending"] is False, "after activation: %s" % mine)
    return ("%d-line QR block that decodes to the URI printed above it, pending until the current code of that very URI's secret; "
            "a wrong code left it pending, the right one activated it" % len(blocks))


def scenario_pin():
    """check_luci_pin_write_only, up to a PIN set and factor pin chosen; the shell side starts
    the agent and unlocks with it."""
    PIN = "07310528"
    # The stand-in in front of the real openwrt-mcp records what it was run with, never the PIN.
    open(SHIM_LOG, "w").close()

    def shim_calls():
        out = []
        for line in open(SHIM_LOG).read().splitlines():
            argv, _, sha = line.partition("\t")
            out.append((argv, sha))
        return out

    # a PIN that is not 4 to 8 digits, or not typed twice the same, is refused and writes nothing
    for pin, again, why in (("123", "123", "3 digits"), ("123456789", "123456789", "9 digits"), ("12ab", "12ab", "letters"),
                            ("12 34", "12 34", "a space"), ("+1234", "+1234", "a sign"), ("", "", "empty"),
                            ("4821", "4822", "not the same twice"), ("4821", "", "no confirmation"),
                            ("١٢٣٤", "١٢٣٤", "digits of another script")):
        r, text = ubus("set_pin", {"pin": pin, "again": again})
        need(r.get("ok") is False, "set_pin took a PIN with %s" % why)
        need(not pin or pin not in r.get("error", ""), "the refusal repeats the PIN")
        need(not any("pin set" in a for a, _ in shim_calls()), "a PIN with %s reached openwrt-mcp" % why)
        need(status()["pin_set"] is False, "pin_set after a PIN with %s" % why)
        need(not os.path.exists("/etc/openwrt-mcp/pin") or CLIENT not in open("/etc/openwrt-mcp/pin").read(), "a PIN with %s was stored" % why)
    # and a factor that needs a PIN cannot be chosen while none exists
    r, _ = ubus("set_factor", {"factor": "pin", "window": "15m", "max_failures": 5, "lockout": "15m"})
    need(r.get("ok") is False, "set_factor pin was accepted with no PIN set")
    need(uci_get("hermes.security.factor") in ("", "none"), "hermes.security.factor is " + uci_get("hermes.security.factor"))

    # the PIN goes in; the process list is watched while it does, over several writes
    watch = ProcessWatch([PIN])
    watch.start()
    texts = []
    try:
        for _ in range(4):
            r, text = ubus("set_pin", {"pin": PIN, "again": PIN})
            need(r.get("ok") is True, "set_pin refused a good PIN: %s" % json.dumps(r))
            texts.append(text)
    finally:
        watch.stop = True
        watch.join(5)
    need(watch.samples > 50, "the process watch looked at %d processes, which measures nothing" % watch.samples)
    need(not watch.hits, "the PIN was in a process's arguments or environment: %s" % sorted(watch.hits)[:2])
    need(all(PIN not in t for t in texts), "set_pin's reply holds the PIN")
    programs_hold_nothing([PIN], "the PIN")

    calls = [c for c in shim_calls() if "pin set" in c[0]]
    need(len(calls) == 4, "openwrt-mcp was run %d times for 4 good PINs" % len(calls))
    want = hashlib.sha256((PIN + "\n").encode()).hexdigest()
    for argv, sha in calls:
        need(PIN not in argv, "the PIN was an argument of openwrt-mcp: %s" % argv)
        need(argv.split() == ["pin", "set", CLIENT], "openwrt-mcp was run as: %s" % argv)
        need(sha == want, "what openwrt-mcp read on stdin is not the PIN (positive control): %s" % sha[:12])

    st = status()
    need(st["pin_set"] is True, "security_status does not say a PIN is set: %s" % json.dumps(st))
    for method in ("status", "logs", "security_status", "chatgpt_login_status"):
        _, text = ubus(method)
        need(PIN not in text, "%s returned the PIN" % method)
    r, text = ubus("set_factor", {"factor": "pin", "window": "15m", "max_failures": 5, "lockout": "15m"})
    need(r.get("ok") is True and PIN not in text, "set_factor pin after the PIN exists: %s" % json.dumps(r))

    # nowhere on the router but openwrt-mcp's own hashed store
    store = open("/etc/openwrt-mcp/pin").read()
    need(re.search(r"^%s pbkdf2-sha256\$\d+\$" % CLIENT, store, re.M) and PIN not in store, "openwrt-mcp's store does not hold a salted hash alone")
    hits = find_in_files([PIN])
    need(not hits, "the PIN was written to: %s" % hits[:3])
    return ("8-digit PIN with a leading zero: nine bad PINs (3 and 9 digits, letters, a space, a sign, empty, mismatch, no confirmation, "
            "another script's digits) wrote nothing and never reached openwrt-mcp; the good one reached it on standard input only "
            "(%d recorded runs, and in no program's arguments or environment, by the recorders and by %d samples of the process "
            "list), in no reply and in no file or log but the hashed store; security_status says pin_set; "
            "set_factor pin refused before the PIN and accepted after" % (len(calls), watch.samples))


def scan():
    """`scan <needle>`: the needle is in no file the router keeps, but openwrt-mcp's hashed store."""
    hits = find_in_files([sys.argv[2]])
    need(not hits, "%s was written to: %s" % ("a secret", hits[:3]))
    return "no file on the router holds it but openwrt-mcp's hashed store"


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    name = argv[1]
    fn = {"check_luci_enrol_shows_qr_and_verifies": scenario_enrol, "check_cli_enrol_prints_qr": scenario_cli,
          "check_luci_pin_write_only": scenario_pin, "code": code, "scan": scan}.get(name)
    if fn is None:
        print("FAIL: no scenario " + name)
        return 2
    try:
        summary = fn()
    except Fail as exc:
        print("FAIL: " + str(exc))
        return 1
    except Exception as exc:  # noqa: BLE001 - a harness error is a failure, with its type
        import traceback
        traceback.print_exc()
        print("FAIL: the scenario broke: %s: %s" % (type(exc).__name__, exc))
        return 1
    if summary is not None:
        print("PASS: " + summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
