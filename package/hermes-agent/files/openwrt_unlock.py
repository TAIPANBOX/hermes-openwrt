"""openwrt-unlock: the owner's /unlock and /lock in Telegram, and the walls that keep the
PIN or code from the model, the logs and the conversation.

@decided 2026-10-01 (paraphrased): the unlock happens in the same Telegram chat as the agent;
the message that unlocks is removed from the chat at once and never reaches the model; the
owner chooses the factor (a PIN, a code from an authenticator app, or both); the PIN is 4 to 8
digits; five wrong tries close unlocking for fifteen minutes (openwrt-mcp counts them, not
this file). openwrt-mcp holds the PIN's hash, the code's secret, the window and the count; this
plugin only carries what the owner typed to it, once, and forgets it.

Standard library only. Everything the secret path does is wrapped so that an error DROPS the
message instead of letting it through: Hermes lets a message proceed when a hook raises
(upstream's pre_gateway_dispatch fails open), so nothing here may raise on that path.

Four lines of defence, in the order a message meets them. Each is tested on its own, because
the first can fail to be wired without anyone noticing.

1. A Telegram-native handler (``register_telegram_handler``), placed before every handler the
   adapter has and consuming the update. It sees the message whether or not the agent is
   busy, which the later lines cannot promise: a message sent while a turn runs is steered,
   redirected or queued by the adapter without passing ``pre_gateway_dispatch``.
2. ``pre_gateway_dispatch``, for anything that reaches the gateway without passing line 1.
3. ``llm_request`` middleware: every request to the model is scrubbed of lines that are a PIN,
   a code, or an /unlock, in every user message, whatever path put them there.
4. Log redaction patterns for the /unlock shapes, and the Telegram library's own DEBUG
   logger (which prints each update, text included, before any handler runs) held at INFO.

And, because an open window is root for its length, the plugin refuses a change to the router
from a scheduled job (``pre_tool_call``), which an unlock cannot tell apart from the owner.

The other half of "never shown to the agent": the unlock message is not in the conversation, so
an agent that asked for /unlock sees nothing after it and goes on asking. While a window the
plugin saw opened is still open, ``pre_llm_call`` adds one line to the owner's next message saying
so (never the PIN or the code, which this file does not keep), and the line is taken out of every
request again once the window is over, in the history the request replays too.

@decided 2026-10-22 (the owner's, paraphrased): a high-impact change (a port opened to the
internet, the firewall weakened, VPN routing, DNS or the time servers changed, an open Wi-Fi into a
trusted network, a guard service stopped, a reboot) waits in openwrt-mcp for the owner's approval
of that one change, given in the same chat with the PIN and a code; the card comes from the same
bot, and before the code is asked for, this plugin restates the headline openwrt-mcp wrote, so a
card the agent wrote itself cannot be approved by mistake; one approver; /unlock and approvals go
through a client of the owner's own, whose token only this plugin holds.

How (0.21.5-r16): the wrapper hands the owner's token to the gateway, and ``register`` takes it out
of the environment before any tool can start a process that inherits it. Every 5 s a task asks
openwrt-mcp for the held changes (``action_list``) and sends each new one's card, as openwrt-mcp
wrote it, to the approver's private chat with Approve and Reject buttons. Reject is one tap.
Approve, or /approve <id>, restates the headline and asks for the PIN and the code, which the next
fitting message from the approver carries on the same path as an unlock: deleted first, never
shown to the model, sent once to ``action_approve`` against the hash of that card. The outcome
edits the card and starts a turn for the agent in the chat the change was proposed from, saying
what happened and, for an applied setting, to check the router and confirm it.
"""
from __future__ import annotations

import asyncio
import datetime
import fnmatch
import json
import logging
import os
import re
import sys
import threading
import time
import urllib.request

# Named so that gateway.log, which holds the loggers under hermes_plugins, carries it too.
log = logging.getLogger("hermes_plugins.openwrt_unlock")

FACTORS = ("pin", "totp", "pin+totp")

PIN_DIGITS = (4, 8)
CODE_DIGITS = 6

# Unicode decimal digits count: a phone keyboard can type Arabic-Indic or full-width ones, and
# dropping more is the safe direction. They are turned into ASCII before they go anywhere.
_D = r"\d"
BARE = re.compile(r"^\s*(" + _D + r"{4,8})(?:[ \t,]+(" + _D + r"{6}))?\s*$")
# One line that is, or starts, an /unlock; the optional @botname is Telegram's own form.
UNLOCK_LINE = re.compile(r"^[ \t]*/unlock(?:@\w+)?(?=\s|$)[ \t]*(.*)$", re.IGNORECASE)
LOCK_WHOLE = re.compile(r"^\s*/lock(?:@\w+)?(?=\s|$)", re.IGNORECASE)
# The owner's answer to a held change, by its five-letter id; anything after the id is not read,
# so a PIN typed there by mistake goes nowhere (the message is deleted all the same).
APPROVE_CMD = re.compile(r"^\s*/approve(?:@\w+)?(?=\s|$)[ \t]*([A-Za-z]{5})?", re.IGNORECASE)
REJECT_CMD = re.compile(r"^\s*/reject(?:@\w+)?(?=\s|$)[ \t]*([A-Za-z]{5})?", re.IGNORECASE)
# An /unlock with digits after it, anywhere in a line: what is removed from text that is not
# the owner's own message (a tool's output, an assistant's echo). "/unlock in the private chat",
# which the agent is told to say, has no digits after it and is left alone.
UNLOCK_INLINE = re.compile(r"/unlock(?:@\w+)?[ \t]+" + _D + r"[^\n]*", re.IGNORECASE)

PLACEHOLDER = ("[A message from the owner was removed here: it looked like an unlock PIN or code, "
               "and those are never shown to you. Do not ask the owner to type one in a message. "
               "If a change needs unlocking, tell the owner to send /unlock in the private chat "
               "again once you have finished answering.]")


