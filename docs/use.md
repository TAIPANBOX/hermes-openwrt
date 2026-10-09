# What it is for

## What this is, and what it is not

This is Hermes living on your router, inside your home network. It is an assistant with
a job to do there, not a general agent for the web, and it does not replace Hermes on a
VPS or a desktop.

- **It has no browser.** It cannot click through a website, sign in, book or buy, and a
  page that builds itself with JavaScript (flight prices, most shops) is out of its
  reach. Upstream asks for 2 GB of memory with browser tools, twice what these routers
  have, so browser, vision and image generation are not packaged (see [What it will not do](#what-it-will-not-do)).
- **It does reach the internet.** Hermes's web tools search and read ordinary pages
  without a browser, with no web API key, on upstream's keyless free tiers: on a Brume 2 on
  2026-10-04 a free model called `web_search` and then `web_extract` on the page it found,
  and named the newest upstream release correctly. The scripts behind a scheduled job fetch plain HTTP, which is measured too.
- **The model runs elsewhere.** The router runs the agent; a provider you choose runs
  the model, a free one included.

What it is good at is the network it sits in, and staying on all the time.

| Use | What it looks like | Status |
|---|---|---|
| **Looking after the home network, from a phone** | In Telegram: "why is the internet slow?" The agent runs commands on the router and answers from what they printed, not from general advice. | Measured on both routers: a five-command diagnosis answered in 18 to 25 s; on a clean Flint 2 with 0.21.5-r9's ping, 9 s ([measured](measured.md#the-agents-own-ping)) |
| **A watch that speaks only when something is wrong** | Every hour a script collects the router's numbers (loss and latency to the internet, DNS, free memory, flash, temperature) and the model reads them in one call. All normal, it stays silent; otherwise one message says what is wrong. | Ran every hour for 19 hours on a Brume 2 (2026-10-01/02), one model call per check, silent while all was normal. The one problem it saw (one ping of three lost) the model reported with Hermes's own failure marker, which a job delivering failures locally keeps silent: see [What a test chat shows](telegram.md#what-a-test-chat-shows) |
| **A morning message** | At 08:00: the weather, the exchange rate and one news item found by web search, in a few lines. | Delivered at 08:00 on 2026-10-02 in one model call, though the small free model skipped the web search it was asked for. Search itself measured on 2026-10-04: the same free model, told to use it, searched and read the page |
| **An assistant that is always on** | Reminders and lists set in plain words in a chat, with no server to keep running: the router is on anyway. | Scheduling measured as above; reminders set from a chat not yet measured |

**When to choose something else.** For an agent that browses, books, or works on sites
you sign in to, run Hermes on a machine with 2 GB of memory or more; upstream's own
container image carries Chromium. The router can still serve that agent as a narrow,
audited tool provider through [openwrt-mcp](https://github.com/TAIPANBOX/openwrt-mcp).

### Scheduled jobs, in practice

A job can run a script first and hand its output to the model, so a check that needs
no tools costs one model call. A job whose reply is exactly `[SILENT]` sends nothing.
Scripts live in `/srv/hermes/scripts`:

```sh
export HERMES_HOME=/srv/hermes
hermes cron create "0 * * * *" "Below is the router's hourly data. If everything is \
normal, reply with exactly [SILENT]. Otherwise say in two lines what is wrong. Do not \
call any tools." --name router-check --script router_check.sh \
  --deliver telegram:<your numeric id> --reasoning-effort none
```

Leave `--failure-deliver` out, so failures go where `--deliver` sends results. When the
model reports a problem with Hermes's own failure marker the run counts as failed, and
`--failure-deliver local` would keep that alert off your phone (see
[What a test chat shows](telegram.md#what-a-test-chat-shows)).

At one call an hour that is 24 calls a day. If your provider caps free requests per
day, count the same way: one call per scripted check, a few per conversation, and
`grep -c 'API call #' /srv/hermes/logs/agent.log` shows what was actually spent.
Free models are also rate-limited by the providers behind them: on 2026-10-01 two of
three free models with tool support answered 429, and the third,
`nvidia/nemotron-3-super-120b-a12b:free`, called its tool correctly.

`hermes cron run <id>` from an SSH session runs the job in that shell, and the shell has
no Telegram token, by design: the service reads it at exec time and hands it to the
gateway only. A job delivering to Telegram is then refused with "no gateway credentials
configured". To try a job by hand, create a one-off job a few minutes ahead
(`hermes cron create 2m "..." --repeat 1 ...`), and the gateway runs it.

## What it will not do

**It will not run a language model on the router.** The model lives elsewhere and the
router talks to it over the network. A local model here is not slow, it is unusable: the
agent's own system prompt is thousands of tokens, and a router CPU spends minutes reading
it before answering a word. Cortex-A53 in particular is ARMv8.0 with neither dotprod nor
i8mm, exactly the case llama.cpp has no fast path for.

**It will not fit a small router.** About 400 MB of flash on a new router, Python and the
first-run helper included, rules out anything without real storage, and
the gateway wants about 200 MB of RAM before it does any work. Below 1 GB,
run [openwrt-mcp](https://github.com/TAIPANBOX/openwrt-mcp) on the router instead and
keep Hermes on a machine with room. That is the better shape anyway: the router becomes a
narrow, audited tool provider rather than the host of a Python runtime. Measured on
2026-10-04 on an `aarch64_cortex-a53` router with 512 MB of RAM and about 200 MB of free flash:
`apk add openwrt-mcp` from this feed took 4 s and 4 MB of flash, and the daemon, idle,
held 7.4 MB of memory. Hermes on a Flint 2 reached it through `ssh -N -L 8731:127.0.0.1:8730`,
in the assistant profile with its own paired client, granted `ubus_call`, `logread` and
`uci_get` on `system.*`, `network.*` and `iwinfo.*` for a day (see
[Pairing openwrt-mcp yourself](security.md#pairing-openwrt-mcp-yourself)), and answered with that
router's board, hostname and uptime; its audit log shows those three reads and nothing
else. A grant of `ubus_call` on `system.*` would also cover `system.reboot`: grant methods
by name for anything that should stay read-only.

**It will not install packages unless you opt in.** By default no policy the package writes lets
the agent install one, in an unlock window or out of it, so what a change needs from the feed you
install yourself. A WireGuard VPN needs the kernel module and the tools:
`apk add kmod-wireguard wireguard-tools`. Without them the agent can write the interface's
settings, but the interface stays `NO_DEVICE`; on a Flint 2 on 2026-10-08 it did, and the agent
said so.

To let it install them, turn on "Let the agent install packages from the official OpenWrt feed"
under Services -> Hermes Agent -> Security (a factor has to be in force first), or
`uci set hermes.security.packages=official && uci commit hermes && /etc/init.d/hermes-agent restart`.
Then, while you have changes unlocked, the agent can install a package you asked for, from the
official OpenWrt feed only, never from a link, a file or another feed; it runs a dry run first and
tells you what would be installed and how much space that takes. It needs openwrt-mcp 0.5.0.4 or
later, and until then the setting gives the agent nothing and the log says so. What it does and
does not do: [Package installs, your opt-in](security.md#package-installs-your-opt-in).

**Browser, vision, image generation and the wake-word stack are not packaged.** They pull
heavy dependencies for capabilities a headless router does not have. `ffmpeg` is included,
because voice messages and speech transcoding do work here and are cheap.
