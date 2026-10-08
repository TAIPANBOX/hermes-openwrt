#!/usr/bin/env python3
"""The stand-ins and the scenarios behind the Hermes-side checks of gate-unlock.sh.

Run INSIDE the 25.12 rootfs the gate installs the packages into, by the gate's own functions,
and nowhere else. Standard library only, like everything on the router.

What is real and what is stood in for. The gateway is the installed one, started the way procd
starts it (the init's own command and environment, through the wrapper that drops root), with
Telegram enabled: the real Telegram adapter, the real python-telegram-bot, the real plugin
loader, the real openwrt-unlock plugin and the real openwrt-mcp daemon with the policies the
package wrote. What the gate stands in for are the two services across the network:

  Telegram's Bot API  (127.0.0.1:8741)  answers getMe, getUpdates and the rest, and records
                                        every call: what the bot sent, what it deleted.
  the model endpoint  (127.0.0.1:8742)  records every request it is sent, byte for byte, and
                                        answers from a script; it can hold a request open, which
                                        is how the agent is made busy.

Everything below that says "never reaches the model" is asserted on the requests the model
endpoint recorded, and everything that says "never in a log" on the files the gateway, the agent
and openwrt-mcp wrote, with the gateway's logging at DEBUG.

  unlock-harness.py fakes                 serve the two stand-ins and a control port (foreground)
  unlock-harness.py ready                 wait until the gateway is polling the stand-in Telegram
  unlock-harness.py factor <factor>       set the owner's PIN and/or enrol the phone for it
  unlock-harness.py check_<name>          run one scenario; the last line is PASS or FAIL
"""
import base64, calendar, hashlib, hmac, http.server, json, os, re, socketserver, struct, subprocess, sys, threading, time
import urllib.parse, urllib.request

TG_PORT, MODEL_PORT, CTL_PORT = 8741, 8742, 8743
FAKE_DIR = os.environ.get("FAKE_DIR", "/tmp/fakes")
OWNER, STRANGER = 4242, 9999
# The PIN is eight digits, and neither it nor the wrong one is a number that turns up in a log
# by chance; the code is whatever the phone would say now.
PIN, WRONG_PIN = "73918260", "11223344"
TOKEN_FILE = "/etc/hermes-agent/router-mcp.token"
DATA = "/srv/hermes"
CHANGE = {"changes": [{"config": "system", "section": "@system[0]", "option": "description", "value": "changed-by-gate"}]}
# Where a PIN or a code could be written down: the agent's own directory (its logs, its
# conversation database), what the gateway printed, what the daemon printed and audited, and
# every config and state directory of the router.
SCAN_ROOTS = [DATA, "/tmp/svc.log", "/tmp/mcp.log", "/etc/openwrt-mcp", "/etc/config", "/etc/hermes-agent", "/var", "/root"]


# ======================================================================================= stand-ins

class State:
    updates = []
    cond = threading.Condition()
    next_update_id = 100
    next_message_id = 1000
    polls = 0
    bot = {"id": 777000, "is_bot": True, "first_name": "gate", "username": "gate_bot",
           "can_join_groups": True, "can_read_all_group_messages": False, "supports_inline_queries": False}
    model_delay = 0.0
    delete_delay = 0.0
    model_script = []
    model_inflight = 0
    model_calls = 0


S = State()
LOCK = threading.Lock()


def record(name, obj):
    os.makedirs(FAKE_DIR, exist_ok=True)
    with LOCK:
        with open(os.path.join(FAKE_DIR, name), "a") as f:
            f.write(json.dumps(obj) + "\n")