def _ascii_digits(text: str) -> str:
    return "".join(str(int(c)) if c.isdecimal() else c for c in text)


# ---------------------------------------------------------------------------------- shapes

def classify(text, factor: str, approving: bool = False):
    """What a message is, as far as the secret path cares.

    ``("lock", "")``, ``("unlock", <what follows /unlock>)``, ``("bare", <digits>)``,
    ``("approve", <id>)``, ``("reject", <id>)``, ``("approve_factor", <digits>)`` or None.
    ``approving`` says that the sender was just asked for the PIN and the code of an approval, so a
    bare PIN and code is that answer, whatever the window's factor is. Never raises on a str;
    anything that is not one is the caller's to treat as a secret.
    """
    if not isinstance(text, str):
        raise TypeError("message text is not a string")
    if LOCK_WHOLE.match(text):
        return ("lock", "")
    m = APPROVE_CMD.match(text)
    if m:
        return ("approve", (m.group(1) or "").upper())
    m = REJECT_CMD.match(text)
    if m:
        return ("reject", (m.group(1) or "").upper())
    if approving and BARE.match(text):
        return ("approve_factor", text.strip())
    for line in text.splitlines() or [text]:
        m = UNLOCK_LINE.match(line)
        if m:
            return ("unlock", m.group(1).strip())
    if factor in FACTORS and BARE.match(text):
        return ("bare", text.strip())
    return None


def attempt_for(factor: str, args: str):
    """The arguments to openwrt-mcp's ``mfa_unlock`` for what the owner typed, or None when what
    they typed does not fit the factor. Nothing is sent to the daemon in that case, so a typo
    never counts toward the five."""
    tokens = [t for t in re.split(r"[\s,]+", _ascii_digits(args).strip()) if t]
    if not all(t.isascii() and t.isdigit() for t in tokens):
        return None
    pin_ok = lambda t: PIN_DIGITS[0] <= len(t) <= PIN_DIGITS[1]
    code_ok = lambda t: len(t) == CODE_DIGITS
    if factor == "pin" and len(tokens) == 1 and pin_ok(tokens[0]):
        return {"pin": tokens[0]}
    if factor == "totp" and len(tokens) == 1 and code_ok(tokens[0]):
        return {"code": tokens[0]}
    if factor == "pin+totp" and len(tokens) == 2 and pin_ok(tokens[0]) and code_ok(tokens[1]):
        return {"pin": tokens[0], "code": tokens[1]}
    return None


def hint_for(factor: str) -> str:
    if factor == "pin":
        return "Send /unlock followed by your PIN (4 to 8 digits)."
    if factor == "totp":
        return "Send /unlock followed by the 6-digit code from your authenticator app."
    return "Send /unlock followed by your PIN and then the 6-digit code from your app, with a space between."


# ---------------------------------------------------------------------------- the scrubber

def scrub_text(text: str, *, bare: bool) -> str:
    """``text`` with every line that is a secret replaced by PLACEHOLDER. ``bare`` says whether a
    line of nothing but digits counts (it does in what the owner wrote, not in a tool's output)."""
    if not isinstance(text, str) or not text:
        return text
    if bare:
        text = _drop_stale_notes(text)
    if "/unlock" not in text.lower() and not (bare and re.search(_D + r"{4,}", text)):
        return text
    out = []
    changed = False
    for line in text.split("\n"):
        new = line
        if bare and UNLOCK_LINE.match(new):
            new = PLACEHOLDER  # the owner's own /unlock line, whatever follows it
        elif UNLOCK_INLINE.search(new):
            new = UNLOCK_INLINE.sub(PLACEHOLDER, new)
        elif bare and BARE.match(new):
            new = PLACEHOLDER
        if new != line:
            changed = True
        out.append(new)
    return "\n".join(out) if changed else text


# Blocks inside a user message that are the owner's own words. Anything else (a tool result
# riding in a user message, in Anthropic's format) is left alone.
_TEXT_BLOCKS = ("text", "input_text")


def _scrub_user_content(content, factor: str):
    bare = factor in FACTORS or _approvals_on()
    if isinstance(content, str):
        return scrub_text(content, bare=bare)
    if isinstance(content, list):
        out = []
        for block in content:
            if isinstance(block, str):
                out.append(scrub_text(block, bare=bare))
            elif isinstance(block, dict) and block.get("type") in _TEXT_BLOCKS and isinstance(block.get("text"), str):
                new = scrub_text(block["text"], bare=bare)
                out.append(block if new == block["text"] else dict(block, text=new))
            else:
                out.append(_scrub_other(block))
        return out if any(a is not b for a, b in zip(out, content)) else content
    return content


def _scrub_other(value):
    """Outside the owner's own words only the /unlock form is removed: a line of digits in a
    tool's output is a number, not a PIN."""
    if isinstance(value, str):
        return scrub_text(value, bare=False)
    if isinstance(value, list):
        out = [_scrub_other(v) for v in value]
        return out if any(a is not b for a, b in zip(out, value)) else value
    if isinstance(value, dict):
        out = {k: _scrub_other(v) for k, v in value.items()}
        return out if any(out[k] is not value[k] for k in value) else value
    return value


def _walk(node, factor: str):
    """A copy of ``node`` with its user messages scrubbed, or ``node`` itself when nothing changed."""
    if isinstance(node, list):
        out = [_walk(n, factor) for n in node]
        return out if any(a is not b for a, b in zip(out, node)) else node
    if isinstance(node, dict):
        if node.get("role") == "user":
            new = dict(node)
            changed = False
            for key in ("content", "text", "parts"):
                if key in node:
                    value = node[key]
                    if key == "parts" and isinstance(value, list):
                        # Gemini-style parts: {"text": ...}
                        fixed = [dict(p, text=scrub_text(p["text"], bare=factor in FACTORS or _approvals_on()))
                                 if isinstance(p, dict) and isinstance(p.get("text"), str) else p for p in value]
                        replaced = fixed if any(a != b for a, b in zip(fixed, value)) else value
                    else:
                        replaced = _scrub_user_content(value, factor)
                    if replaced is not value:
                        new[key] = replaced
                        changed = True
            return new if changed else node
        if "role" in node:
            # An assistant's, a tool's or the system's message: only the /unlock-with-digits
            # form goes, and a line of digits stays.
            return _scrub_other(node)
        out = {k: _walk(v, factor) for k, v in node.items()}
        return out if any(out[k] is not node[k] for k in node) else node
    return node


