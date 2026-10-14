# More than one provider

One router can offer several providers at once: a key for one, another key for another,
a ChatGPT subscription for a third. Every chat starts on the main model; in a chat,
`/model` lists the others beside it and switches that chat only, so several chats run on
several providers at the same time. On 2026-09-25 three agents in one process on the
Brume 2, on OpenRouter, an Anthropic key and a ChatGPT subscription, answered together
from what the router's `uptime` said, in 150 MB.

Each further provider is a UCI section, and its key a root-only file, like the main one:

```sh
printf '%s' 'sk-ant-...' > /etc/hermes-agent/claude.key && chmod 600 /etc/hermes-agent/claude.key
uci set hermes.claude=provider
uci set hermes.claude.label='Anthropic'
uci set hermes.claude.base_url='https://api.anthropic.com/v1'
uci set hermes.claude.model='claude-haiku-4-5'
uci commit hermes && /etc/init.d/hermes-agent restart
```

`key_file` defaults to `/etc/hermes-agent/<name>.key`. A name upstream already uses for a
provider of its own (`anthropic`, `openrouter`, `openai` and the like) refuses the start,
because upstream would resolve its own first and the chat would land somewhere else. A
key that goes missing drops that provider alone, with a line in the log. A provider on
the same address as the main model keeps its own key, so a second account on the main
model's own service works as a further provider. In `/model` the main model is listed as
`Main (<host>)`; `uci` is its entry, so no section can take that name.

A ChatGPT subscription needs no section. Allow device code sign-in once in ChatGPT's
security settings, then:

```sh
hermes-login chatgpt
```

It prints a code to enter at `auth.openai.com/codex/device`, in a browser signed in to
ChatGPT; the tokens stay in the agent's data directory, readable by root only, and no
password passes through the router. ChatGPT then shows up in `/model`. To put one chat on it
by name, send the model with upstream's provider for the subscription:

```
/model gpt-6.1-sol --provider openai-codex
```

The model matters more for changing a router than for answering. Measured on 2026-10-08 on a
Brume 2 and a Flint 2 through Telegram, with openwrt-mcp: `gpt-6.1-sol` through a ChatGPT
subscription ran the diagnosis correctly, while `gpt-4o-mini` looped on its memory tool and made
a wrong firewall change.

**Anyone the bot answers can switch their chat to any provider listed here**, including
keys that cost money per call. The allowlist is the boundary, as it is for everything
else the agent can do. **Services -> Hermes Agent -> Providers** does all of this from the
browser: it adds and removes providers, takes each key write-only like the main one,
deletes a provider's key along with the provider, and signs ChatGPT in and out, showing
the address and the code to enter.

## Through a model gateway

A gateway between the router and the provider can meter every model call, cap what a
conversation or a group of routers may spend, stop a run, and keep a record, without
anything on the router changing but its address. The router only needs to send the
gateway's own headers. This is how it was set up on a Flint 2 and a Brume 2 against TokenFuse's
OpenAI-compatible door; any gateway that reads headers works the same way.

**The address and the model**, in UCI as for any endpoint:

```sh
uci set hermes.main.base_url='http://<gateway>:<port>/v1'
uci set hermes.main.model='anthropic/claude-haiku-5.5'   # a model the gateway's upstream serves
uci commit hermes
```

