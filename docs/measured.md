# Measured on hardware

Every figure in this section was measured on two routers with **Hermes 0.21.5**, the
version the package carries, on 2026-09-25 unless a subsection gives its own date: not in a
container and not on a VM.

![The two routers behind these numbers](boxes.svg)

Both are GL.iNet hardware running **vanilla OpenWrt 25.12.5**, not the vendor firmware
they ship with. They are the two routers the measurements in this section come from, chosen
as two form factors doing the same job (a Beryl AX, the third test router, is the case of a
router with 512 MB and little flash, under [Hermes on a USB stick](usb.md#hermes-on-a-usb-stick)): the Flint 2 is a Wi-Fi 6 router with four cores and six
ports, and the Brume 2 is a wired-only gateway with two cores, closer to what a small
always-on box looks like. Before each run the router was cleaned of every trace of the
package, Python and ffmpeg included, and put back exactly as it was afterwards.

| | GL-MT6000 (Flint 2) | GL-MT2500 (Brume 2) |
|---|---|---|
| SoC | MT7986, 4x Cortex-A53 | MT7981, 2x Cortex-A53 |
| RAM / free flash | 1 GB / 6.8 GB | 1 GB / 6.8 GB |
| `apk add hermes-agent luci-app-hermes`, from nothing | 17 s, 46 packages | 48 s, 45 packages |
| package tree (`/usr/lib` and `/usr/share/hermes-agent`) | 239 MB | 239 MB |
| `hermes --version`, cold | 2 s | 3 s |
| gateway resident | 179 MB | 178 MB |
| one conversation, end to end | 18 s | 25 s |
| six conversations at once | 25 s, all answered | 30 s, all answered |
| all of Hermes at six, memory | 361 MB | 379 MB |
| temperature, fanless | 51 to 52 C | 45 to 47 C |

A conversation here is a real diagnosis: the model (`openai/gpt-4o-mini` on OpenRouter)
runs five commands through the terminal tool and answers from what they printed. The
wall clock is mostly the model's own time.

![Measured on hardware](measured.svg)

## Re-run on the published release, 2026-10-04

The same two routers, with the package, Python, ffmpeg and their configuration removed first
and earlier data moved aside, then the [Install](../README.md#install) block above run as written
against the published feed (agent 0.21.5-r5, LuCI 0.21.5-r1, openwrt-mcp from the fork).
Afterwards their configuration, keys and data were put back as found, and the packages left
at the published release. The model this time was `gpt-5.6-luna` through a ChatGPT
subscription, and a turn here is one agent turn in a test process inside the service's
memory group, without the gateway or Telegram in front of it, so the times are not
comparable with the table above, which used `gpt-4o-mini`.

| | Flint 2 | Brume 2 |
|---|---|---|
| key, feed line, `apk update && apk add hermes-agent luci-app-hermes` | 24 s, 47 packages | 64 s, 50 packages |
| then `apk add hermes-agent-telegram` | 2 s | 2 s |
| flash, agent and LuCI page / with Telegram / after the first start | 345 / 357 / 396 MB | 343 / 354 / 393 MB |
| gateway resident, 90 s after the first start | 202 MB | 203 MB |
| `kill -9` of the gateway: procd has it back | 9 s | 10 s |
| `reboot` with the service enabled: gateway running by | 26 s after boot | 21 s after boot |
| one agent turn | 25 s | 32 s |
| six turns at once: the slowest, and all six | 24 s, 32 s, all answered | 36 s, 46 s, all answered |
| all of Hermes at six (cgroup, page cache included) | 400 MB | 453 MB |
| temperature, fanless | 44 to 45 C | 42 to 44 C |

Also on the Brume 2 that day: a change made through openwrt-mcp in an unlock window and not
confirmed, then a reboot, the sequence that preceded the 2026-10-02 failure: back in 33 s,
and openwrt-mcp rolled the change back at start ("unconfirmed apply ... found at startup,
rolling back"). A script made the unlock and the change with the agent's own openwrt-mcp
client, not the agent and not `/unlock` from Telegram. Web search with a free model
(`nvidia/nemotron-3-super-120b-a12b:free`) and no web API key: `web_search` (upstream's
keyless Firecrawl tier), then `web_extract` on the page it found (Keenable's anonymous
tier), three model calls and 45 s from a cold start; it gave the newest upstream release,
v2026.9.24, as GitHub reports it. Through the ChatGPT subscription the same question took
one model call and no Hermes tool, cited OpenAI's own search, and named an older release.

`hermes chat` run from an SSH shell has neither the model's key nor the router token: the
service hands both to the gateway only. A question to the agent from a shell is refused by
the provider (HTTP 401) and its openwrt-mcp calls by the daemon. Ask through Telegram, or
create a one-off job, which the gateway runs (see [Scheduled jobs, in practice](use.md#scheduled-jobs-in-practice)).

## How many agents fit alongside your other services

A box with WireGuard, Tailscale and the usual packages still has to run all of them, so
the number that matters is what Hermes takes while working, not while idle. Measured on
2026-10-03 on both routers, the same task each time, with `gpt-5.6-luna` through a
ChatGPT subscription. There are two ways to run more than one agent, and they cost very
differently:

![How many agents fit on a 1 GB router](concurrency.svg)

- **Conversations in one gateway**, which is how the Telegram gateway serves several
  chats: each is a thread of the process that is already running. One to four at once
  all answered, and all of Hermes stayed flat at 388 MB on the Flint 2 and 445 MB on the
  Brume 2, whose gateway also carries the Telegram add-on. The 2026-09-25 run took six
  at once with the same flat line.
- **Separate agents**, such as a second `hermes chat` or a gateway for another profile:
  each is its own Python interpreter, about 140 MB. Under the default 512 MB ceiling two
  fit. A third fills the ceiling, and since the service's memory group is ended as a
  whole, the gateway goes with it; procd started it again (27 s on the Brume 2), and the
  router kept 286 MB or more available throughout.
- **With the ceiling lifted** (`mem_max_mb=0`) on clean OpenWrt, with Tailscale and every
  other non-OpenWrt service stopped for the run: three separate agents fit, leaving 201
  to 216 MB. A fourth took the router under 120 MB, where the test stopped the agents
  before the kernel had to choose. With Tailscale and the lab's services left running,
  three still fit, leaving 170 to 182 MB.

So plan on conversations rather than agents: one gateway serves many chats for the price
of one. Run separate agents only with the ceiling raised, and no more than three on 1 GB.
Cores buy wall clock rather than capacity. The harness is in `scripts/fit/` and the raw
summaries are in `docs/measurements/2026-10-03/`.

## Under the router's own work

Measured on 2026-09-25, with the same conversations running while the router did its
real job:

- **Flint 2, carrying a house's internet as a transparent bridge.** A 25 MB download
  through it ran at 340 to 400 Mbit/s with Hermes idle, 336 to 384 with one
  conversation, 438 to 458 with three and 401 to 406 with three at nice 10: the line's
  own variation, not Hermes. The kernel dropped no packets, the four cores stayed 70 to
  75% idle while the model was thinking, and the house's latency to the internet held a
  median of 11 ms over 511 seconds with no loss.
- **Brume 2, carrying a WireGuard tunnel at 574 Mbit/s.** A conversation running at the
  same time took about a quarter of the tunnel's throughput (414 and 404 Mbit/s with one
  and three), and less at nice 10 (439 Mbit/s), which is why the service runs at nice 10.
  Latency through the tunnel stayed at 4 to 6 ms on average, with no loss.

One run per step.

## Which models can actually drive it

The package is provider-agnostic, so the useful question is which models can call a tool
rather than talk about calling one. The same task for each, one turn, on the Brume 2
through OpenRouter: read `/proc/uptime` with the terminal tool and give the uptime in
minutes. "Called the tool" is counted from the turn's own messages, and "right" is the
answer checked against the router's uptime.

![Which models can call a tool on the router](models.svg)

The same runs as text, since a picture is not greppable:

| Model | Called the tool | Right | Wall clock | Note |
|---|---|---|---|---|
| `anthropic/claude-haiku-4.5` | yes | yes | 18 s | |
| `google/gemini-2.5-flash` | yes | yes | 4 s | |
| `openai/gpt-4o-mini` | yes | yes | 7 s | |
| `moonshotai/kimi-k2-0905` | yes | yes | 11 s | |
| `deepseek/deepseek-chat-v3.1` | yes | yes | 16 s | three calls where one would do |
| `qwen/qwen3-8b` | yes | yes | 14 s | 8B, and it works |
| `mistralai/mistral-small-3.2-24b-instruct` | yes | yes | 4 s | |
| `meta-llama/llama-3.3-70b-instruct` | cut off | no | 15 s | ran out of output tokens mid-call; Hermes refused to run the half-written command |
| `google/gemma-3-12b-it` | **no** | no | 5 s | printed the call as JSON text |

The floor is native tool calling, not parameter count: an 8B model works, a 12B model
without tool support does not, and a 70B one can still fail on the output limit its
provider sets. Pick for function calling, not for size.

One provider note: OpenRouter and any OpenAI-compatible endpoint work as the main
provider, Anthropic's own included: its OpenAI-compatible endpoint takes an Anthropic key
(`https://api.anthropic.com/v1`, measured 2026-09-25). As a further provider, below,
Anthropic runs on upstream's native transport, which the package now carries.

## Two defects the hardware found

Neither was visible in a container or on x86, which is the whole argument for running on
the thing itself.

**`bash` is required, and was not declared.** Hermes builds its shell commands with
`builtin cd`, which BusyBox `ash` does not have, so on a stock OpenWrt image every single
command the agent ran failed with `/bin/ash: builtin: not found` and exit 126. The model
does not recover from this; it reports the environment as broken and gives up. `bash` is
now a declared dependency and the gates check for it.

**The key reached procd's service table.** The init handed it over with
`procd_set_param env`, and procd returns its whole environment to anyone who can ask
`ubus call service list`, which rpcd ACLs can extend to a LuCI session. argv and uci were
clean, which is what the older checks looked at. The key is now read by a small wrapper
at exec time, so it exists only in the process's own environment, and
`check_key_not_in_procd_env` fails the build if it ever appears in the service table
again.

## The service controls, on both routers

On 2026-09-25 the controls described under "Letting it touch the router" were checked on
real procd on both routers, with 0.21.5 freshly installed:

- procd holds the bounded respawn (3600 s, 5 s, 5 retries), and the key does not appear
  in `ubus call service list`.
- `mem_max_mb=256` reaches the kernel: `memory.max` 268435456, `memory.swap.max` 0.
- A model saved the way a chat's `/model ... --global` saves it, then `kill -9`: procd
  had the gateway back in 9 s on the Flint 2 and 10 s on the Brume 2, with the model,
  provider and endpoint from UCI in place again.
- `mem_max_mb=0` and a restart: `memory.max` and `memory.swap.max` read `max`.
- With the key file removed and the gateway killed, procd started it five more times,
  each start was refused and logged, and procd then left the service stopped.
- From start to the gateway's own exec takes 4 s on the Flint 2 and 5 s on the Brume 2.

The Flint 2 carried the house's internet the whole time. A machine in the house pinged
the house router and 1.1.1.1 once a second throughout, 511 times each, lost none, and
the internet median stayed at 11 ms.