def _everything_a_user_said_replaced(node):
    """The fail-closed fallback: every owner message in the request is the placeholder."""
    if isinstance(node, list):
        return [_everything_a_user_said_replaced(n) for n in node]
    if isinstance(node, dict):
        if node.get("role") == "user":
            new = dict(node)
            for key in ("content", "text", "parts"):
                if key in new:
                    new[key] = PLACEHOLDER if key != "parts" else [{"text": PLACEHOLDER}]
            return new
        return {k: _everything_a_user_said_replaced(v) for k, v in node.items()}
    return node


def llm_request(request=None, **_ignored):
    """Line 3. Called by Hermes for every request it is about to send to the model.

    Returns ``{"request": <copy>}`` when something was removed and None when nothing was. If the
    scrubbing itself fails, every user message in the request becomes the placeholder: Hermes
    sends the request unchanged when middleware errors, so an error here must not mean "send it".
    """
    try:
        factor = _factor()
        if not isinstance(request, dict):
            return None
        fixed = _walk(request, factor)
        if fixed is request:
            return None
        return {"request": fixed, "source": "openwrt-unlock", "reason": "an unlock PIN or code, or an unlock note that no longer holds, was removed"}
    except BaseException:  # noqa: BLE001 - fail closed, see above
        try:
            return {"request": _everything_a_user_said_replaced(request), "source": "openwrt-unlock",
                    "reason": "scrubbing failed; user messages withheld"}
        except BaseException:  # noqa: BLE001
            return {"request": {}, "source": "openwrt-unlock", "reason": "scrubbing failed; request withheld"}


# ----------------------------------------------------------------------------- the daemon

def _factor() -> str:
    value = os.environ.get("HERMES_OPENWRT_FACTOR", "none").strip()
    return value if value in FACTORS else "none"


def _approvals_on() -> bool:
    """Whether a held change can be approved here: the init found someone to approve it."""
    return os.environ.get("HERMES_OPENWRT_APPROVALS", "off").strip() == "on" and _approver() is not None


def _approver():
    """The one Telegram id that approves held changes (hermes.security.approver_id), or None."""
    raw = os.environ.get("HERMES_OPENWRT_APPROVER_ID", "").strip()
    return raw if raw.isdigit() else None


def _client() -> str:
    """The openwrt-mcp client whose window this gateway's owner opens: one gateway, one agent."""
    return os.environ.get("HERMES_OPENWRT_CLIENT", "hermes-main").strip() or "hermes-main"


# The owner's client's token (0.21.5-r16). Taken out of the environment by register(), so a process
# a tool starts later cannot inherit it, and kept here for the calls that are the owner's.
_OWNER_TOKEN = ""


def _take_owner_token() -> None:
    global _OWNER_TOKEN
    token = os.environ.pop("OPENWRT_MCP_OWNER_TOKEN", "").strip()
    # The gateway's sitecustomize took it out of the environment before upstream ran; it is kept there.
    take = getattr(sys.modules.get("sitecustomize"), "take_owner_token", None)
    if callable(take):
        token = (take() or "").strip() or token
    if token:
        _OWNER_TOKEN = token


def _allowed_ids() -> set:
    raw = os.environ.get("TELEGRAM_ALLOWED_USERS", "")
    return {part.strip() for part in raw.split(",") if part.strip() and part.strip() != "*"}


def authorized(user_id) -> bool:
    """Only an id the owner listed. Stricter than the gateway on purpose: someone who may chat
    (paired, or let in by allow_all) still may not try a PIN, so they cannot use up the owner's
    five tries."""
    return user_id is not None and str(user_id) in _allowed_ids()


_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _post(url: str, token: str, body: dict, session=None, timeout: float = 25.0):
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(url, json.dumps(body).encode(), headers)
    # No proxy: this is the router's own loopback, and a proxy in the environment must not see a PIN.
    with _OPENER.open(req, timeout=timeout) as resp:
        raw, sid = resp.read().decode(), resp.headers.get("Mcp-Session-Id")
    for line in raw.splitlines():
        if line.startswith("data:"):
            raw = line[5:].strip()
            break
    return (json.loads(raw) if raw.strip() else None), sid


def _close(url: str, token: str, session) -> None:
    """Ends the session at the daemon, which otherwise keeps every one it was ever asked to open:
    the held changes are asked for every few seconds. Best effort; nothing here holds a secret."""
    if not session:
        return
    try:
        req = urllib.request.Request(url, None, {"Authorization": "Bearer " + token, "Mcp-Session-Id": session},
                                     method="DELETE")
        with _OPENER.open(req, timeout=5) as resp:
            resp.read()
    except Exception:  # noqa: BLE001
        pass


def call_tool(tool: str, arguments: dict, token=None):
    """(answered, text, is_error): one tool of openwrt-mcp, over the HTTP address the gateway
    found it at, as the owner's client: what this plugin asks is the owner's to ask, never the
    agent's. ``answered`` is False when the daemon could not be asked at all; an answer that says
    no is ``(True, text, True)``. Blocking: run it off the event loop."""
    url = os.environ.get("HERMES_OPENWRT_UNLOCK_URL", "").strip()
    token = (token if token is not None else _OWNER_TOKEN).strip()
    if not url or not token:
        return False, "", False
    try:
        _, sid = _post(url, token, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "hermes-unlock", "version": "1"}}})
        _post(url, token, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
        try:
            res, _ = _post(url, token, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                        "params": {"name": tool, "arguments": arguments}}, sid)
        finally:
            _close(url, token, sid)
        result = res["result"]
        text = "".join(c.get("text", "") for c in result.get("content", []))
        return True, text, bool(result.get("isError"))
    except Exception as exc:  # noqa: BLE001 - never lets the arguments (the secret) into a message
        log.warning("openwrt-mcp could not be asked (%s)", type(exc).__name__)
        return False, "", False