**The provider key.** `/etc/hermes-agent/provider.key` holds whatever the gateway passes
upstream. A pass-through gateway (TokenFuse's door is one) forwards the router's
`Authorization` header to the provider, so the file holds your provider key, as before; a
gateway that holds the provider key itself needs only a placeholder there.

**The gateway's headers**, in `config.yaml` in the data directory (`/srv/hermes`), owned by
the user `hermes`. The package leaves these keys alone when it rewrites the model settings
at every start:

```yaml
model:
  default_headers:
    x-fuse-key: ${FUSE_CLIENT_KEY}
    x-fuse-agent-id: agent://example.home/routers/flint2
    x-fuse-run-id: flint2-hermes            # used only by a call outside a conversation
    x-fuse-budget-usd: '0.05'               # the most one conversation may spend
custom_providers:
- name: Gateway session
  base_url: http://<gateway>:<port>/v1
  session_affinity_header: x-fuse-run-id    # one run per conversation, see below
```

`${FUSE_CLIENT_KEY}` is read from the environment when the gateway starts. Put the gateway's
credential in `/srv/hermes/.env` without it touching a command line, then hand the file to
the agent's user and restart:

```sh
ssh root@<router> 'umask 077; { printf "FUSE_CLIENT_KEY="; cat; echo; } > /srv/hermes/.env; chown hermes:hermes /srv/hermes/.env' < client-key.txt
/etc/init.d/hermes-agent restart
```

**One run per conversation.** A gateway that keeps budgets and its firewall per run needs a
run id that follows the conversation. Hermes sends a key that stays the same for one
conversation in the header a `custom_providers` entry names in `session_affinity_header`, on
every call of it, and that wins over the fixed id in `default_headers`. A chat is a run of its
own, and so is a scheduled job, across all of its runs: a job that repeats spends one run's
budget over its whole life, so size `x-fuse-budget-usd` for that, or leave the cap to the
gateway's limit for the group. With the fixed id alone, everything the router ever does is one
run. The entry has to sit in `custom_providers`: the package rewrites its own `providers.uci`
entry at every start.

**What a router sees when the gateway says no.** Measured on a Flint 2 and a Brume 2 on
2026-10-14 through TokenFuse's door, with one-off scheduled jobs:

| the gateway | the job on the router |
|---|---|
| a conversation reaches its budget | the call is refused with 402 and the job fails with the gateway's own sentence, "run ... was stopped by the gateway: per-run budget exceeded"; Hermes does not retry it |
| the credential is wrong or missing | 401, the job fails with the gateway's reason; the service itself starts without complaint, since the package does not know about the credential |
| the router claims another router's identity | 403 `identity_mismatch`, the job fails, nothing reaches the provider |
| the gateway is down | Hermes tries three times over about ten seconds; the gateway came back before the third try and the turn finished. Down for longer, the job fails |
| a model switched with `hermes cron edit --model` | served and priced per call, inside the same run |

**What the gateway governs, and what it does not.** It sees every model call: who calls,
as whom, how much a conversation and the group of routers have spent, what the tool results
in the conversation carried. It does not see the tools themselves: the terminal, the files
and openwrt-mcp run on the router, and the agent calls openwrt-mcp there directly, not through
a gateway's own MCP broker, so a change to the router is governed by openwrt-mcp and your
unlock (see [security.md](security.md)), not by the gateway. What the tools fetch from the
internet does not pass through it either. Two things measured on 2026-10-14 with TokenFuse's
firewall in enforce mode:

- A gateway that judges the tool calls in an answer sees only what it reads whole. Hermes
  streams its answers, and TokenFuse does not yet judge a streamed answer's tool calls: a
  `write_file` call its firewall refuses in a buffered answer ran on the router.
- TokenFuse reads the descriptions of the tools a request declares, and the descriptions of
  openwrt-mcp's `uci_get` and Hermes's own `web_extract` read to it as a possible injection.
  Every conversation is therefore marked untrusted from its first call, and a real injection
  read later adds no new signal.

Limits on the router side:

- With a pass-through gateway the provider key stays on the router (root's alone, as
  before): the gateway limits what the key spends through it, not what it spends elsewhere.
- `.env` and `config.yaml` belong to the agent's user, so the agent can read the gateway's
  credential. With it alone nobody can spend your provider key, but they can call the
  gateway as this router.
- A gateway on the LAN is usually plain `http`: the provider key and the gateway's
  credential then cross your network unencrypted. Put the gateway behind TLS before you use
  it anywhere you do not trust every device on the network.
