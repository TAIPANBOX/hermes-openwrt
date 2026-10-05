# Reaching it from a phone

![A phone talks to Telegram, the router polls Telegram outbound, and an allowlist decides who is answered](telegram.svg)

```sh
apk add hermes-agent-telegram
```

Then, in **Services -> Hermes Agent -> Settings**, switch Telegram on, paste the token
from [@BotFather](https://t.me/BotFather), and add your own numeric Telegram id. The
service will not start until that last part is done, and the reason is the next section.

**The router opens no port.** The adapter polls Telegram outbound, so this works behind
NAT, behind CGNAT, and on a connection with no static address, and nothing has to be
forwarded to the router. Webhook mode exists and its server is packaged, because a router
is the one machine in the house that plausibly does have a public address, but it is not
the default and nothing needs it.

## Why the service refuses to start with an empty allowlist

Upstream already default-denies: an unlisted user is ignored, and that is the last line
of `_is_user_authorized` in `gateway/authz_mixin.py`. So an empty allowlist is safe. It
is also silent, and silence is the problem. The bot answers nobody, explains nothing, and
the obvious next move for somebody trying to make it work is to find the switch that
turns the allowlist off.

So the service refuses to start instead, names the command that adds an id, and mentions
the switch rather than leaving it to be discovered:

```
hermes-agent: telegram is enabled but no user is allowed to talk to it.
hermes-agent: add your numeric Telegram id (ask @userinfobot for it):
hermes-agent:   uci add_list hermes.telegram.allow_user_id=123456789
hermes-agent:   uci commit hermes && service hermes-agent restart
hermes-agent: or set hermes.telegram.allow_all=1 to answer anyone, which on a
hermes-agent: bot holding router tools means anyone who finds the bot.
```

The token is handled exactly like the model API key: a root-only file, never UCI, never
argv, and a write-only field on the settings page.

## Why it is a separate package

The Telegram adapter is already inside `hermes-agent`. Upstream's wheel ships
`plugins/platforms/telegram/` alongside twenty other platforms, so nothing had to be
ported. What is missing from a router is the client library, and that is all this
package is.

Measured on every build inside `openwrt/rootfs` for aarch64 25.12: adding
`python-telegram-bot[webhooks]` to the router profile adds **two** distributions and
changes the version of nothing already installed.

| | |
|---|---|
| added | `python-telegram-bot` 22.8, `tornado` 6.5.8 |
| version changes to the base package's 77 | none |
| flash it takes | 12 MB, against the base package's 239 MB tree (2026-09-25, both routers) |

That second row is what makes an add-on possible at all. Two OpenWrt packages cannot own
one file, and apk refuses such an install. So the contents are not written down anywhere.
`package/hermes-agent-telegram/files/delta.py` resolves the base profile and the base
profile plus Telegram on every build, through the same resolution the base package is
built with, and subtracts, and it stops the build if a shared
package would have to change version. Upstream's pin is read from upstream's own
metadata, so a version bump carries the right one automatically.

Taking upstream's `messaging` extra whole would also have installed Discord with voice
support, which pulls compiled crypto, and Slack. The router was asked for Telegram.

## What a test chat shows

Measured on the Brume 2 through Telegram on 2026-10-01 and 2026-10-02. None of it is a fault of
the package, and each of them looks like one the first time.

- The first message in a new conversation can be taken by Hermes's own onboarding question,
  which offers to build a short profile of you, instead of being acted on. Send it again.
- Each new conversation prints a notice that no home channel is set. `/sethome` once makes that
  chat the home channel, which is where the results of scheduled jobs go.
- A scheduled check that finds a problem can answer with Hermes's own failure marker, so the run
  is recorded as failed, and with `--failure-deliver local` the alert is silent. Leave
  `--failure-deliver` out, so failures follow `--deliver`, and do not take one lost ping for a
  problem.
- A small free model may skip a tool it was told to use (a morning digest ran with one model
  call and no web search) or answer from the conversation instead of acting. The model is the
  first thing to change when an agent will not act.
