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