_RFC3339 = re.compile(r"\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d{2}:\d{2})")


def _when(text: str):
    """The first RFC 3339 time in the daemon's answer, or None."""
    m = _RFC3339.search(text or "")
    if not m:
        return None
    try:
        return datetime.datetime.fromisoformat(m.group(0).replace("Z", "+00:00"))
    except Exception:  # noqa: BLE001
        return None


def _clock(text: str):
    when = _when(text)
    try:
        return when.astimezone().strftime("%H:%M (%Z, %d %b)") if when else None
    except Exception:  # noqa: BLE001
        return None


def answer_for(tool: str, answered: bool, text: str, is_error: bool, factor: str) -> str:
    """What the owner is told. Built from the daemon's outcome and nothing the owner typed."""
    if not answered:
        return "I could not reach the router's unlock service. Nothing was changed."
    low = text.lower()
    if tool == "mfa_lock":
        rejected = re.search(r"(\d+) held change", low)
        tail = (" %s waiting change(s) were rejected." % rejected.group(1)
                if rejected and rejected.group(1) != "0" else "")
        if low.startswith("already") or "was not open" in low:
            return "Already locked." + tail
        return "Locked. Changes need an unlock again." + tail
    if not is_error and low.startswith("unlocked until"):
        until = _clock(text)
        return ("Changes are open until " + until + ". Send /lock to close them sooner."
                if until else "Changes are open. Send /lock to close them.")
    if "locked out" in low:
        until = _clock(text)
        return ("Too many wrong tries. Unlocking is closed until " + until + "."
                if until else "Too many wrong tries. Unlocking is closed for a while.")
    if "already used" in low and factor == "totp":
        return "That code was already used. Wait for the next one."
    return "Refused. Nothing was unlocked."


# ------------------------------------------------------------------------------ the secret path

async def process(kind: str, args: str, *, user_id, chat_id, private: bool, factor: str, delete, send) -> None:
    """Everything that happens to a message that is, or may be, an unlock attempt, after it has
    been decided that it is one. ``delete`` and ``send`` are coroutines the caller binds to its
    own transport. Never raises: whatever fails, the message has already been consumed."""
    try:
        if not authorized(user_id):
            return  # checks nothing, counts nothing, answers nothing
        if not private:
            with _quiet():
                await delete()  # works only where the bot is an administrator
            await send("/unlock and /lock work only in the private chat with me, where I can delete "
                       "your message. Do not send a PIN or a code here.")
            return
        deleted = False
        try:
            deleted = bool(await delete())
        except Exception as exc:  # noqa: BLE001
            log.warning("could not delete an unlock message (%s)", type(exc).__name__)
        note = "" if deleted else (" I could not delete your message from the chat. Delete it yourself.")
        if factor not in FACTORS:
            await send("No PIN or app code is set up on this router yet, so nothing can be unlocked. "
                       "Set one up first: Services, Hermes Agent, Security in LuCI, or on the router "
                       "`openwrt-mcp pin set hermes-main` or `openwrt-mcp mfa enrol hermes-main --pending`."
                       + note)
            return
        if kind == "lock":
            tool, arguments = "mfa_lock", {"client": _client()}
        else:
            arguments = attempt_for(factor, args)
            if arguments is None:
                await send("That does not look like what this router asks for. " + hint_for(factor) + note)
                return
            arguments["client"] = _client()
            tool = "mfa_unlock"
        answered, text, is_error = await asyncio.to_thread(call_tool, tool, arguments)
        arguments = None  # the secret leaves scope here
        note_outcome(tool, answered, text, is_error)
        await send(answer_for(tool, answered, text, is_error, factor) + note)
    except Exception as exc:  # noqa: BLE001
        log.warning("the unlock path failed (%s); the message was dropped", type(exc).__name__)
        try:
            await send("Something went wrong. Your message was dropped and nothing was unlocked.")
        except Exception:  # noqa: BLE001
            pass


class _quiet:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return True


# ------------------------------------------------------------------- line 2: the gateway hook

SKIP = {"action": "skip", "reason": "openwrt-unlock"}


async def pre_gateway_dispatch(event=None, gateway=None, session_store=None, **_ignored):
    """Line 2. Returns skip for every message that is an unlock attempt, whatever happens next."""
    try:
        source = getattr(event, "source", None)
        platform = getattr(getattr(source, "platform", None), "value", None)
        if platform != "telegram":
            return None
        if (getattr(event, "metadata", None) or {}).get("hermes_plugin_injection"):
            return None  # this plugin's own turn for the agent: it holds no secret
        text = getattr(event, "text", None)
        if not text:
            return None  # a photo, a sticker: there is no text to be a secret
        kind = classify(text, _factor(), _approving(getattr(source, "user_id", None)))
    except BaseException:  # noqa: BLE001 - the text could not even be read: it is not let through
        return SKIP
    if kind is None:
        return None
    try:
        adapter = gateway.adapters[source.platform]
        chat_id, message_id = source.chat_id, getattr(event, "message_id", None)

        async def delete():
            return await adapter.delete_message(chat_id, message_id) if message_id else False

        async def send(text):
            return await adapter.send(chat_id, text)

        await dispatch(kind, user_id=getattr(source, "user_id", None), chat_id=chat_id,
                       private=getattr(source, "chat_type", "") == "dm", delete=delete, send=send)
    except BaseException as exc:  # noqa: BLE001
        if isinstance(exc, asyncio.CancelledError):
            raise
        log.warning("the unlock hook failed (%s); the message was dropped", type(exc).__name__)
    return SKIP


