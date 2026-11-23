# Questions from netryx

[netryx](https://github.com/TAIPANBOX/netryx) is the traffic console on the same router. Its button
"Ask the router's agent" sends the stretch of traffic the owner selected, with a question, to the Hermes
agent running on that router, and shows the answer in plain language. This page is the contract between
the two: how the agent is reached, what it is sent, what comes back, and what such a question can and
cannot do. [docs/security.md](security.md#questions-from-netryx-the-routers-console) says why it is safe.

## Turning it on

Off unless the owner turns it on, and only in the owner profile:

```sh
uci set hermes.api.enabled=1 && uci commit hermes && service hermes-agent restart
```

The first start with it on writes a random key, 64 hex digits, to `/etc/hermes-agent/api.key`
(`hermes.api.key_file`), a file only root reads. To replace the key, remove the file and restart the
service. The other settings, with their defaults:

| Option | Default | Meaning |
|---|---|---|
| `hermes.api.port` | `8642` | the port on 127.0.0.1, from 1024 to 65535 |
| `hermes.api.hourly_limit` | `10` | questions an hour, from 1 to 1000 |
| `hermes.api.daily_budget_usd` | `0.50` | what the questions may cost the model in a day (UTC) |
| `hermes.api.key_file` | `/etc/hermes-agent/api.key` | the key; a symbolic link or a key under 32 characters refuses the start |

A bad value refuses the start, with one line in `logread` naming the option. In another profile the
setting is ignored, with one line saying so.

## The request

```
POST http://127.0.0.1:8642/v1/ask
Authorization: Bearer <the key from /etc/hermes-agent/api.key>
Content-Type: application/json
Content-Length: <bytes>

{"question": "What made this spike?", "context": "14:02-14:05 UTC, 192.168.1.23 (laptop) -> 203.0.113.9:443, 1.2 GB, 96% of the window"}
```

- `question`: text, 1 to 2000 characters, in the language the answer should come in.
- `context`: optional text, up to 8000 characters: what the console selected (the time range, the
  devices, hosts, ports and bytes it saw). The agent is told it is data from the network and not
  instructions, since a host name or a DNS name in it can be anyone's.
- Nothing else: a body with another key (a model, a session, a history) is refused. The whole body is
  at most 16384 bytes, sent with `Content-Length`.
- netryx runs as root and reads the key file for each request, so a replaced key needs no restart of
  netryx.

Only this one route is served. Any other path, `GET`, or the same path with something after it answers
404 or 405 and reaches nothing.

## The answer

`200`:

```json
{"answer": "The laptop at 192.168.1.23 downloaded about 1.2 GB from ...", "cost_usd": 0.0031,
 "asks_left_this_hour": 9, "budget_left_usd": 0.4969}
```

`answer` is plain text for a person. `cost_usd` is what this question cost the model: as Hermes priced
it, or on Anthropic's own API at the model's list price with every input token charged as a cache write
(a question on Claude Haiku 5.5 costs a fraction of a cent), or, for a model or endpoint neither knows,
at 15 USD per million input tokens and 75 per million output, above any model a router is set up with
today, so the budget errs on the side of refusing.

Everything else is JSON of one shape, whose `message` is written to be shown to the person as it is:

```json
{"error": {"code": "hourly_limit", "message": "The console may ask 10 questions an hour, and this hour's are used. The next one can be asked in 12 minutes.", "retry_after": 701}}
```

| Status | `code` | When |
|---|---|---|
| 400 | `bad_request` | not JSON, a key other than question and context, an empty or long question, a long context |
| 401 | `unauthorized` | no key or another key |
| 404 / 405 | `not_found` / `method_not_allowed` | any other path or method |
| 409 | `busy` | another question is being answered; one runs at a time (`Retry-After: 60`) |
| 413 | `too_large` | a body over 16384 bytes |
| 429 | `hourly_limit` | the hour's questions are used (`Retry-After`: until the oldest leaves the hour) |
| 429 | `daily_budget` | today's budget is spent (`Retry-After`: until 00:00 UTC) |
| 502 | `agent_failed` | the agent could not answer (the model refused the key, say) |
| 503 | `usage_unreadable` | the record of what questions cost (`openwrt-api-usage.json` in the data directory) cannot be read; removing it starts it again |
| 504 | `timeout` | no answer within 110 seconds; the turn is asked to stop and its cost is still counted |

A refused connection means the agent is not running or the questions are off.

## Timing

The agent has 110 seconds; give the request 120. Usually a question takes a few model calls and a few
reads, some seconds on a cloud model. Only one runs at a time.

## What the agent can do for it

It reads the router through openwrt-mcp, as in a chat: its state, clients and DHCP leases, the
configuration (secrets redacted by openwrt-mcp), the log, and netryx's own six ubus reads where the
owner granted them (the `netryx_reads` policy in openwrt-mcp). It cannot change the router, even while
the owner has changes unlocked; it cannot run commands, read or write files, save memories or skills,
schedule jobs, send messages or hand the work to a subagent. The answer goes back to netryx only, never
to Telegram. What it reads goes to the model provider, as every read does.

## Trying it on the router

The key stays out of every command line: Python reads it from the file.

```sh
python3 - <<'EOF'
import json, urllib.request
key = open("/etc/hermes-agent/api.key").read().strip()
body = json.dumps({"question": "Who is on my network right now?"}).encode()
req = urllib.request.Request("http://127.0.0.1:8642/v1/ask", data=body, method="POST",
                             headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    print(urllib.request.urlopen(req, timeout=120).read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode())
EOF
```
