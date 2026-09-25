<div align="center">

![hermes-openwrt: Hermes Agent as a native OpenWrt service, not Docker and not a chroot](docs/banner.svg)

# hermes-openwrt

[**Hermes Agent**](https://github.com/NousResearch/hermes-agent) packaged for the router
it runs on: an `apk` for OpenWrt 25.12, a signed feed, a LuCI page,
and figures measured on hardware rather than in a container.

[![ci](https://github.com/TAIPANBOX/hermes-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/TAIPANBOX/hermes-openwrt/actions/workflows/ci.yml)
![OpenWrt 25.12](https://img.shields.io/badge/OpenWrt-25.12-2dd4bf)
![Hermes 0.21.5 on Python 3.13](https://img.shields.io/badge/Hermes%200.21.5-Python%203.13-4493f8)
![signed feed](https://img.shields.io/badge/feed-signed-3fb950)
![license MIT](https://img.shields.io/badge/license-MIT-9aa7b8)
![tested on two routers](https://img.shields.io/badge/hardware-two%20routers%2C%20measured-3fb950)

</div>

![The agent runs on the router, the model runs elsewhere, and the router itself is reached through a narrow audited window](docs/hero.svg)

## The fact everything here rests on

One thing had to be measured rather than assumed, because it decides between a native
package and a 950 MB container image:

> **pip on OpenWrt resolves musllinux wheels, and every wheel Hermes needs exists.**

On `openwrt/rootfs:aarch64_generic-25.12.4`, `pip debug --verbose` reports
`cp313-cp313-musllinux_1_2_aarch64` as its top tag. A `pydantic-core` wheel, which is
compiled Rust, installs and imports and validates. For Hermes 0.21.5 the router profile
is 77 packages in under 30 seconds with nothing compiled and no toolchain present.

So Hermes does not need to be built for OpenWrt. It needs to be assembled for it, and
that is what this repository does.

### Which Hermes, and from where

The package carries **Hermes 0.21.5** (upstream tag `v2026.9.24`). PyPI stops at 0.19.0,
and upstream's own `setup.py` now refuses to build a wheel anywhere but inside its Nix
build, so the package is built the way that Nix build does it:

- from the archive of one pinned upstream commit, whose checksum is checked before a byte
  is unpacked (`package/upstream/upstream.env`);
- every library at the version upstream's `uv.lock` names at that commit, not whatever
  PyPI serves that day;
- skills, optional skills, translations and the MCP catalogue beside the wheel, under
  `/usr/share/hermes-agent`, found through the same `HERMES_BUNDLED_*` variables upstream's
  Nix wrapper sets.

Two upstream dependencies are left out, about 49 MB of an unpacked 278 MB: NVIDIA's Relay
runtime (`nemo-relay`), for which upstream falls back to a no-op host, and the HEIC/AVIF
image decoder (`pillow-heif`), which upstream imports only if it is there. Everything else
upstream depends on ships. The router records what it carries in
`/usr/lib/hermes-agent/upstream`, and `gate-upstream.sh` checks all of it.

## Install

### OpenWrt 25.12

```sh
wget -O /etc/apk/keys/hermes-openwrt.pem \
  https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.pem

echo "https://taipanbox.github.io/hermes-openwrt/25.12/$(cat /etc/apk/arch)/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list

apk update && apk add hermes-agent luci-app-hermes

# and, to reach it from a phone:
apk add hermes-agent-telegram
```

OpenWrt 24.10 is not served: the package is built and tested for 25.12 only.

No `--allow-untrusted` and no `--force` anywhere. That is the point of signing the feed.

## Measured on hardware

Every figure in this section was measured on two routers with **Hermes 0.21.5**, the
version the package carries, on 2026-09-25: not in a container and not on a VM.

![The two routers behind these numbers](docs/boxes.svg)

Both are GL.iNet hardware running **vanilla OpenWrt 25.12.5**, not the vendor firmware
they ship with. They are the two routers this package is tested on, chosen as two form
factors doing the same job: the Flint 2 is a Wi-Fi 6 router with four cores and six
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

![Measured on hardware](docs/measured.svg)

### What fits alongside your other services

A box with WireGuard, Tailscale and the usual packages still has to run all of them, so
the number that matters is what Hermes takes while working, not while idle.
Conversations were run the way the gateway runs them, as threads of one process inside
the service's own memory group, one, two, four and then six at once:

![How many conversations fit on a 1 GB router](docs/concurrency.svg)

The gateway takes about 180 MB and stays there. Conversations on top of it cost little:
all of Hermes peaked at 361 to 384 MB whether one conversation ran or six, the kernel
killed nothing, and the router kept 270 MB or more of memory available throughout.
The gateway was the same process with the same 179 MB after all four runs. The
service's own 512 MB ceiling never came into play. Cores buy wall clock rather than
capacity: six conversations took 25 s on four cores and 30 s on two.

### Under the router's own work

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

### Which models can actually drive it

The package is provider-agnostic, so the useful question is which models can call a tool
rather than talk about calling one. The same task for each, one turn, on the Brume 2
through OpenRouter: read `/proc/uptime` with the terminal tool and give the uptime in
minutes. "Called the tool" is counted from the turn's own messages, and "right" is the
answer checked against the router's uptime.

![Which models can call a tool on the router](docs/models.svg)

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

### Small flash: put the data directory on a USB stick

On a router that has never had Hermes, the install also brings Python, ffmpeg and ripgrep
from OpenWrt's own feed. Measured on 2026-09-25 on both routers, from a router cleaned of
every trace of the package: the agent and its web page took 332 MB of flash on the
Brume 2 and 337 MB on the Flint 2, 343 and 348 MB with the Telegram add-on. The first
start then puts 37 MB into the data directory, 32 MB of it a helper (`tirith`) the agent
downloads, which makes 382 and 387 MB in all. Sessions, memory and a SQLite journal grow
there from then on, so budget at least 400 MB plus room to grow. On a router with 8 MB or
128 MB of flash that does not fit, and even where it fits, the writes land on the same
flash the firmware lives on.

![Moving the data directory to a USB stick](docs/usb.svg)

```sh
apk add kmod-usb-storage kmod-fs-ext4 block-mount e2fsprogs

mkfs.ext4 -F -L hermes-data /dev/sda1
mkdir -p /mnt/usb && mount /dev/sda1 /mnt/usb
/etc/init.d/hermes-agent stop
cp -a /srv/hermes/. /mnt/usb/ && umount /mnt/usb

uci set fstab.hermes=mount
uci set fstab.hermes.uuid="$(block info /dev/sda1 | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)"
uci set fstab.hermes.target='/srv/hermes'
uci set fstab.hermes.options='rw,noatime'
uci set fstab.hermes.enabled='1'
uci commit fstab && /etc/init.d/fstab boot
/etc/init.d/hermes-agent start
```

### Two defects the hardware found

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

### The service controls, on both routers

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

## The web interface

`luci-app-hermes` adds **Services -> Hermes Agent**: an overview with service state,
version, free space where the data lives, which keys are set and a live log tail, and a
settings page for the endpoint, the model, the keys, router access, Telegram and toolsets, and a
Providers page for the further providers and a ChatGPT subscription.

It looks like every other LuCI page, and two things about it are not cosmetic.

**The key fields are write-only.** They read `stored`, never a key: the page can store one
and can ask whether one exists, and no method returns one, which is the next section.

**The log tail is the only way to see the service without SSH**, and it is not decoration.
The worst defect this package ever shipped, a flag the CLI rejects that killed the service
at argument parsing on every start, was found by opening that box in a browser after weeks
of green gates. There is a check for it now.

## Keys go in and do not come out

![The settings page can write a key and can ask whether one is present; nothing returns one](docs/security.svg)

A key put in UCI is world-readable, printed in full by `uci show`, and present in every
support bundle. So keys live in root-only files under `/etc/hermes-agent`, and the fields
are write-only: the page can store one and can ask whether one exists, and no method
returns one.

`scripts/gate-luci.sh` asserts that rather than trusting it. It writes a canary through
the RPC and then requires that no readable method mentions it.

The page manages the three key files in `/etc/hermes-agent`. If UCI points the service
at a different file, the page says so and does not write its own slot, and a write that
fails is reported as not saved. Read-only access to the page covers its status and log
calls and its own UCI configuration, and nothing else: not procd's service list, where a
service's environment can be read, and no file on the router.

## More than one provider

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
the same address as the main model is switched to with the main key, which is what
upstream does for an endpoint it is already using, so a second account on the main
model's own service does not work as a further provider.

A ChatGPT subscription needs no section. Allow device code sign-in once in ChatGPT's
security settings, then:

```sh
hermes-login chatgpt
```

It prints a code to enter at `auth.openai.com/codex/device`, in a browser signed in to
ChatGPT; the tokens stay in the agent's data directory, readable by root only, and no
password passes through the router. ChatGPT then shows up in `/model`.

**Anyone the bot answers can switch their chat to any provider listed here**, including
keys that cost money per call. The allowlist is the boundary, as it is for everything
else the agent can do. **Services -> Hermes Agent -> Providers** does all of this from the
browser: it adds and removes providers, takes each key write-only like the main one,
deletes a provider's key along with the provider, and signs ChatGPT in and out, showing
the address and the code to enter.

## Reaching it from a phone

![A phone talks to Telegram, the router polls Telegram outbound, and an allowlist decides who is answered](docs/telegram.svg)

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

### Why the service refuses to start with an empty allowlist

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

### Why it is a separate package

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

## The signed feed

The index (`packages.adb`) and every package in it are signed with an EC prime256v1 key
through `apk adbsign`; the router trusts it through `/etc/apk/keys/hermes-openwrt.pem`.
An untrusted feed is refused in silence: apk drops the repository, so the package merely
appears not to exist.

**Signing happens on a workstation, not in CI.** A key held as a repository secret is
readable by anyone who can push a workflow to the default branch, and this one cannot be
revoked: a router that has trusted the public half keeps trusting anything signed with the
private half until a person logs in and deletes the file. So CI builds and gates, and
`scripts/publish-feed.sh` signs and publishes from the machine where the key lives.

## How a package is built

![Upstream, built inside the target release, one shim, packaged, signed locally](docs/build.svg)

```sh
# 25.12, Python 3.13. EXTRA_ARCHES relabels the same tree for the Flint 2 and Brume 2.
EXTRA_ARCHES=aarch64_cortex-a53 ./package/hermes-agent/build-in-container.sh aarch64_generic
```

Docker is required; the OpenWrt SDK is not. The build runs **inside** the OpenWrt release
it targets, so the libc resolving the wheels is the one the router has. Cross-downloading
with `pip --platform` looks simpler and does not work: `pydantic-core` ships stable-ABI
wheels tagged `cp39-abi3`, and pinning `--implementation cp --python-version 3.13` narrows
the tag set until pip reports no matching distribution for a wheel that plainly exists.
`build.sh` refuses to run on a glibc interpreter rather than produce a package that would
only fail on the device.

### The one shim

OpenWrt splits the standard library into packages and ships no `webbrowser` at all, the
same way it ships no `tkinter`. Without it the CLI cannot print its own version. The shim
implements the real contract rather than a stub: `open()` returns `False`, which is the
honest answer on a machine with no screen and the one upstream's own headless path
expects, and the URL is logged so a pairing step is still completable by hand.

Everything else Hermes needs is already packaged by OpenWrt: sqlite3, ssl, ctypes,
asyncio, multiprocessing, email, http, xml, decimal, curses, readline.

## What it will not do

**It will not run a language model on the router.** The model lives elsewhere and the
router talks to it over the network. A local model here is not slow, it is unusable: the
agent's own system prompt is thousands of tokens, and a router CPU spends minutes reading
it before answering a word. Cortex-A53 in particular is ARMv8.0 with neither dotprod nor
i8mm, exactly the case llama.cpp has no fast path for.

**It will not fit a small router.** About 400 MB of flash on a new router, Python and the
first-run helper included, rules out anything without real storage, and
the gateway wants about 180 MB of RAM before it does any work. Below 1 GB,
run [openwrt-mcp](https://github.com/GlassOnTin/openwrt-mcp) on the router instead and
keep Hermes on a machine with room. That is the better shape anyway: the router becomes a
narrow, audited tool provider rather than the host of a Python runtime.

**Browser, vision, image generation and the wake-word stack are not packaged.** They pull
heavy dependencies for capabilities a headless router does not have. `ffmpeg` is included,
because voice messages and speech transcoding do work here and are cheap.

## Letting it touch the router

<!-- @codex 2026-09-19 -->
**The service runs as root.** Its default file and terminal tools can read and change
router configuration directly. Give access only to trusted operators on a spare test
router. Disabling MCP does not remove this local access.

Two profiles decide how much of that access the agent actually has. **admin** is the
default wherever the option is not set, which includes a router whose configuration
predates it, and leaves every tool the toolsets list selects in place, running as root
as described above. **assistant** turns the terminal, code execution and file tools off
regardless of what that list selects, and tells the agent so: it can still chat, keep
memory and schedule reminders, and it reaches the router only through an MCP server
such as openwrt-mcp, if one is configured, never directly. Choose it in
**Services -> Hermes Agent -> Settings -> Profile**, or from the command line:

```sh
uci set hermes.main.profile=assistant && uci commit hermes && /etc/init.d/hermes-agent restart
```

A value other than `assistant` or `admin` refuses to start rather than guess which was
meant. An upgrade leaves the router's own configuration file alone, so a router whose
file names a profile keeps it; that includes the `assistant` line the previous release
wrote into a new install. Starting the service prints which profile applies, and in
assistant the command that switches it.

One turn makes at most 20 model calls with tools (`hermes.main.max_turns`, 1 to 500),
and a turn that reaches the limit gets one more, without tools, to sum up what it found.
Upstream allows 90, and on 2026-09-24 a bot in the assistant profile, asked for something
it had no tool for, spent all 90 before it answered. The same day, with this revision on
both routers and each asked for its own uptime: in admin it ran `uptime` and answered in
two model calls; with the limit set to 1 it stopped after the first call, which had
already run `uptime`, and the summary answered from that; in assistant, told what it
cannot do, it said so at once, in one call.

The optional [openwrt-mcp](https://github.com/GlassOnTin/openwrt-mcp) connection adds
policy checks to calls sent through that server. Its policy does not constrain local
file, terminal, plugins or delegated tools. Pair once on the router and grant a narrow,
expiring window. openwrt-mcp refuses every tool it has not been granted, so a connection
without a grant does nothing:

```sh
openwrt-mcp pair hermes > /etc/hermes-agent/router-mcp.token
chmod 600 /etc/hermes-agent/router-mcp.token
openwrt-mcp allow hermes ubus_call,logread 'network.* iwinfo.* system.*' 30d
```

Then set its URL in UCI or LuCI. The package writes `mcp_servers.openwrt` into Hermes
config with an environment placeholder; the token is read at exec time and never stored
in YAML or procd's table. An `openwrt` entry of the operator's own is preserved and
startup is refused until it is renamed, unless it is identical to the entry the package
writes, which is then adopted. If the token file is missing when the gateway starts, it
starts without this connection and says so in the log. Clearing the URL removes only the
package-managed entry.

UCI also selects the primary model and OpenAI-compatible endpoint through
`model.default`, `model.base_url` and `model.provider` in Hermes config. They are
written again before every start, including the restarts procd makes on its own, so a
model switched from a chat lasts until the next start. Credentials remain environment
references. Conflicting `.env`, named provider, credential pool
or Authorization-header settings refuse startup; existing credentials are preserved
for the operator to reconcile. Explicit job/channel overrides and fallback chains
retain their upstream behavior.

The UCI tool list sets `platform_toolsets.telegram` and `platform_toolsets.cron`.
Empty means no selected default families. Upstream per-job tool overrides and
separately configured plugins or MCP servers still apply. This selection is not an
OS sandbox. Invalid YAML or tool names stop startup instead of loading a broader set.

`mem_max_mb` requires writable **cgroup v2 memory control**. Before every launch,
the wrapper verifies its dedicated procd cgroup, applies `memory.max`, disables swap
for that group and enables group OOM termination. Unsupported firmware refuses to
start with an explanation. Setting `mem_max_mb=0` explicitly accepts an unlimited
process and lifts a ceiling an earlier start applied. This ceiling protects against
accidental memory growth; root tools can modify system controls. Verify the controller
on the target router before testing.

procd retries a gateway that fails at start at most five times within an hour and then
leaves it stopped, so a refusal is logged a handful of times rather than every five
seconds. It also runs the service at nice 10, so the router's own work keeps the
processor; "Under the router's own work" above has the measurement.

## What is checked, and how

Nothing here is verified by reading the archive. Every gate installs the package into
OpenWrt's own published rootfs and then asks the running system.

| gate | what it proves |
|---|---|
| `gate-package.sh` | 11 checks: apk installs it with every dependency including `bash`, the CLI runs, it ships disabled, it refuses without a key, **the command the init hands procd actually starts and stays up**, the key reaches neither argv nor UCI nor **procd's service table**, config survives reinstall, removal is clean |
| `gate-luci.sh` | 24 checks: files land where luci-base looks, the views parse, menu and ACL are valid JSON, the rpcd backend answers on ubus, reads the agent's version from disk without starting it, and, before the first start, reports the free space where the data will go, a written key lands 0600, the page can tell a missing package from a missing token, **no method returns a key**, the read permission is exactly the page's two calls and its UCI config, a failed write is reported, and the page will not write a slot the service does not read; on the Providers page a provider's key lands 0600 in its own slot, a crafted name writes nothing, a key file set elsewhere is refused, and ChatGPT signs in and out with the call returning at once; an upgrade restarts rpcd, as an install does; and the installed pages' own JavaScript, run against a stand-in for LuCI, deletes a provider's key with the provider and keeps what it says across the reload that follows a sign-in, or Save & Apply once LuCI reports the apply went through, dropping what is older than ten minutes, and says "Saved" at once, once, for a Save & Apply that changed only a key, which LuCI neither announces nor reloads for |
| `gate-feed.sh` | 3 checks: refused without the key, installs with it, no `--allow-untrusted` needed |
| `gate-upstream.sh` | 7 checks: built from the pinned upstream commit and archive, reports that version, every library at its `uv.lock` version, `nemo-relay` and `pillow-heif` absent with nothing else missing, the Relay host falls back to upstream's no-op, skills, translations and the MCP catalogue found under `/usr/share/hermes-agent`, the platform plugins shipped |
| `gate-telegram.sh` | 8 checks: the base alone cannot import telegram, the add-on installs beside it, neither package claims a file the other owns, the library imports, and the service refuses in each of the three ways a Telegram setup can be incomplete |
| `gate-runtime.sh` | 49 tests against the installed upstream payload: actual model HTTP response, platform tool defaults, MCP configuration, credential handover, UCI re-applied after a model switched from a chat, override refusals, bounded respawn, kernel-enforced memory limits including lifting one, the two profiles and what the assistant is told, the per-turn limit on model calls, and further providers: what upstream resolves and /model offers, their keys, names and ownership |
| `teeth-runtime.py` | 44 product mutations must fail their named test; missing subjects refuse verification and the restored product must pass |
| `gate-scenarios-bound.sh` | every scenario in `features/` names a check that runs, and every check is described by a scenario |
| `gate-named-routers.sh` | the tracked tree names no router but the two it is tested on, by name or by model number |
| `teeth.sh` | plants five faults and requires a different check to catch each one |
| `teeth-upstream.sh` | seven faults, one per check: another commit recorded, the agent's metadata saying 0.21.4, a library off its locked version, `nemo-relay` back, the Relay fallback raising, the translations variable forgotten, the Telegram plugin manifest missing |
| `teeth-telegram.sh` | four more: a colliding file, a missing library, and two refusals cut out of the init script |
| `teeth-luci.sh` | seventeen for the web page: procd's service list back in the read permission, a file read grant beside it, the failed-write check removed, the refusal to write a slot the service does not read removed, the free space measured on the missing data directory again, a provider slot that takes any name, ChatGPT reported as signed in regardless, a sign-in run in the foreground, a package without its post-upgrade script, the version read by running Hermes again, a provider deleted without its key, a message not kept across the reload, an old message shown anyway, a Save & Apply message kept before the apply went through, a key-only Save & Apply that never says it saved, a leftover message shown twice, and "Saved" beside a key that did not save |
| `teeth-named-routers.sh` | a box named by name and one named by model number must fail, the two test routers must pass, and nothing to read must refuse |

`teeth.sh` earns its place. Its first run found a real defect in this repository rather
than in the harness: a package built with one `.pyc` missing writes that bytecode at
runtime into its own installed directory, apk does not own the file, and `apk del` then
leaves all 193 MB behind.

The newest check is there because of a worse one. The service was passing `--toolsets`
to `hermes gateway run`, which does not accept it, so it died at argument parsing on
every start with the configuration this package ships. Every gate was green: the package
installed, the CLI ran, the service refused politely without a key. Nothing had ever run
the command line the init builds. It was found by opening the web interface and reading
the log box, which is the one thing no gate here does.

Hardware added the same lesson twice more. A container has `bash`, so no gate could see
that the agent's shell tool is unusable without it; a container has no procd, so no gate
could see the key in the service table. Both now have checks, and the rule they teach is
the same one: a gate proves what it was pointed at, and a router is not a container.

## Status

- [x] Native package for OpenWrt 25.12 (apk); 24.10 was served until 2026-09-25 and is not any more
- [x] Hermes 0.21.5 from a pinned upstream commit, libraries at upstream's locked versions
- [x] `aarch64_cortex-a53` for the Flint 2 and Brume 2, plus `aarch64_generic`
- [x] LuCI interface with write-only key handling
- [x] Signed feed, signed on a workstation
- [x] Every gate runs on OpenWrt's own rootfs images in CI
- [x] **Run on real hardware.** Two GL.iNet routers on vanilla OpenWrt 25.12.5; see the figures above
- [x] **Service controls on real procd**: bounded respawn, the memory ceiling and its removal, UCI back in place after a crash (Flint 2 and Brume 2, 25.12.5)
- [x] **A full agent turn on a router**, model calling a tool and answering from what it read
- [x] **Measured under load** on 0.21.5: concurrent conversations, thermals, throughput through the router
- [x] **The feed installs on hardware** with its signature verified and no `--allow-untrusted`
- [x] Telegram, as a two-distribution add-on package
- [x] Two profiles, admin by default and assistant by choice, governing terminal, code execution and file tools
- [x] A per-turn limit on model calls, set on the router
- [x] Several providers at once, each chat on the one it picks, a ChatGPT subscription included
- [x] Upstream's native Anthropic provider
- [x] A Providers page: further providers with write-only keys, ChatGPT sign-in and sign-out
- [ ] Track upstream releases automatically, which arrive every two to four days

## Prior art, and what is not ours

[`Dedrimer/hermes-openwrt`](https://github.com/Dedrimer/hermes-openwrt) is an independent
native port that arrived at the same `webbrowser` shim from the same wall. It carries no
licence file, so no code from it is used here; the overlap is two people meeting the same
constraint.

[`GlassOnTin/openwrt-mcp`](https://github.com/GlassOnTin/openwrt-mcp) is the router-side
MCP server this pairs with, and its apk packaging for OpenWrt 25.12 came from
[a pull request out of this work](https://github.com/GlassOnTin/openwrt-mcp/pull/1).

Hermes Agent is Nous Research's and is MIT licensed. This repository is not affiliated
with them; the packaging is what is new here, and it is MIT too.