async def dispatch(kind, *, user_id, chat_id, private: bool, delete, send) -> None:
    """A message the secret path took, to the part of this file that answers it."""
    if kind[0] in ("lock", "unlock", "bare"):
        await process(kind[0], kind[1], user_id=user_id, chat_id=chat_id, private=private,
                      factor=_factor(), delete=delete, send=send)
    else:
        await process_approval(kind[0], kind[1], user_id=user_id, private=private, delete=delete, send=send)


# ------------------------------------------------------- line 1: Telegram's own handler chain

def telegram_handler(app, adapter):
    """Line 1. Registered with ``register_telegram_handler``; runs as the adapter connects.
    The telegram package is imported here and not at the top: the add-on that ships it is optional."""
    from telegram import Update
    from telegram.ext import ApplicationHandlerStop, BaseHandler

    class SecretHandler(BaseHandler):
        def check_update(self, update):
            # Called for every update: answers True for a message that is an unlock attempt, and
            # for one whose text cannot be classified (it is then dropped, not let through).
            try:
                msg = update.message if isinstance(update, Update) else None
                if msg is None or msg.text is None:
                    return False
                return classify(msg.text, _factor(), _approving(getattr(msg.from_user, "id", None))) is not None
            except BaseException:  # noqa: BLE001
                return True

    async def on_secret(update, context):
        try:
            msg = update.message
            chat, user = msg.chat, msg.from_user
            try:
                kind = classify(msg.text, _factor(), _approving(getattr(user, "id", None))) or ("unlock", "")
            except Exception:  # noqa: BLE001
                kind = ("unlock", "")  # unreadable: dropped, and fits no factor, so nothing is tried

            async def delete():
                await context.bot.delete_message(chat_id=chat.id, message_id=msg.message_id)
                return True

            async def send(text):
                await context.bot.send_message(chat_id=chat.id, text=text)

            await dispatch(kind, user_id=getattr(user, "id", None), chat_id=chat.id,
                           private=getattr(chat, "type", "") == "private", delete=delete, send=send)
        except asyncio.CancelledError:
            raise
        except BaseException as exc:  # noqa: BLE001
            log.warning("the Telegram unlock handler failed (%s); the update was dropped", type(exc).__name__)
        # Whatever happened above, nothing downstream sees this update.
        raise ApplicationHandlerStop()

    # A group below the adapter's own (0), so this runs before every handler it registers, and
    # the stop above keeps the later groups, the observer included, from seeing the update.
    app.add_handler(SecretHandler(on_secret), group=-1)
    # The card's buttons, scoped by pattern: the adapter has a catch-all for its own buttons, and
    # a handler that matched every button would swallow them (upstream's register_telegram_handler).
    from telegram.ext import CallbackQueryHandler
    app.add_handler(CallbackQueryHandler(on_card_button, pattern=CARD_BUTTON.pattern), group=-1)
    global _BOT
    _BOT = app.bot
    if _approvals_on():
        _start_poller()
    log.info("openwrt-unlock: the Telegram handler is in place")


# ------------------------------------------------------- the agent is told the window is open

# When the window the owner opened ends, as epoch seconds, or None. One gateway process holds one
# client, hermes-main, so one value is the whole state; a second agent would be a second process
# with its own. Written from the event loop and read from the agent's thread.
_window_end = None
_window_lock = threading.Lock()

NOTE_FORMAT = "The owner has unlocked router changes until %s; if a change was waiting for that, do it now."
_NOTE_AT = "The owner has unlocked router changes until "
# The line, and the blank lines that set it apart from the message it was appended to.
_NOTE_LINE = re.compile(r"\n*[ \t]*" + re.escape(_NOTE_AT) + r"[^\n]*")


def note_outcome(tool: str, answered: bool, text: str, is_error: bool) -> None:
    """Remembers what an answer from the daemon says about the window, so the agent can be told.

    It learns an open window only from an answer that says it is open and when it ends, and forgets
    it on any answer that closes it or leaves it in doubt (a lock, a lockout, a lock that could not
    be told apart from an error). Not hearing from the daemon changes nothing."""
    global _window_end
    try:
        if not answered:
            return
        low = (text or "").lower()
        if tool == "mfa_lock":
            end = None
        elif tool == "mfa_unlock" and not is_error and low.startswith("unlocked until"):
            when = _when(text)
            end = when.timestamp() if when is not None else None
        elif tool == "mfa_unlock" and "locked out" in low:
            end = None
        else:
            return  # a refused try says nothing about a window that was already open
        with _window_lock:
            _window_end = end
    except Exception:  # noqa: BLE001 - never on the secret path
        pass


def _current_note():
    """The line for the window that is open now, or None."""
    with _window_lock:
        end = _window_end
    if end is None or time.time() >= end:
        return None
    return NOTE_FORMAT % datetime.datetime.fromtimestamp(end).strftime("%H:%M")


def pre_llm_call(**ctx):
    """Upstream's hook before a turn's request: what it returns is added to the user's message.

    The owner's /unlock never reaches the agent, so without this it asks for one it was already
    given. A scheduled job is not told: it may not change the router inside a window, and being
    told it may would only send it to a refusal."""
    try:
        note = _current_note()
        if note is None or _is_scheduled(ctx):
            return None
        return {"context": note}
    except Exception:  # noqa: BLE001
        return None


def _drop_stale_notes(text: str) -> str:
    """``text`` without the notes that no longer hold: every one when no window is open, and any
    that names another end than the window open now. The request replays earlier turns with the
    line they were sent with, and after /lock that would still read "do it now"."""
    if _NOTE_AT not in text:
        return text
    current = _current_note()
    new = _NOTE_LINE.sub(lambda m: m.group(0) if current is not None and m.group(0).strip() == current else "", text)
    return text if new == text else new


# ---------------------------------------------------------------- scheduled jobs cannot change

# What a read-only caller may do through openwrt-mcp: the tools that read, and ubus_call only
# for the methods the init lists as reads. Everything else is a change, and an unknown tool is one.
_READ_TOOLS = {"ubus_list", "uci_get", "logread", "status", "action_status"}
_BRIDGE = "tool_call"
_PREFIX = "mcp__openwrt__"


