#!/usr/bin/env python3
# mcp-probe.py -- call one openwrt-mcp tool with the agent's own token, as the agent would.
# Runs ON the router, as root (to read the root-only token). hw-flow.sh copies it there.
#   python3 mcp-probe.py <tool> '<json arguments>'
# Prints one line: "OK <text>" or "ERROR <text>", cut to 300 characters.
import json
import sys
import urllib.request

URL = "http://127.0.0.1:8730/mcp"
TOKEN = open("/etc/hermes-agent/router-mcp.token").read().strip()
session = None


def rpc(method, params=None, notify=False, _id=[0]):
    global session
    body = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        body["params"] = params
    if not notify:
        _id[0] += 1
        body["id"] = _id[0]
    headers = {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
    if session:
        headers["Mcp-Session-Id"] = session
    resp = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(body).encode(), headers), timeout=60)
    session = resp.headers.get("Mcp-Session-Id") or session
    raw = resp.read().decode()
    if notify or not raw.strip():
        return None
    for line in raw.splitlines():
        if line.startswith("data:"):
            raw = line[5:]
    return json.loads(raw)


rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "hw-flow", "version": "1"}})
rpc("notifications/initialized", notify=True)
res = rpc("tools/call", {"name": sys.argv[1], "arguments": json.loads(sys.argv[2])})
r = res.get("result") or res.get("error") or {}
text = " ".join(c.get("text", "") for c in (r.get("content") or [])) if isinstance(r, dict) else str(r)
if isinstance(r, dict) and "message" in r and not text:
    text = r["message"]
failed = bool(res.get("error")) or (isinstance(r, dict) and r.get("isError"))
print(("ERROR " if failed else "OK ") + " ".join(text.split())[:300])