class Base(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def send_json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


class FakeTelegram(Base):
    def do_POST(self):
        raw = self.body()
        path = urllib.parse.urlparse(self.path).path
        if not path.startswith("/bot"):
            return self.send_json({"ok": False, "error_code": 404, "description": "Not Found"}, 404)
        method = path.rsplit("/", 1)[-1]
        ctype = self.headers.get("Content-Type", "")
        try:
            params = json.loads(raw) if raw and "json" in ctype else dict(urllib.parse.parse_qsl(raw.decode("utf-8", "replace")))
        except Exception:
            params = {"_unparsed": raw.decode("utf-8", "replace")[:300]}
        started = time.time()
        if method == "getMe":
            return self.send_json({"ok": True, "result": S.bot})
        if method == "getUpdates":
            S.polls += 1
            timeout = min(float(params.get("timeout") or 1), 3.0)
            offset = int(params.get("offset") or 0)
            deadline = time.time() + timeout
            with S.cond:
                while True:
                    S.updates = [u for u in S.updates if u["update_id"] >= offset]
                    pending = list(S.updates)
                    if pending or time.time() >= deadline:
                        break
                    S.cond.wait(timeout=max(0.05, deadline - time.time()))
            return self.send_json({"ok": True, "result": pending})
        if method == "deleteMessage" and S.delete_delay:
            time.sleep(S.delete_delay)
        if method != "setMyCommands":
            record("tg_calls.jsonl", {"t": started, "t_done": time.time(), "method": method, "params": params})
        if method in ("sendMessage", "sendPhoto", "sendDocument", "sendVoice", "sendAudio", "editMessageText"):
            with S.cond:
                S.next_message_id += 1
                mid = S.next_message_id
            chat = params.get("chat_id")
            try:
                chat = int(chat)
            except Exception:
                pass
            return self.send_json({"ok": True, "result": {"message_id": mid, "date": int(time.time()),
                                  "chat": {"id": chat, "type": "private"}, "from": S.bot, "text": params.get("text", "")}})
        if method == "getWebhookInfo":
            return self.send_json({"ok": True, "result": {"url": "", "has_custom_certificate": False, "pending_update_count": 0}})
        if method == "getMyCommands":
            return self.send_json({"ok": True, "result": []})
        if method == "getChat":
            return self.send_json({"ok": True, "result": {"id": params.get("chat_id"), "type": "private"}})
        return self.send_json({"ok": True, "result": True})

    do_GET = do_POST


def sse(obj):
    return ("data: " + json.dumps(obj) + "\n\n").encode()


class FakeModel(Base):
    def do_POST(self):
        raw = self.body()
        path = urllib.parse.urlparse(self.path).path
        try:
            req = json.loads(raw)
        except Exception:
            req = {"_unparsed": raw.decode("utf-8", "replace")}
        record("model_requests.jsonl", {"t": time.time(), "path": path, "body": req})
        with LOCK:
            S.model_calls += 1
            S.model_inflight += 1
        try:
            if S.model_delay:
                time.sleep(S.model_delay)
            if not path.endswith("/chat/completions"):
                return self.send_json({"error": {"message": "not found: " + path}}, 404)
            reply = S.model_script.pop(0) if S.model_script else {"text": "ok"}
            msg, finish = {"role": "assistant", "content": reply.get("text")}, "stop"
            if reply.get("tool_call"):
                tc = reply["tool_call"]
                msg = {"role": "assistant", "content": None, "tool_calls": [{
                    "id": "call_%d" % S.model_calls, "type": "function",
                    "function": {"name": tc["name"], "arguments": json.dumps(tc.get("arguments", {}))}}]}
                finish = "tool_calls"
            usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
            if req.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                base = {"id": "chatcmpl-gate", "object": "chat.completion.chunk", "created": int(time.time()), "model": req.get("model", "gate")}
                delta = {"role": "assistant"}
                if msg.get("content") is not None:
                    delta["content"] = msg["content"]
                if msg.get("tool_calls"):
                    delta["tool_calls"] = [dict(tc, index=i) for i, tc in enumerate(msg["tool_calls"])]
                try:
                    self.wfile.write(sse(dict(base, choices=[{"index": 0, "delta": delta, "finish_reason": None}])))
                    self.wfile.write(sse(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": finish}], usage=usage)))
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            return self.send_json({"id": "chatcmpl-gate", "object": "chat.completion", "created": int(time.time()),
                                   "model": req.get("model", "gate"),
                                   "choices": [{"index": 0, "message": msg, "finish_reason": finish}], "usage": usage})
        finally:
            with LOCK:
                S.model_inflight -= 1

    def do_GET(self):
        return self.send_json({"data": [{"id": "gate", "object": "model"}]})


class Control(Base):
    def do_POST(self):
        raw = self.body()
        path = urllib.parse.urlparse(self.path).path
        args = json.loads(raw) if raw else {}
        if path == "/say":
            with S.cond:
                S.next_update_id += 1
                S.next_message_id += 1
                uid, mid = S.next_update_id, S.next_message_id
                chat_type = args.get("chat_type", "private")
                user = int(args.get("user_id", OWNER))
                chat = int(args.get("chat_id", user if chat_type == "private" else -100500))
                msg = {"message_id": mid, "date": int(time.time()), "chat": {"id": chat, "type": chat_type},
                       "from": {"id": user, "is_bot": False, "first_name": "someone"}, "text": args["text"]}
                if chat_type != "private":
                    msg["chat"]["title"] = "a group"
                if args["text"].startswith("/"):
                    cmd = args["text"].split()[0]
                    msg["entities"] = [{"type": "bot_command", "offset": 0, "length": len(cmd)}]
                if args.get("edit_of"):
                    # An edit of an earlier message: same message_id, an edit_date, and Telegram
                    # delivers it as edited_message rather than message.
                    msg["message_id"] = mid = int(args["edit_of"])
                    msg["edit_date"] = int(time.time())
                    S.updates.append({"update_id": uid, "edited_message": msg})
                else:
                    S.updates.append({"update_id": uid, "message": msg})
                S.cond.notify_all()
            return self.send_json({"update_id": uid, "message_id": mid, "chat_id": chat})
        if path == "/set":
            for key in ("model_delay", "delete_delay"):
                if key in args:
                    setattr(S, key, float(args[key]))
            if "model_script" in args:
                S.model_script = list(args["model_script"])
            return self.send_json({"ok": True})
        return self.send_json({"error": "unknown"}, 404)

    def do_GET(self):
        if urllib.parse.urlparse(self.path).path == "/state":
            return self.send_json({"polls": S.polls, "model_inflight": S.model_inflight, "model_calls": S.model_calls})
        return self.send_json({"error": "unknown"}, 404)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def serve():
    for port, handler in ((TG_PORT, FakeTelegram), (MODEL_PORT, FakeModel), (CTL_PORT, Control)):
        threading.Thread(target=Server(("127.0.0.1", port), handler).serve_forever, daemon=True).start()
    print("stand-ins up", flush=True)
    while True:
        time.sleep(3600)


# =========================================================================================== helpers

class Fail(Exception):
    pass


def need(cond, message):
    if not cond:
        raise Fail(message)


def ctl(path, body=None):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (CTL_PORT, path),
                                 None if body is None else json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode())


def say(text, **kw):
    return ctl("/say", dict(kw, text=text))


def state():
    return ctl("/state")


def jsonl(name):
    try:
        with open(os.path.join(FAKE_DIR, name)) as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []


def bot_sent():
    """The texts the bot sent, minus the home-channel notice Hermes adds to a first reply."""
    return [c["params"].get("text", "") for c in jsonl("tg_calls.jsonl")
            if c["method"] == "sendMessage" and not c["params"].get("text", "").startswith("\U0001F4EC")]


def deleted():
    return [(str(c["params"].get("chat_id")), str(c["params"].get("message_id"))) for c in jsonl("tg_calls.jsonl") if c["method"] == "deleteMessage"]


def wait_for(predicate, what, timeout=40.0, every=0.25):
    end = time.time() + timeout
    while time.time() < end:
        got = predicate()
        if got:
            return got
        time.sleep(every)
    raise Fail("timed out after %ds waiting for %s" % (timeout, what))


def settle(seconds=2.5):
    """Nothing more arrives: the bot's sends and the model's requests stop changing."""
    last, since = None, time.time()
    while time.time() - since < seconds:
        now = (len(jsonl("tg_calls.jsonl")), len(jsonl("model_requests.jsonl")))
        if now != last:
            last, since = now, time.time()
        time.sleep(0.25)


def answered(fragment, after=0):
    """The nth-or-later bot message that holds `fragment`."""
    def look():
        for text in bot_sent()[after:]:
            if fragment in text:
                return text
    return look


def mcp(tool, args=None):
    """(allowed, text), as the model's own token would be answered."""
    token = open(TOKEN_FILE).read().strip()
    r = subprocess.run(["python3", "/tmp/mcpcall.py", token, tool, json.dumps(args or {})], capture_output=True, text=True, timeout=60)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def locked():
    """True while changes need the unlock. ubus_call on a method that is not on the read list
    reaches the change policy: refused for the second factor when locked, and when open it is
    let through to ubus, which the container has no answer for."""
    ok, text = mcp("ubus_call", {"object": "gate", "method": "noop"})
    if ok:
        return False
    if "second factor" in text:
        return True
    if "Command failed" in text or "Not found" in text:
        return False
    raise Fail("an unexpected answer to a probe change: " + text[:160])


def desc():
    return subprocess.run(["uci", "-q", "get", "system.@system[0].description"], capture_output=True, text=True).stdout.strip()


def totp_secret():
    return open("/tmp/totp.secret").read().strip()


def totp(secret, at=None):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    h = hmac.new(key, struct.pack(">Q", int((at or time.time()) // 30)), hashlib.sha1).digest()
    o = h[-1] & 15
    return "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** 6)


def wrong_code(real):
    return "%06d" % ((int(real) + 111111) % 10 ** 6)


def audit():
    try:
        with open("/etc/openwrt-mcp/audit.jsonl") as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []


def files_under(roots):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirs, names in os.walk(root, followlinks=False):
            for name in names:
                path = os.path.join(dirpath, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                yield path


def whole_token(needle):
    return re.compile(rb"(?<![0-9])" + re.escape(needle.encode()) + rb"(?![0-9])")


def find_in_files(needles, roots=SCAN_ROOTS):
    """(path, context) for every file that holds one of the needles as a whole run of digits.
    Binary files count: the conversation database is one."""
    patterns = [(n, whole_token(n)) for n in needles]
    hits = []
    for path in files_under(roots):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        for needle, pattern in patterns:
            m = pattern.search(data)
            if m:
                ctx = data[max(0, m.start() - 40):m.end() + 20].decode("utf-8", "replace").replace("\n", " ")
                hits.append((path, ctx))
    return hits


def model_text_with(needles):
    """What each request the model endpoint recorded says, flattened: every string in it."""
    out = []
    for req in jsonl("model_requests.jsonl"):
        blob = json.dumps(req["body"], ensure_ascii=False)
        for needle in needles:
            if whole_token(needle).search(blob.encode()):
                out.append((req["path"], needle))
    return out


def chat_requests():
    return [r for r in jsonl("model_requests.jsonl") if r["path"].endswith("/chat/completions")]


def last_user_texts():
    out = []
    for req in chat_requests():
        for m in req["body"].get("messages", []):
            if m.get("role") == "user":
                out.append(m.get("content") if isinstance(m.get("content"), str) else json.dumps(m.get("content")))
    return out


def gateway_is_wired():
    log = open(os.path.join(DATA, "logs", "agent.log")).read()
    need("Wired native handlers from plugin 'openwrt-unlock'" in log,
         "the Telegram handler of the plugin was never wired, so the first line of defence is missing")


def no_trace(needles, what):
    """The needles are in no model request and in no file the router keeps."""
    bad = model_text_with(needles)
    need(not bad, "%s reached the model: %s" % (what, bad[:2]))
    hits = find_in_files(needles)
    need(not hits, "%s was written down: %s" % (what, "; ".join("%s: ...%s..." % h for h in hits[:3])))


# ===================================================================================== setup steps

def run(cmd, stdin=None, check=True):
    r = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise Fail("%s failed: %s" % (" ".join(cmd[:3]), (r.stdout + r.stderr).strip()[-200:]))
    return r


def set_factor(factor):
    if factor in ("pin", "pin+totp"):
        run(["openwrt-mcp", "pin", "set", "hermes-main"], stdin=PIN + "\n")
    if factor in ("totp", "pin+totp"):
        out = run(["openwrt-mcp", "mfa", "enrol", "hermes-main", "--json"]).stdout
        with open("/tmp/totp.secret", "w") as f:
            f.write(json.loads(out)["secret"])


def ready():
    wait_for(lambda: state()["polls"] >= 2, "the gateway to poll the stand-in Telegram", timeout=240, every=1.0)
    # the plugin's own line must be in the log before anything is asserted about it
    wait_for(lambda: os.path.exists(os.path.join(DATA, "logs", "agent.log"))
             and "Connected to Telegram" in open(os.path.join(DATA, "logs", "agent.log")).read() + open("/tmp/svc.log").read(),
             "the Telegram adapter to connect", timeout=60, every=1.0)


def unlock(text, expect="open until", after=None):
    """The owner sends `text`; returns the bot's answer."""
    n = len(bot_sent()) if after is None else after
    say(text)
    return wait_for(answered(expect, n), "the bot to answer '%s'" % expect, timeout=30)


# ======================================================================================== scenarios

def check_pin_alone_unlocks():
    gateway_is_wired()
    need(locked(), "changes were open before anything was sent")
    reply = unlock("/unlock " + PIN)
    need(not locked(), "the right PIN did not open changes: " + reply)
    ok, text = mcp("uci_apply", CHANGE)
    need(ok and desc() == "changed-by-gate", "a change was refused inside the window: " + text[:160])
    mcp("uci_confirm")
    say("/lock")
    wait_for(lambda: locked(), "the window to close", timeout=15)
    # and a wrong PIN opens nothing
    n = len(bot_sent())
    say("/unlock " + WRONG_PIN)
    wait_for(answered("Refused", n), "the refusal of a wrong PIN", timeout=20)
    need(locked(), "a wrong PIN opened changes")
    no_trace([PIN, WRONG_PIN], "the PIN")
    return "factor pin: /unlock <PIN> opened changes, a change went through, /lock closed them, a wrong PIN opened nothing"


def check_code_alone_unlocks():
    gateway_is_wired()
    secret = totp_secret()
    need(locked(), "changes were open before anything was sent")
    n = len(bot_sent())
    say("/unlock " + wrong_code(totp(secret)))
    wait_for(answered("Refused", n), "the refusal of a wrong code", timeout=20)
    need(locked(), "a wrong code opened changes")
    code = totp(secret)
    reply = unlock("/unlock " + code)
    need(not locked(), "the current code did not open changes: " + reply)
    ok, text = mcp("uci_apply", CHANGE)
    need(ok, "a change was refused inside the window: " + text[:160])
    mcp("uci_confirm")
    no_trace([code], "the code")
    return "factor totp: a wrong code opened nothing, the current code opened changes and a change went through"


def check_pin_and_code_both_required():
    gateway_is_wired()
    secret = totp_secret()
    code = totp(secret)
    for what, text in (("a right PIN with a wrong code", "/unlock %s %s" % (PIN, wrong_code(code))),
                       ("a wrong PIN with the right code", "/unlock %s %s" % (WRONG_PIN, code))):
        n = len(bot_sent())
        say(text)
        wait_for(answered("Refused", n), "the refusal of " + what, timeout=20)
        need(locked(), what + " opened changes")
    # one factor alone is a message that does not fit what this router asks for, and it is not
    # counted against the five either
    n = len(bot_sent())
    say("/unlock " + PIN)
    wait_for(answered("PIN and then the 6-digit code", n), "the hint for a PIN alone", timeout=20)
    need(locked(), "a PIN alone opened changes")
    reply = unlock("/unlock %s %s" % (PIN, totp(secret)))
    need(not locked(), "the PIN with the current code did not open changes: " + reply)
    no_trace([PIN, WRONG_PIN, code], "the PIN or the code")
    return "factor pin+totp: a right PIN with a wrong code, a wrong PIN with a right code and a PIN alone opened nothing; both right opened changes"


def check_pin_stored_as_slow_hash():
    gateway_is_wired()
    path = "/etc/openwrt-mcp/pin"
    need(os.path.exists(path), "no PIN file after the PIN was set")
    st = os.stat(path)
    need(st.st_uid == 0 and (st.st_mode & 0o777) == 0o600, "the PIN file is %o owned by uid %d, not 0600 root" % (st.st_mode & 0o777, st.st_uid))
    records = [l for l in open(path).read().splitlines() if l.strip() and not l.startswith("#")]
    need(len(records) == 1, "expected one PIN record, found %d" % len(records))
    client, _, rest = records[0].partition(" ")
    need(client == "hermes-main", "the PIN record is for %r" % client)
    fields = rest.strip().split("$")
    need(len(fields) == 4 and fields[0] == "pbkdf2-sha256", "the PIN is not stored as a pbkdf2-sha256 record: %s" % rest[:40])
    iterations, salt, digest = int(fields[1]), fields[2], fields[3]
    need(iterations >= 100000, "the PIN hash takes %d iterations, which is not slow" % iterations)
    need(len(salt) >= 16 and len(digest) >= 40, "the salt or the digest is too short to be salted and a hash")
    need(PIN not in rest, "the PIN is in its own record")
    # the same PIN for a second client gets another salt, so equal PINs do not look equal
    run(["openwrt-mcp", "pin", "set", "hermes-other"], stdin=PIN + "\n")
    other = [l for l in open(path).read().splitlines() if l.startswith("hermes-other ")]
    need(len(other) == 1 and other[0].split(" ", 1)[1].split("$")[2] != salt, "two clients with one PIN share a salt")
    # and a PIN used through the chat is written nowhere else on the router
    unlock("/unlock " + PIN)
    settle()
    no_trace([PIN], "the PIN")
    return "pbkdf2-sha256, %d iterations, a %d-character salt, root-only; the PIN is in no other file and in no request" % (iterations, len(salt))


def check_wrong_attempts_lock_out():
    gateway_is_wired()
    secret = totp_secret()
    for i in range(5):
        n = len(bot_sent())
        say("/unlock %s %s" % (WRONG_PIN, totp(secret)))
        wait_for(answered("Refused", n) if i < 4 else answered("", n), "the answer to wrong try %d" % (i + 1), timeout=20)
    # the fifth is told it is the last: unlocking is now closed, even for the right PIN and code
    started = time.time()
    n = len(bot_sent())
    say("/unlock %s %s" % (PIN, totp(secret)))
    reply = wait_for(answered("Unlocking is closed until", n), "the lockout to be reported in the chat", timeout=20)
    need(locked(), "the right PIN and code opened changes after five wrong tries")
    ok, text = mcp("mfa_unlock", {"pin": PIN, "code": totp(secret)})
    m = re.search(r"locked out until (\S+)", text)
    need(not ok and m, "the daemon did not say it is locked out: " + text[:160])
    import datetime
    until = datetime.datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp()
    need(14 * 60 <= until - started <= 15 * 60 + 30, "the lockout lasts %.1f minutes, not fifteen" % ((until - started) / 60))
    need(PIN not in reply, "the answer repeats the PIN")
    no_trace([PIN, WRONG_PIN], "the PIN")
    return "five wrong tries, then the right PIN and code refused in the chat and at the daemon, locked out for %.1f minutes, and the owner told" % ((until - started) / 60)


def check_code_works_once():
    gateway_is_wired()
    secret = totp_secret()
    code = totp(secret)
    unlock("/unlock " + code)
    need(not locked(), "the code did not open changes")
    say("/lock")
    wait_for(lambda: locked(), "the window to close", timeout=15)
    n = len(bot_sent())
    say("/unlock " + code)
    wait_for(answered("already used", n), "the refusal of a code used twice", timeout=20)
    need(locked(), "a code that had been used opened changes again")
    no_trace([code], "the code")
    return "a code opened changes once; the same code a second time was refused and opened nothing"


def check_unlock_window_ends():
    gateway_is_wired()
    unlock("/unlock " + PIN)
    need(not locked(), "the PIN did not open changes")
    # the gate configured a window of five seconds
    time.sleep(1)
    need(not locked(), "the window closed early")
    wait_for(lambda: locked(), "the window to end by itself", timeout=15, every=0.5)
    return "changes opened for a five second window and were refused again when it ran out, with nobody sending /lock"


def check_lock_closes_at_once():
    gateway_is_wired()
    unlock("/unlock " + PIN)
    need(not locked(), "the PIN did not open changes")
    n = len(bot_sent())
    say("/lock")
    reply = wait_for(answered("Locked", n), "the answer to /lock", timeout=20)
    need(locked(), "changes were still open after /lock")
    n = len(bot_sent())
    say("/lock")
    wait_for(answered("Already locked", n), "the answer to /lock when already locked", timeout=20)
    return "/lock closed an open window at once (%r), and said so when there was nothing to close" % reply[:40]


def check_unlock_message_deleted_and_never_reaches_model():
    gateway_is_wired()
    secret = totp_secret()
    code = totp(secret)
    calls_before = state()["model_calls"]
    ctl("/set", {"delete_delay": 2.5})
    sent = say("/unlock %s %s" % (PIN, code))
    reply = wait_for(answered("open until"), "the bot to say it opened", timeout=30)
    mid = str(sent["message_id"])
    need((str(sent["chat_id"]), mid) in deleted(), "the bot did not delete the message from the chat")
    # "delete first": the daemon heard of it only after the delete call came back
    gone = [c for c in jsonl("tg_calls.jsonl") if c["method"] == "deleteMessage" and str(c["params"].get("message_id")) == mid][0]
    asked = [a for a in audit() if a.get("tool") == "mfa_unlock"]
    need(asked, "openwrt-mcp has no record of an unlock")
    stamp = calendar.timegm(time.strptime(asked[-1]["time"], "%Y-%m-%dT%H:%M:%SZ"))
    need(stamp + 1.0 >= gone["t_done"], "the daemon was asked at %.1f, before the delete came back at %.1f" % (stamp, gone["t_done"]))
    need(PIN not in reply and code not in reply, "the bot's answer repeats the PIN or the code")
    settle()
    need(state()["model_calls"] == calls_before, "the message caused a request to the model")
    no_trace([PIN, code], "the PIN or the code")
    # the same chat still reaches the model, so the silence above is not a dead gateway
    say("what time is it")
    wait_for(lambda: state()["model_calls"] > calls_before, "an ordinary message to reach the model", timeout=40)
    ctl("/set", {"delete_delay": 0})
    return "deleted from the chat before the daemon was asked, answered with the outcome only, no request to the model, in no file; an ordinary message still reaches the model"


def check_edited_unlock_never_reaches_model():
    """An ordinary message edited afterwards into an /unlock: Telegram sends the edit as a
    separate kind of update, which a handler that looks only at new messages never sees."""
    gateway_is_wired()
    calls_before = state()["model_calls"]
    sent = say("good evening")
    wait_for(lambda: state()["model_calls"] > calls_before, "the first message to reach the model", timeout=40)
    settle()
    say("/unlock " + PIN, edit_of=sent["message_id"])
    settle(6.0)
    no_trace([PIN], "a PIN written into an edited message")
    need((str(sent["chat_id"]), str(sent["message_id"])) in deleted(),
         "the message edited into an /unlock was not deleted from the chat")
    return "a message edited into /unlock <PIN> was deleted, and the PIN reached neither the model nor a file"


def busy_turn(mode, mixed):
    """Start a turn that the model endpoint holds open, then say `mixed` while it runs."""
    n = len(bot_sent())
    say("/busy " + mode)
    wait_for(answered("Busy input mode set to *`%s`*" % mode, n), "the busy mode to change", timeout=20)
    ctl("/set", {"model_delay": 8})
    calls = state()["model_calls"]
    say("please look into the router for me")
    wait_for(lambda: state()["model_inflight"] >= 1 and state()["model_calls"] > calls, "the agent to be in the middle of answering", timeout=40)
    say(mixed)
    wait_for(lambda: state()["model_inflight"] == 0, "the held request to finish", timeout=60)
    ctl("/set", {"model_delay": 0})
    settle(4.0)


def check_unlock_while_busy_never_reaches_model():
    gateway_is_wired()
    # 1. the unlock itself, sent while the agent is busy: the first line takes it
    n = len(bot_sent())
    say("/busy interrupt")
    wait_for(answered("Busy input mode set to", n), "the busy mode to be set", timeout=20)
    ctl("/set", {"model_delay": 6})
    calls = state()["model_calls"]
    say("please look into the router for me")
    wait_for(lambda: state()["model_inflight"] >= 1 and state()["model_calls"] > calls, "the agent to be busy", timeout=40)
    n = len(bot_sent())
    sent = say("/unlock " + PIN)
    wait_for(answered("open until", n), "the bot to answer an unlock sent while it is busy", timeout=20)
    need(state()["model_inflight"] >= 1, "the agent was not busy any more, so this did not measure the busy path")
    need((str(sent["chat_id"]), str(sent["message_id"])) in deleted(), "an unlock sent while the agent was busy was not deleted")
    need(not locked(), "an unlock sent while the agent was busy did not open changes")
    wait_for(lambda: state()["model_inflight"] == 0, "the held request to finish", timeout=40)
    ctl("/set", {"model_delay": 0})
    settle()
    no_trace([PIN], "the PIN")
    # 2. what slips past the first two lines: a PIN on a line of its own inside a longer message.
    #    The adapter steers, redirects or queues it into the run, and only the request to the
    #    model can still stop it, in each of the three ways it is told to behave while busy.
    removed = []
    for mode in ("interrupt", "steer", "queue"):
        before = len(chat_requests())
        busy_turn(mode, "wait, one more thing\n%s\nthat is all" % PIN)
        mine = chat_requests()[before:]
        need(mine, "mode %s: the agent made no request at all, so the message was not measured" % mode)
        text = "\n".join(json.dumps(r["body"]) for r in mine)
        need(PIN not in text, "mode %s: the PIN reached the model on a line of its own" % mode)
        need(any("removed here" in t for t in last_user_texts()[-6:]) or "removed here" in text,
             "mode %s: the message never reached the model, so nothing was scrubbed and nothing measured" % mode)
        removed.append(mode)
    need(not model_text_with([PIN]), "the PIN is in a request to the model")
    return ("an /unlock sent while the agent was busy was deleted and opened changes, in no request; a PIN inside a longer message, "
            "sent while busy in modes %s, reached the model only as the placeholder" % ", ".join(removed))


def check_bare_code_is_an_unlock_attempt():
    gateway_is_wired()
    secret = totp_secret()
    calls = state()["model_calls"]
    code = totp(secret)
    n = len(bot_sent())
    sent = say("%s %s" % (PIN, code))
    reply = wait_for(answered("open until", n), "a bare PIN and code to be treated as /unlock", timeout=30)
    need((str(sent["chat_id"]), str(sent["message_id"])) in deleted(), "the bare message was not deleted")
    need(not locked(), "the bare PIN and code did not open changes")
    # a bare number that is not what this router asks for: still held back, not counted, hint given
    n = len(bot_sent())
    sent2 = say("%s" % PIN)
    wait_for(answered("PIN and then the 6-digit code", n), "the hint for a bare PIN", timeout=20)
    need((str(sent2["chat_id"]), str(sent2["message_id"])) in deleted(), "the bare PIN was not deleted")
    settle()
    need(state()["model_calls"] == calls, "a bare PIN or code reached the model")
    no_trace([PIN, code], "the PIN or the code")
    # the control: an ordinary message is not held back
    say("how is the weather")
    wait_for(lambda: state()["model_calls"] > calls, "an ordinary message to reach the model", timeout=40)
    return "a bare PIN and code opened changes exactly as /unlock does, a bare PIN was held back and deleted, neither reached the model; an ordinary message did"


def check_secret_in_no_log():
    gateway_is_wired()
    secret = totp_secret()
    code = totp(secret)
    log = open(os.path.join(DATA, "logs", "agent.log")).read()
    need(log.count(" DEBUG ") > 50, "the gateway is not logging at DEBUG, so nothing below was measured")
    ctl("/set", {"model_delay": 0})
    codes = [code]
    unlock("/unlock %s %s" % (PIN, code))
    n = len(bot_sent())
    say("/lock")
    wait_for(answered("Locked", n), "/lock", timeout=20)
    n = len(bot_sent())
    say("/unlock %s %s" % (WRONG_PIN, wrong_code(code)))
    wait_for(answered("Refused", n), "a refusal", timeout=20)
    n = len(bot_sent())
    say("%s %s" % (PIN, wrong_code(code)))
    wait_for(answered("Refused", n), "a bare refusal", timeout=20)
    n = len(bot_sent())
    say("/unlock " + PIN)
    wait_for(answered("PIN and then the 6-digit code", n), "a hint", timeout=20)
    # while the agent is busy. (A PIN on a line of its own inside a longer message is not here: it
    # is removed from the request to the model, but Hermes logs and stores what the owner wrote.)
    ctl("/set", {"model_delay": 6})
    calls = state()["model_calls"]
    say("please look into the router for me")
    wait_for(lambda: state()["model_inflight"] >= 1 and state()["model_calls"] > calls, "the agent to be busy", timeout=40)
    n = len(bot_sent())
    say("/unlock %s %s" % (PIN, totp(secret)))
    wait_for(lambda: len(bot_sent()) > n, "an answer while busy", timeout=20)
    wait_for(lambda: state()["model_inflight"] == 0, "the held request to finish", timeout=40)
    ctl("/set", {"model_delay": 0})
    settle(4.0)
    needles = [PIN, WRONG_PIN, code, wrong_code(code)]
    hits = find_in_files(needles)
    # the daemon's own audit file is among the roots; name it in the failure when it is the one
    need(not hits, "a PIN or code is in a log: " + "; ".join("%s: ...%s..." % h for h in hits[:3]))
    logs = [os.path.join(DATA, "logs", n) for n in ("agent.log", "gateway.log", "errors.log")]
    need(all(os.path.exists(p) for p in logs[:2]), "the gateway and agent logs are missing, so nothing was measured")
    need(os.path.getsize("/etc/openwrt-mcp/audit.jsonl") > 0 and any(a.get("tool") == "mfa_unlock" for a in audit()),
         "openwrt-mcp's audit file holds no unlock, so it was not measured")
    return "at DEBUG, after an unlock, a lock, wrong tries, bare tries, a hint, and an unlock while busy: neither the PIN nor a code is in agent.log, gateway.log, errors.log, the gateway's output, openwrt-mcp's output or its audit file, nor anywhere else under the data directory or /etc"


def check_unlock_refused_in_group():
    gateway_is_wired()
    calls = state()["model_calls"]
    n = len(bot_sent())
    sent = say("/unlock " + PIN, chat_type="group")
    reply = wait_for(answered("private chat", n), "the answer for a group", timeout=20)
    need(locked(), "an /unlock sent in a group opened changes")
    need(PIN not in reply, "the answer repeats the PIN")
    n = len(bot_sent())
    say(PIN, chat_type="group")
    wait_for(answered("private chat", n), "the answer for a bare PIN in a group", timeout=20)
    settle()
    need(state()["model_calls"] == calls, "a message sent in a group reached the model")
    need(locked(), "changes were opened from a group")
    # not counted either: five of them, then the owner in private is not locked out
    for _ in range(5):
        say("/unlock " + WRONG_PIN, chat_type="group")
    settle()
    unlock("/unlock " + PIN)
    need(not locked(), "the owner could not unlock in private after five tries in a group, so they were counted")
    no_trace([PIN, WRONG_PIN], "the PIN")
    return "an /unlock and a bare PIN in a group opened nothing, were answered with the private chat, reached no model, and were not counted against the owner"


def check_unlock_only_from_allowlist():
    gateway_is_wired()
    calls = state()["model_calls"]
    sent_before = len(jsonl("tg_calls.jsonl"))
    attempts_before = len([a for a in audit() if a.get("tool") == "mfa_unlock"])
    for text in ("/unlock " + PIN, "/unlock " + WRONG_PIN, PIN, "/lock"):
        say(text, user_id=STRANGER)
    for _ in range(5):
        say("/unlock " + WRONG_PIN, user_id=STRANGER)
    settle(4.0)
    need(locked(), "someone outside the allowlist opened changes")
    mine = jsonl("tg_calls.jsonl")[sent_before:]
    need(not [c for c in mine if c["method"] in ("sendMessage", "deleteMessage")],
         "the bot answered or deleted something for someone outside the allowlist: %s" % [c["method"] for c in mine][:4])
    need(len([a for a in audit() if a.get("tool") == "mfa_unlock"]) == attempts_before, "an attempt from outside the allowlist reached the daemon")
    need(state()["model_calls"] == calls, "a message from outside the allowlist reached the model")
    # no attempt counted against the owner: the right PIN still opens
    unlock("/unlock " + PIN)
    need(not locked(), "the owner was locked out by someone else's tries")
    return "ten messages from a stranger (nine of them /unlock or a bare PIN) were dropped without an answer, a delete, a call to the daemon or a request to the model, and counted for nothing"


def check_scheduled_job_cannot_change():
    gateway_is_wired()
    # an open window: the owner unlocks, the way they would
    unlock("/unlock " + PIN)
    need(not locked(), "the PIN did not open changes")
    # The tool by its own name: since 0.21.5-r10 the bridge turns upstream's tool search off, so
    # every openwrt tool is offered directly and there is no tool_call bridge to go through.
    change = {"name": "mcp__openwrt__uci_apply", "arguments": CHANGE}
    # 1. the same change, asked for by the agent in the owner's own chat, goes through
    ctl("/set", {"model_script": [{"tool_call": change}, {"text": "done"}]})
    say("please change the router description")
    wait_for(lambda: desc() == "changed-by-gate", "the change asked for in the chat to be applied", timeout=60)
    mcp("uci_confirm")
    run(["uci", "set", "system.@system[0].description=baseline-gate"])
    run(["uci", "commit", "system"])
    need(not locked(), "the window closed before the scheduled job was tried")
    # 2. the same change, asked for by a scheduled job with the window open, is refused
    ctl("/set", {"model_script": [{"tool_call": change}, {"text": "done"}]})
    r = subprocess.run(["sh", "/tmp/run-cron-job.sh"], capture_output=True, text=True, timeout=200)
    need("RESULT" in r.stdout, "the scheduled job did not run: " + (r.stdout + r.stderr)[-300:])
    need(desc() == "baseline-gate", "a scheduled job changed the router while an unlock was open: " + desc())
    tool_results = [m.get("content", "") for req in chat_requests() for m in req["body"].get("messages", []) if m.get("role") == "tool"]
    need(any("scheduled job cannot change the router" in t for t in tool_results), "the job was not refused by the plugin; its tool results: " + " | ".join(t[:120] for t in tool_results[-2:]))
    need(not locked(), "the window closed during the scheduled job, so the refusal was not the window's")
    return "with the window open the same uci_apply changed the router from the owner's chat and was refused for a scheduled job, which was told why"


# ================================================================== the agent is told the window is open

NOTE = "The owner has unlocked router changes until "


def text_of(message):
    content = message.get("content")
    return content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)


def notes_in(requests):
    """Every 'unlocked until HH:MM' note found in a user message of these requests, with the
    message it rides on, so a note in the conversation's history counts as much as a new one."""
    out = []
    for req in requests:
        for m in req["body"].get("messages", []):
            if m.get("role") != "user":
                continue
            for found in re.finditer(re.escape(NOTE) + r"(\d\d:\d\d)", text_of(m)):
                out.append((found.group(1), text_of(m)))
    return out


def shown_note(found):
    """The note, and what follows it, from the first message that carried one, for a failure message;
    built whether or not there was one."""
    return found[0][1][found[0][1].find(NOTE):][:160] if found else ""


def ask(text, timeout=40):
    """The owner says `text` and the agent answers; the requests the model was sent for it.
    The session title is asked for by a request of its own, so a turn may be several."""
    before = len(chat_requests())
    say(text)
    wait_for(lambda: len(chat_requests()) > before, "a request to the model for " + repr(text), timeout=timeout)
    wait_for(lambda: state()["model_inflight"] == 0, "the model to answer " + repr(text), timeout=timeout)
    settle(1.5)
    return chat_requests()[before:]


def check_agent_told_window_is_open():
    gateway_is_wired()
    need(locked(), "changes were open before anything was sent")
    # 1. before any unlock the agent is told nothing of the kind
    need(not notes_in(ask("good morning")), "the agent was told a window is open when none was")
    # 2. after one, the next request carries the line, on the message that asked
    reply = unlock("/unlock " + PIN)
    need(not locked(), "the PIN did not open changes: " + reply)
    shown = re.search(r"open until (\d\d:\d\d)", reply)
    need(shown, "the owner's own answer has no time to compare with: " + reply)
    mine = notes_in(ask("please change the router description"))
    need(mine, "the request after a successful unlock carries no note that the window is open, so the agent is told nothing")
    need(all(t == shown.group(1) for t, _ in mine), "the note's time %s is not the owner's %s" % (mine[0][0], shown.group(1)))
    carrier = mine[0][1]
    need("please change the router description" in carrier, "the note does not ride on the owner's own message")
    need(carrier.count(NOTE) == 1 and len(carrier) - len(carrier.split(NOTE)[0]) < 220, "the note is not one short line: " + carrier[-260:])
    need(PIN not in carrier and "do it now" in carrier, "the note is not what was specified: " + carrier[-260:])
    # 3. a second turn in the same window is told again, the first still in what the conversation replays
    need(notes_in(ask("and one more thing")), "the second turn of the window was not told")
    # 4. /lock: the next request carries no note, nor does what it replays of the earlier turns
    say("/lock")
    wait_for(lambda: locked(), "the window to close", timeout=15)
    stale = notes_in(ask("did that work"))
    need(not stale, "after /lock a request still carries the note (%s)" % shown_note(stale))
    # 5. a window opened again is told again, and wrong tries until the lockout end the telling
    unlock("/unlock " + PIN)
    need(notes_in(ask("one more try")), "a second window was not told to the agent")
    for _ in range(5):
        n = len(bot_sent())
        say("/unlock " + WRONG_PIN)
        wait_for(lambda: len(bot_sent()) > n, "the answer to a wrong try", timeout=20)
    n = len(bot_sent())
    say("/unlock " + PIN)
    wait_for(answered("Unlocking is closed until", n), "the lockout to be reported", timeout=20)
    stale = notes_in(ask("is it still open"))
    need(not stale, "after the lockout a request still carries the note (%s)" % shown_note(stale))
    # 6. what asks the plugin directly: a scheduled job is never told, whatever the window
    probe = (
        "import time, openwrt_unlock as u\n"
        "end = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() + 600))\n"
        "u.note_outcome('mfa_unlock', True, 'unlocked until ' + end, False)\n"
        "got = [u.pre_llm_call(session_id='s1', task_id='t1'), u.pre_llm_call(session_id='cron_job_1'), u.pre_llm_call(task_id='cron:job:1')]\n"
        "u.note_outcome('mfa_lock', True, 'Locked.', False)\n"
        "got.append(u.pre_llm_call(session_id='s1'))\n"
        "print([bool(g) for g in got])\n")
    r = subprocess.run(["python3", "-c", probe], capture_output=True, text=True, timeout=60,
                       env=dict(os.environ, PYTHONPATH="/usr/lib/hermes-agent/site-packages"))
    need(r.stdout.strip() == "[True, False, False, False]",
         "the plugin told a scheduled job, or not a person, or kept telling after a lock: " + (r.stdout + r.stderr).strip()[-200:])
    no_trace([PIN, WRONG_PIN], "the PIN")
    return ("after /unlock the next request carried one line saying changes are open until the time the owner was told, "
            "and not the PIN; /lock, and a lockout, ended it, in the history the request replays too; a scheduled job is never told")


def check_agent_not_told_after_window_ends():
    gateway_is_wired()
    # the gate configured a window of twenty seconds
    unlock("/unlock " + PIN)
    need(notes_in(ask("please change the router description")), "inside the window the agent was not told it is open")
    wait_for(lambda: locked(), "the window to end by itself", timeout=40, every=0.5)
    # the plugin's own clock is the daemon's answer, to the second: let that second pass
    time.sleep(1.5)
    stale = notes_in(ask("is it still open"))
    need(not stale, "after the window ran out a request still carries the note (%s)" % shown_note(stale))
    return "inside a twenty second window the agent was told it was open; once the window ran out, with nobody sending /lock, it was not"


# ======================================================================================== entry point

def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "fakes":
        serve()
        return 0
    if cmd == "ready":
        try:
            ready()
        except Fail as exc:
            print("FAIL: " + str(exc))
            return 1
        print("PASS: the gateway is polling")
        return 0
    if cmd == "factor":
        try:
            set_factor(argv[2])
        except Fail as exc:
            print("FAIL: " + str(exc))
            return 1
        print("PASS: factor set")
        return 0
    fn = globals().get(cmd)
    if not callable(fn) or not cmd.startswith("check_"):
        print("FAIL: no scenario " + cmd)
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
    print("PASS: " + summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