def _read_ubus():
    raw = os.environ.get("HERMES_OPENWRT_READ_UBUS", "")
    return [p for p in raw.replace(",", " ").split() if p]


def _is_scheduled(ctx: dict) -> bool:
    """Whether this tool call belongs to a scheduled job. Upstream marks a cron run in three
    places, and any one of them is enough: the HERMES_CRON_SESSION context variable the scheduler
    binds for the run, a session id of the form cron_<job>_<time>, and a task id of cron:<job>:..."""
    try:
        from gateway.session_context import get_session_env
        if str(get_session_env("HERMES_CRON_SESSION", "") or "").strip().lower() in ("1", "true", "yes"):
            return True
    except Exception:  # noqa: BLE001
        pass
    if str(ctx.get("session_id") or "").startswith("cron_") or str(ctx.get("task_id") or "").startswith("cron:"):
        return True
    return False


def _refuses(tool_name: str, args: dict):
    """The reason a read-only caller may not make this call, or None."""
    name, arguments = tool_name, args if isinstance(args, dict) else {}
    if name == _BRIDGE:
        try:
            from tools.tool_search import resolve_underlying_call
            name, arguments, err = resolve_underlying_call(arguments)
            if err or not name:
                return "a call through the tool bridge that could not be read"
        except Exception:  # noqa: BLE001
            return "a call through the tool bridge that could not be read"
    if not str(name).startswith(_PREFIX):
        return None
    short = str(name)[len(_PREFIX):]
    if short in _READ_TOOLS:
        return None
    if short == "ubus_call":
        scope = "%s.%s" % ((arguments or {}).get("object", ""), (arguments or {}).get("method", ""))
        if any(fnmatch.fnmatchcase(scope, pattern) for pattern in _read_ubus()):
            return None
        return "ubus_call " + scope
    return short


def pre_tool_call(tool_name=None, args=None, **ctx):
    """Refuses a change to the router from a scheduled job, even inside an open unlock window.

    Hermes treats a pre_tool_call hook that raises as a veto, so this one catches what it can:
    an error is a block for a router tool and no opinion for any other."""
    try:
        if not _is_scheduled(ctx):
            return None
        why = _refuses(tool_name or "", args)
        if why is None:
            return None
        return {"action": "block", "message": (
            "Refused: a scheduled job cannot change the router (" + why + "), even while the owner "
            "has changes unlocked. Tell the owner in the job's output to ask for this in the chat.")}
    except Exception:  # noqa: BLE001
        if str(tool_name or "").startswith(_PREFIX) or tool_name == _BRIDGE:
            return {"action": "block", "message": "Refused: this router tool call could not be checked."}
        return None


# ------------------------------------------------------------------------------- registration

# The shapes a log line can carry the secret in. Hermes masks a match whole: all of it when it is
# under 18 characters, and when it is longer, everything but its first six and last four. So
# each pattern below is kept under 18 characters whatever digits it meets, and a PIN or a
# code (4 to 8 and 6 digits) is then always masked in full. A PIN followed by a code is longer
# than that and cannot be matched in one piece (a pattern must start with two literal
# characters, and what follows a PIN has none), so /unlock <PIN> <code> still leaves the last
# four digits of the code in a log line, and in the quoted forms the PIN of a PIN and a code is
# masked and the code is not. That is the limit of this line of defence: it is the last of four,
# and the gate shows that nothing reaches it in the first place.
REDACTION_PATTERNS = (
    r"/unlock[ \t]{1,2}[0-9]{4,8}[ \t][0-9]{6}",
    r"/unlock[ \t]{1,2}[0-9]{4,8}",
    r": '[0-9]{4,8}",
    r"text='[0-9]{4,8}",
    r"msg='[0-9]{4,8}",
)


# ============================================================== held changes: the owner approves

# A card's buttons: owa approves, owr rejects, then the id and the first 16 hex of the card's hash.
CARD_BUTTON = re.compile(r"^ow([ar]):([A-Z]{5}):([0-9a-f]{16})$")
HELD_RE = re.compile(r"\bHELD ([A-Z]{5}) until (\S+)")
POLL_SECONDS = 5.0
PROMPT_SECONDS = 180.0
# The approval's own factor, which openwrt-mcp's approval section names (the init writes pin+totp).
APPROVAL_FACTOR = "pin+totp"

_CTX = None
_BOT = None
_POLLER = None
# id -> what this gateway knows of a held change: its hash, headline and tool from action_list, the
# card message it sent (chat id, message id), and the status it last showed.
_cards = {}
# id -> the session the change was proposed from, learned from the tool's own answer.
_sessions = {}
_sessions_lock = threading.Lock()
# approver id -> the change whose PIN and code they were just asked for, and until when.
_prompts = {}


def _approving(user_id) -> bool:
    p = _prompts.get(str(user_id)) if user_id is not None else None
    return bool(p) and time.time() < p["until"]


def post_tool_call(tool_name=None, args=None, result=None, **_ctx):
    """Remembers which chat a held change came from, so the owner's answer can be told to it."""
    try:
        if not isinstance(result, str) or "HELD " not in result:
            return None
        m = HELD_RE.search(result)
        if not m:
            return None
        from gateway.session_context import get_session_env
        key = str(get_session_env("HERMES_SESSION_KEY", "") or "").strip()
        if key:
            with _sessions_lock:
                _sessions[m.group(1)] = key
    except Exception:  # noqa: BLE001 - an observer: it never changes what the agent sees
        pass
    return None


def _actions():
    """The held changes of this gateway's agent, as openwrt-mcp lists them to the owner's client."""
    answered, text, is_error = call_tool("action_list", {})
    if not answered or is_error:
        return None
    try:
        return [a for a in json.loads(text).get("actions", []) if a.get("client") == _client()]
    except Exception:  # noqa: BLE001
        return None


