<div align="center">

# hermes-openwrt

**[Hermes Agent](https://github.com/NousResearch/hermes-agent) as a native OpenWrt service.**
Not Docker. Not a chroot. An `apk` or an `ipk` that installs into a private site-packages
and runs under procd.

[![ci](https://github.com/TAIPANBOX/hermes-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/TAIPANBOX/hermes-openwrt/actions/workflows/ci.yml)
![OpenWrt 25.12 and 24.10](https://img.shields.io/badge/OpenWrt-25.12%20%C2%B7%2024.10-2dd4bf)
![Python 3.13 and 3.11](https://img.shields.io/badge/Python-3.13%20%C2%B7%203.11-4493f8)
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
compiled Rust, installs and imports and validates. The router profile is 69 packages in
22 seconds with nothing compiled and no toolchain present. On 24.10 the same holds with
`cp311`.

So Hermes does not need to be built for OpenWrt. It needs to be assembled for it, and
that is what this repository does.

## Install

### OpenWrt 25.12 and later (apk)

```sh
wget -O /etc/apk/keys/hermes-openwrt.pem \
  https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.pem

echo "https://taipanbox.github.io/hermes-openwrt/25.12/$(cat /etc/apk/arch)/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list

apk update && apk add hermes-agent luci-app-hermes

# and, to reach it from a phone:
apk add hermes-agent-telegram
```

### OpenWrt 24.10 (opkg)

```sh
ARCH=aarch64_cortex-a53          # GL.iNet Flint 2 and other Cortex-A53 routers
# ARCH=x86_64                    # x86 boxes
# ARCH=aarch64_generic           # other 64-bit ARM

wget -O /tmp/hermes.pub https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.usign.pub
opkg-key add /tmp/hermes.pub

echo "src/gz hermes https://taipanbox.github.io/hermes-openwrt/24.10/$ARCH" \
  >> /etc/opkg/customfeeds.conf

opkg update && opkg install hermes-agent luci-app-hermes

# and, to reach it from a phone:
opkg install hermes-agent-telegram
```

No `--allow-untrusted` and no `--force` anywhere. That is the point of signing the feed.

## Measured on hardware

Those four lines install it. This section is what happened when they were run on actual
routers rather than in CI, which until 2026-09-13 had never been done: everything the
repository claimed was true of container images. Two boxes changed that, and every figure
below comes from them.

![The two routers behind these numbers](docs/boxes.svg)

Both are GL.iNet hardware running **vanilla OpenWrt 25.12.5**, not the vendor firmware
they ship with: the stock image was replaced entirely, over the network, and the package
was installed from the signed feed exactly as the instructions above describe. The Flint 2
is a Wi-Fi 6 router with four cores and six ports; the Brume 2 is a wired-only box with
two cores, which is the interesting case here because it is closer to what a small
always-on gateway looks like.

| | GL-MT6000 (Flint 2) | GL-MT2500 (Brume 2) |
|---|---|---|
| SoC | MT7986, 4x Cortex-A53 | MT7981, 2x Cortex-A53 |
| RAM / free flash | 1 GB / 6.8 GB | 1 GB / 6.8 GB |
| `apk add hermes-agent luci-app-hermes` | 16 s | 48 s |
| installed tree | 185 MB | 185 MB |
| `hermes --version`, cold | 3 s | 4 s |
| gateway resident | 128 MB | 131 MB |
| one agent task, end to end | 25 s | 33 s |

![Measured on hardware](docs/measured.svg)

### What fits alongside your other services

A box with WireGuard, Tailscale and the usual packages still has to run all of them, so
the number that matters is what Hermes takes while working, not while idle. Concurrency
was pushed until something broke:

![How many agents fit on a 1 GB router](docs/concurrency.svg)

Two things that were worth checking and turned out fine. **Routing is not disturbed**:
iperf3 across the box measured 938 Mbit/s idle and 931 Mbit/s while three agents were
working, which is inside the noise. **Nothing leaks over a run**: eight sequential
sessions moved the gateway's resident memory from 108688 kB to 108716 kB, and each
session still took its usual 24 s. Temperature never left the 39 to 43 C band on either
box, fanless, with no throttling.

### Which models can actually drive it

The package is provider-agnostic, so the useful question is which models can call a tool
rather than talk about calling one. Same task on the same box, through OpenRouter:

![Which models can call a tool on the router](docs/models.svg)

The same runs as text, since a picture is not greppable:

| Model | Called the tool | Wall clock | Note |
|---|---|---|---|
| `anthropic/claude-haiku-4.5` | yes | 25 s | reference |
| `google/gemini-2.5-flash` | yes | 25 s | clean |
| `openai/gpt-4o-mini` | yes | 24 s | clean |
| `moonshotai/kimi-k2-0905` | yes | 25 s | clean |
| `deepseek/deepseek-chat-v3.1` | yes | 34 s | leaks its reasoning into the reply |
| `qwen/qwen3-8b` | yes | 43 s | slowest that still works |
| `mistralai/mistral-small-3.2-24b` | yes | 24 s | called the tool, then did the arithmetic wrong |
| `meta-llama/llama-3.3-70b` | no | 35 s | provider returned an empty stream |
| `google/gemma-3-12b-it` | **no** | 26 s | printed `[terminal(command=...)]` as plain text |

The floor is native tool calling, not parameter count: an 8B model works, a 12B model
without tool support does not, and a 24B model can call the tool correctly and still get
the answer wrong. Pick accordingly, and prefer a model with real function calling over a
larger one without it.

One provider note: OpenRouter and any OpenAI-compatible endpoint work. Anthropic's own
API does not, because the native provider wants the `anthropic` python package, which
this wheel set does not carry, and the OpenAI-compatible endpoint answers 401.

### Small flash: put the data directory on a USB stick

The agent keeps sessions, memory and a SQLite journal under its data directory, and
Hermes downloads a further 34 MB helper binary on first run, so budget about 220 MB
rather than the 185 MB the package reports. On a router with 8 MB or 128 MB of flash
that does not fit, and even where it fits, the writes land on the same flash the
firmware lives on.

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

## The web interface

`luci-app-hermes` adds **Services -> Hermes Agent**: an overview with service state,
version, free space where the data lives, which keys are set and a live log tail, and a
settings page for the endpoint, the model, the keys, router access, Telegram and toolsets.

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

## Reaching it from a phone

![A phone talks to Telegram, the router polls Telegram outbound, and an allowlist decides who is answered](docs/telegram.svg)

```sh
apk add hermes-agent-telegram          # 25.12 and later
opkg install hermes-agent-telegram     # 24.10
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

Measured on 2026-09-08 inside `openwrt/rootfs` for aarch64, on both 25.12.4 (CPython
3.13) and 24.10.8 (CPython 3.11): adding `python-telegram-bot[webhooks]` to the router
profile adds **two** distributions and changes the version of nothing already installed.

| | |
|---|---|
| added | `python-telegram-bot` 22.6, `tornado` 6.5.8 |
| version changes to the base package's 69 | none |
| installed size | 9.3 MB, against the base package's 193 MB |

That second row is what makes an add-on possible at all. Two OpenWrt packages cannot own
one file: apk refuses such an install and opkg silently accepts it, then breaks the base
package when the add-on is later removed. So the contents are not written down anywhere.
`package/hermes-agent-telegram/files/delta.py` resolves the base profile and the base
profile plus Telegram on every build and subtracts, and it stops the build if a shared
package would have to change version. Upstream's pin is read from upstream's own
metadata, so a version bump carries the right one automatically.

Taking upstream's `messaging` extra whole would also have installed Discord with voice
support, which pulls compiled crypto, and Slack. The router was asked for Telegram.

## The signed feed

![The same feed for two release lines, with different index formats, signatures and key locations](docs/feed.svg)

|  | 25.12 | 24.10 |
|---|---|---|
| index | `packages.adb`, binary | `Packages` + `Packages.gz`, text |
| signed with | `apk adbsign`, EC prime256v1 | `usign`, Ed25519 |
| signature | inside the index | a separate `Packages.sig` |
| trusted keys | `/etc/apk/keys/<name>.pem` | `/etc/opkg/keys/<fingerprint>` |
| what is signed | every package **and** the index | the index only |

Neither key works for the other line. The last row is the one worth knowing: on 24.10 a
package is trusted because its SHA256 appears in a signed index, so an `.ipk` handed over
on its own is never verifiable and `opkg install ./file.ipk` checks nothing at all.

Both refuse an untrusted feed, and only one says so out loud. apk drops the repository in
silence, so the package merely appears not to exist and the available count is two lower.
opkg prints `Signature check failed` and stops.

**Signing happens on a workstation, not in CI.** A key held as a repository secret is
readable by anyone who can push a workflow to the default branch, and this one cannot be
revoked: a router that has trusted the public half keeps trusting anything signed with the
private half until a person logs in and deletes the file. So CI builds and gates, and
`scripts/publish-feed.sh` signs and publishes from the machine where the key lives.

## How a package is built

![Upstream, built inside the target release, one shim, packaged, signed locally](docs/build.svg)

```sh
# 25.12: apk, Python 3.13. EXTRA_ARCHES relabels the same tree for the Flint 2.
EXTRA_ARCHES=aarch64_cortex-a53 ./package/hermes-agent/build-in-container.sh aarch64_generic

# 24.10: opkg, Python 3.11
RELEASE=24.10.8 ./package/hermes-agent/build-in-container.sh x86_64
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

**It will not fit a small router.** 193 MB installed rules out anything without real
storage, and the gateway wants about 175 MB of RAM before it does any work. Below 1 GB,
run [openwrt-mcp](https://github.com/GlassOnTin/openwrt-mcp) on the router instead and
keep Hermes on a machine with room. That is the better shape anyway: the router becomes a
narrow, audited tool provider rather than the host of a Python runtime.

**Browser, vision, image generation and the wake-word stack are not packaged.** They pull
heavy dependencies for capabilities a headless router does not have. `ffmpeg` is included,
because voice messages and speech transcoding do work here and are cheap.

## Letting it touch the router

The recommended answer is not a root shell. Run
[openwrt-mcp](https://github.com/GlassOnTin/openwrt-mcp) alongside it and grant a narrow,
audited, expiring window over ubus:

```sh
openwrt-mcp pair hermes > /etc/hermes-agent/router-mcp.token
chmod 600 /etc/hermes-agent/router-mcp.token
openwrt-mcp allow hermes ubus_call,logread 'network.* iwinfo.* system.*' 30d
```

Every call is then policy-checked and written to an audit log, ungranted tools are refused
by name, and configuration changes carry a rollback timer. Read-only first is worth the
ten minutes.

## What is checked, and how

Nothing here is verified by reading the archive. Every gate installs the package into
OpenWrt's own published rootfs and then asks the running system.

| gate | what it proves |
|---|---|
| `gate-package.sh` | 11 checks: apk installs it with every dependency including `bash`, the CLI runs, it ships disabled, it refuses without a key, **the command the init hands procd actually starts and stays up**, the key reaches neither argv nor UCI nor **procd's service table**, config survives reinstall, removal is clean |
| `gate-ipk.sh` | 6 checks on 24.10: opkg installs it, it runs on Python 3.11, `/etc/config/hermes` is a registered conffile, removal leaves nothing |
| `gate-luci.sh` | 10 checks: files land where luci-base looks, both views parse, menu and ACL are valid JSON, the rpcd backend answers on ubus, a written key lands 0600, the page can tell a missing package from a missing token, and **no method returns a key** |
| `gate-feed.sh` | 3 checks: refused without the key, installs with it, no `--allow-untrusted` needed |
| `gate-feed-opkg.sh` | 3 checks: `Signature check failed` without the key, `passed` with it, and installs |
| `gate-telegram.sh` | 8 checks: the base alone cannot import telegram, the add-on installs beside it, neither package claims a file the other owns, the library imports, and the service refuses in each of the three ways a Telegram setup can be incomplete |
| `gate-telegram-opkg.sh` | 5 checks on 24.10, where opkg does not refuse a collision but overwrites: the file lists are compared directly, and removing the add-on must leave all 9037 base files |
| `gate-scenarios-bound.sh` | every scenario in `features/` names a check that runs, and every check is described by a scenario |
| `teeth.sh` | plants four faults and requires a different check to catch each one |
| `teeth-telegram.sh` | four more: a colliding file, a missing library, and two refusals cut out of the init script |

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

- [x] Native package for 25.12 (apk) and 24.10 (opkg)
- [x] `aarch64_cortex-a53` for the Flint 2, plus `x86_64` and `aarch64_generic`
- [x] LuCI interface with write-only key handling
- [x] Signed feed for both lines, signed on a workstation
- [x] Every gate runs on OpenWrt's own rootfs images in CI
- [x] **Run on real hardware.** Two GL.iNet routers on vanilla OpenWrt 25.12.5; see the figures above
- [x] **A full agent turn on a router**, model calling a tool and answering from what it read
- [x] **Measured under load**: concurrency ceiling, thermals, throughput, flash writes, leak check
- [x] **The feed installs on hardware** with its signature verified and no `--allow-untrusted`
- [x] Telegram, as a two-distribution add-on package, on both release lines
- [ ] Native Anthropic provider, which needs the `anthropic` package as a second add-on
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