OUTCOME_LINE = {
    "applied": "Approved and applied.",
    "failed": "Approved, but it failed.",
    "rejected": "Rejected. Nothing was applied.",
    "expired": "Expired without an answer. Nothing was applied.",
    "withdrawn": "Withdrawn by the agent. Nothing was applied.",
}


def _turn_for(a: dict):
    """The turn the agent is told the outcome in, or None when there is nothing to tell."""
    aid, status, head = a.get("id", ""), a.get("status", ""), (a.get("headline") or "").split("\n")[0]
    result = a.get("result") or ""
    if status == "applied":
        token = re.search(r'uci_confirm \{"token": "([^"]+)"\}', result)
        until = re.search(r"reverts automatically at (\S+)", result)
        if token:
            return ("[The owner approved %s and it was applied: %s. It rolls back at %s unless it is confirmed: "
                    "check that the router still answers and behaves as asked, then call uci_confirm with token %s.]"
                    % (aid, head, until.group(1) if until else "a few minutes from now", token.group(1)))
        return "[The owner approved %s and it ran: %s.]" % (aid, head)
    if status == "failed":
        return "[The owner approved %s, but it failed: %s]" % (aid, result.split("\n")[0][:300])
    if status == "rejected":
        return "[The owner rejected %s; it was not applied. Do not propose it again unless the owner asks for it.]" % aid
    if status == "expired":
        return "[%s expired without an answer from the owner; it was not applied.]" % aid
    return None


def _tell_agent(a: dict) -> None:
    text = _turn_for(a)
    if not text:
        return
    with _sessions_lock:
        key = _sessions.pop(a.get("id", ""), None)
    if not key or _CTX is None:
        return
    try:
        if not _CTX.inject_message(text, session_key=key):
            log.warning("the outcome of %s could not be given to the agent", a.get("id"))
    except Exception as exc:  # noqa: BLE001
        log.warning("the outcome of %s could not be given to the agent (%s)", a.get("id"), type(exc).__name__)


def _keyboard(a: dict):
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    tail = "%s:%s" % (a["id"], a["hash"][:16])
    return InlineKeyboardMarkup([[InlineKeyboardButton("Approve", callback_data="owa:" + tail),
                                  InlineKeyboardButton("Reject", callback_data="owr:" + tail)]])


async def _show(a: dict) -> None:
    """Sends a newly held change's card to the approver, or edits a card whose change was decided."""
    aid, status = a.get("id"), a.get("status")
    card = _cards.get(aid)
    # openwrt-mcp lists a change as approving while an approval runs, and as held again when that
    # try is refused: neither is an outcome, so the card stays one that can be approved.
    if status in ("held", "approving"):
        if card is not None and status == "held":
            card["shown"] = "held"
        if status == "held" and card is None and _BOT is not None and a.get("card") and len(a.get("hash", "")) == 64:
            msg = await _BOT.send_message(chat_id=int(_approver()), text=a["card"], reply_markup=_keyboard(a))
            _cards[aid] = {"hash": a["hash"], "headline": a.get("headline", ""), "tool": a.get("tool"),
                           "chat": msg.chat_id, "message": msg.message_id, "shown": "held", "card": a["card"]}
        return
    if card is None or card.get("shown") == status:
        return
    card["shown"] = status
    if status in OUTCOME_LINE and _BOT is not None:
        try:
            await _BOT.edit_message_text(chat_id=card["chat"], message_id=card["message"],
                                         text=card["card"] + "\n\n" + OUTCOME_LINE[status], reply_markup=None)
        except Exception as exc:  # noqa: BLE001 - the card stays as it was; the outcome is still told
            log.warning("the card of %s could not be edited (%s)", aid, type(exc).__name__)
    await asyncio.to_thread(_tell_agent, a)


async def _poll_forever() -> None:
    while True:
        try:
            for a in (await asyncio.to_thread(_actions)) or []:
                await _show(a)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - the next round tries again
            log.warning("could not read the held changes (%s)", type(exc).__name__)
        await asyncio.sleep(POLL_SECONDS)


def _start_poller() -> None:
    global _POLLER
    if _POLLER is not None and not _POLLER.done():
        return
    coro = _poll_forever()
    try:
        _POLLER = _CTX.spawn_task(coro, name="openwrt-unlock:held") if _CTX is not None else asyncio.get_running_loop().create_task(coro)
    except Exception:  # noqa: BLE001
        coro.close()
        log.error("the task that shows held changes could not start; approve with /approve <id>")


APPROVE_ANSWERS = (
    ("hash is not", "That card is no longer the change that waits, so nothing was approved."),
    ("changed since", "The router's configuration changed since this was asked for, so nothing was approved. "
                      "Reject it, and let the agent ask again if it is still wanted."),
    ("waits for confirmation", "Another change still waits for the agent to confirm it. Approve this one again "
                               "in a few minutes."),
    ("expired", "It expired before it was approved. Nothing was applied."),
    ("locked out", None),
    ("no held change", "That change is no longer waiting."),
)


def approve_answer(answered: bool, text: str, is_error: bool) -> str:
    """What the owner is told of an approval. Built from the daemon's outcome and nothing typed."""
    if not answered:
        return "I could not reach the router's approval service. Nothing was approved."
    low = (text or "").lower()
    if not is_error and low.startswith("applied"):
        return "Approved and applied."
    if "approved, but" in low:
        return "Approved, but it failed. The agent is told why."
    for fragment, answer in APPROVE_ANSWERS:
        if fragment in low:
            if answer is None:
                until = _clock(text)
                return ("Too many wrong tries. Approving and unlocking are closed until " + until + "."
                        if until else "Too many wrong tries. Approving and unlocking are closed for a while.")
            return answer
    if "already used" in low:
        return "That code was already used. Wait for the next one, and send /approve again."
    return "Refused. Nothing was approved."


async def _ask_factor(user_id, aid: str, send) -> None:
    card = _cards.get(aid)
    if card is None:
        for a in (await asyncio.to_thread(_actions)) or []:
            if a.get("id") == aid and a.get("status") == "held":
                await _show(a)
                card = _cards.get(aid)
    if card is None or card.get("shown") != "held":
        await send("No change %s is waiting." % aid if aid else "No change is waiting.")
        return
    _prompts[str(user_id)] = {"id": aid, "hash": card["hash"], "until": time.time() + PROMPT_SECONDS}
    await send("To approve %s, the change openwrt-mcp holds is:\n%s\n\nIf that is what you want, send your PIN "
               "and then the 6-digit code from your app, with a space between. Otherwise press Reject or send "
               "/reject %s." % (aid, card["headline"], aid))


async def _decided(aid: str) -> None:
    """Shows a decision at once, without waiting for the next poll."""
    for a in (await asyncio.to_thread(_actions)) or []:
        if a.get("id") == aid:
            await _show(a)


async def process_approval(kind: str, arg: str, *, user_id, private: bool, delete, send) -> None:
    """/approve, /reject and the PIN and code of an approval. Like process(): never raises, and a
    message that may hold a secret is deleted before anything is asked."""
    try:
        if str(user_id) != _approver() or not _approvals_on():
            if kind == "approve_factor":
                return  # not reachable: only the approver is ever asked
            if authorized(user_id) and private:
                with _quiet():
                    await delete()
                await send("Only the owner chosen to approve changes can approve or reject them.")
            return
        in_group = not private
        if in_group:
            with _quiet():
                await delete()
            await send("Approvals work only in the private chat with me, where I can delete your message.")
            return
        removed = False
        try:
            removed = bool(await delete())
        except Exception as exc:  # noqa: BLE001
            log.warning("could not delete an approval message (%s)", type(exc).__name__)
        note = "" if removed else " I could not delete your message from the chat. Delete it yourself."
        if kind == "approve":
            if not arg:
                waiting = [a for a in (await asyncio.to_thread(_actions)) or [] if a.get("status") == "held"]
                await send(("Waiting for you: " + ", ".join(a["id"] for a in waiting) + ". Send /approve <id>.")
                           if waiting else "No change is waiting.")
                return
            await _ask_factor(user_id, arg, send)
            return
        if kind == "reject":
            answered, text, is_error = await asyncio.to_thread(call_tool, "action_reject", {"id": arg})
            await send("Rejected. Nothing was applied." if answered and not is_error
                       else "That change is no longer waiting." if answered else
                       "I could not reach the router's approval service.")
            await _decided(arg)
            return
        prompt = _prompts.pop(str(user_id), None)
        if not prompt or time.time() >= prompt["until"]:
            await send("Nothing is waiting for a PIN and a code from you. Send /approve <id> first." + note)
            return
        arguments = attempt_for(APPROVAL_FACTOR, arg)
        if arguments is None:
            _prompts[str(user_id)] = prompt  # a typo is not a try: ask again
            await send("That does not look like a PIN and a code. " + hint_for(APPROVAL_FACTOR).replace("/unlock", "your answer") + note)
            return
        arguments.update(id=prompt["id"], hash=prompt["hash"])
        answered, text, is_error = await asyncio.to_thread(call_tool, "action_approve", arguments)
        arguments = None  # the secret leaves scope here
        await send(approve_answer(answered, text, is_error) + note)
        await _decided(prompt["id"])
    except Exception as exc:  # noqa: BLE001
        log.warning("the approval path failed (%s); the message was dropped", type(exc).__name__)
        try:
            await send("Something went wrong. Your message was dropped and nothing was approved.")
        except Exception:  # noqa: BLE001
            pass


async def on_card_button(update, context):
    """Approve or Reject under a card. Reject is the decision; Approve asks for the PIN and the code."""
    from telegram.ext import ApplicationHandlerStop
    try:
        q = update.callback_query
        user = getattr(q.from_user, "id", None)
        chat = getattr(getattr(q, "message", None), "chat", None)
        m = CARD_BUTTON.match(q.data or "")
        if not m or str(user) != _approver() or getattr(chat, "type", "") != "private" or not _approvals_on():
            with _quiet():
                await q.answer("Only the owner chosen to approve changes can use these buttons.")
            raise ApplicationHandlerStop()
        verb, aid, h16 = m.groups()
        card = _cards.get(aid)
        if card is None or not card["hash"].startswith(h16) or card.get("shown") != "held":
            with _quiet():
                await q.answer("This change is no longer waiting.")
            raise ApplicationHandlerStop()

        async def send(text):
            await context.bot.send_message(chat_id=chat.id, text=text)

        with _quiet():
            await q.answer()
        if verb == "r":
            answered, text, is_error = await asyncio.to_thread(call_tool, "action_reject", {"id": aid})
            if not (answered and not is_error):
                await send("That change is no longer waiting." if answered else "I could not reach the router's approval service.")
            await _decided(aid)
        else:
            await _ask_factor(user, aid, send)
    except ApplicationHandlerStop:
        raise
    except asyncio.CancelledError:
        raise
    except BaseException as exc:  # noqa: BLE001
        log.warning("a card's button failed (%s)", type(exc).__name__)
    raise ApplicationHandlerStop()


def register(ctx):
    global _CTX
    _CTX = ctx
    # First: no tool has run yet, so no process has inherited it.
    _take_owner_token()
    ctx.register_hook("pre_gateway_dispatch", pre_gateway_dispatch)
    ctx.register_hook("post_tool_call", post_tool_call)
    ctx.register_middleware("llm_request", llm_request)
    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_hook("pre_llm_call", pre_llm_call)
    ctx.register_redaction_patterns(list(REDACTION_PATTERNS))
    # The Telegram library prints each update, text included, at DEBUG before any handler runs.
    logging.getLogger("telegram").setLevel(logging.INFO)
    try:
        ctx.register_telegram_handler(telegram_handler)
    except Exception as exc:  # noqa: BLE001 - lines 2 and 3 still stand
        log.error("the Telegram handler could not be registered (%s); lines 2 and 3 still stand", type(exc).__name__)
