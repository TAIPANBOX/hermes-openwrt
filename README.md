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
![tested on three routers](https://img.shields.io/badge/hardware-three%20routers%2C%20measured-3fb950)

</div>

![The agent runs on the router, the model runs elsewhere, and the router itself is reached through a narrow audited window](docs/hero.svg)

## What it is

Hermes living on your router, inside your home network: an assistant for the network it sits
in, on all the time. The router runs the agent; a provider you choose runs the model, a free
one included. It has no browser, so it does not book, buy or sign in to sites; it does search
and read ordinary web pages.

| Use | Status |
|---|---|
| Ask the router from Telegram ("why is the internet slow?"); it runs commands and answers from their output | measured on both routers, 18 to 25 s |
| An hourly check that speaks only when something is wrong | ran 19 hours on a Brume 2, one model call per check; [one way it stays silent](docs/use.md#scheduled-jobs-in-practice) |
| A morning message (weather, rate, one news item) | delivered on time; a small free model skipped the search |
| Reminders set in plain words in a chat | not measured yet |

More, with the limits named: [docs/use.md](docs/use.md).

## Install

| You need | |
|---|---|
| **Router** | vanilla OpenWrt 25.12 (not a vendor firmware) on aarch64: `cat /etc/apk/arch` prints `aarch64_cortex-a53` or `aarch64_generic`. Tested on a Flint 2, a Brume 2 and a Beryl AX |
| **Memory** | 1 GB. On 512 MB one conversation at a time fits, with little to spare |
| **Flash** | about 350 MB for the packages, then the data directory (37 MB at the first start, growing). Short of flash: [a USB stick](docs/usb.md) |
| **A model** | a key for any OpenAI-compatible provider, free ones included; the service does not start without one |
| **A way back** | a backup kept off the router (`sysupgrade -b /tmp/backup.tar.gz`), and your router's vendor firmware at hand |

![Install: trust the feed, add the packages, give it a model, start it](docs/install-flow.svg)

**1. Trust the feed and install.**

```sh
wget -O /etc/apk/keys/hermes-openwrt.pem \
  https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.pem

echo "https://taipanbox.github.io/hermes-openwrt/25.12/$(cat /etc/apk/arch)/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list

apk update && apk add hermes-agent luci-app-hermes
```

No `--allow-untrusted` and no `--force`: that is the point of signing the feed. `hermes-agent`
pulls in `openwrt-mcp` from the same feed and creates the `hermes` account the agent runs as.

**2. Give it a model and start it.** The service ships switched off.

Typed in an SSH session on the router, `printf` is a shell builtin and the key never reaches a
command line another process can read; sending the same line as `ssh router "..."` would put
it in one.

```sh
printf '%s' 'sk-...' > /etc/hermes-agent/provider.key && chmod 600 /etc/hermes-agent/provider.key
uci set hermes.main.base_url='https://openrouter.ai/api/v1'   # any OpenAI-compatible endpoint
uci set hermes.main.model='openai/gpt-4o-mini'               # pick one that calls tools
uci set hermes.main.enabled=1
uci commit hermes && /etc/init.d/hermes-agent restart
logread -e hermes | tail -n 20
```

Or in the browser: **Services -> Hermes Agent -> Settings**. The key is a root-only file and the
page can write it but never read it back. Which models can drive it is measured
[below](#measured-on-hardware).

**3. Reach it from a phone** (optional). The router opens no port: it polls Telegram outbound.

```sh
apk add hermes-agent-telegram
printf '%s' '<token from @BotFather>' > /etc/hermes-agent/telegram.token
chmod 600 /etc/hermes-agent/telegram.token
uci set hermes.telegram.enabled=1
uci add_list hermes.telegram.allow_user_id=<your numeric id, from @userinfobot>
uci commit hermes && /etc/init.d/hermes-agent restart
```

It refuses to start with nobody allowed rather than answer nobody in silence:
[docs/telegram.md](docs/telegram.md).

**4. Let it change the router** (optional). In the default `owner` profile the agent reads the
router freely and changes it only after you unlock it with a second factor. With none set,
nothing can change the router through it. Set one in **Services -> Hermes Agent -> Security**,
or over SSH, where the QR code is printed in the terminal:

```sh
stty -echo; read -r PIN; stty echo; printf '%s\n' "$PIN" | openwrt-mcp pin set hermes-main; unset PIN
openwrt-mcp mfa enrol hermes-main --pending --qr
openwrt-mcp mfa activate hermes-main <code from the app>
uci set hermes.security.factor=pin+totp    # none, pin, totp or pin+totp
uci commit hermes && /etc/init.d/hermes-agent restart
```

Then `/unlock` in the private chat opens a 15-minute window. That window is root for its
length: [how it works and what it does not protect](docs/security.md).

**Upgrading.** `apk update && apk upgrade hermes-agent luci-app-hermes openwrt-mcp` (and
`hermes-agent-telegram` if you added it), then `/etc/init.d/hermes-agent restart`: an upgrade
does not restart a running gateway, and it leaves the start at boot as you set it. Do not
install a fixed version with `apk add hermes-agent=<version>`: that pins it in
`/etc/apk/world`, and later upgrades silently keep the old one.

**Removing it.** If `hermes-usb status` says the data is on a stick, run `hermes-usb back` first.

```sh
/etc/init.d/hermes-agent stop
apk del luci-app-hermes hermes-agent-telegram hermes-agent openwrt-mcp
```

That leaves the data, the keys, the configuration and the `hermes` account, on purpose; how to
take all of it away is in [docs/install-notes.md](docs/install-notes.md#removing-it).

An agent doing this for you: [docs/agent-install.md](docs/agent-install.md) is the same install
written as checks an agent runs and the output it must see.

## Measured on hardware

![The 2026-10-04 re-run on the published release, Flint 2 against Brume 2](docs/rerun.svg)

Step 1 above and the Telegram add-on, run as written against the published feed on two
routers on vanilla OpenWrt 25.12.5 (the model added by hand, through a ChatGPT subscription), each cleaned first and put back as found afterwards. Every figure, its date,
its model and its method, with the earlier runs, load tests and how many agents fit:
[docs/measured.md](docs/measured.md).

![Which models can call a tool on the router](docs/models.svg)

The floor is native tool calling, not size: an 8B model works, a 12B one without tool support
does not.

## How it keeps the router yours

![The settings page can write a key and can ask whether one is present; nothing returns one](docs/security.svg)

| profile | runs as | the router |
|---|---|---|
| `owner` (default) | `hermes`, unprivileged | read through openwrt-mcp; changed only through it, after an unlock |
| `assistant` | `hermes`, no terminal, code or file tools | only through an MCP server you set up |
| `root` | root, warned at every start | directly, no unlock |

![An unlock: the message is deleted before anything else, openwrt-mcp checks the factor, a window opens, an unconfirmed change rolls back by itself](docs/unlock.svg)

- Keys live in root-only files; no page and no call returns one, and they stay out of
  command lines, UCI and procd's service table.
- The unlock message is deleted from the chat and never reaches the model or a log.
- A change that is not confirmed is undone by itself, after a reboot too.

Everything about keys, profiles, the unlock and the memory ceiling, with the limits named:
[docs/security.md](docs/security.md). Several providers on one router: [docs/providers.md](docs/providers.md).

## On a USB stick

![Hermes on a USB stick: a GL-MT3000 Beryl AX running Hermes from a stick, and the two ways to put Hermes on USB](docs/usb-stick.svg)

```sh
apk update && apk add kmod-usb-storage block-mount kmod-fs-ext4 e2fsprogs
block info                            # the stick's partition: /dev/sda1 here
hermes-usb move /dev/sda1 --format    # erases that partition, makes ext4, moves the data
hermes-usb status
```

Without its stick Hermes does not start, and says why. For a router with too little flash,
extroot puts every package on the stick: [docs/usb.md](docs/usb.md).

## Testing it for us

What helps most is what has not been measured yet:

1. **A reminder set in plain words in a chat**, and whether it arrives on time.
2. **The gateway's memory over days.** The longest run so far was 19 hours, and in its
   last 14.5 the gateway grew from 204 to 215 MB, too short to tell a leak from warming
   up. That figure is the gateway's own resident memory; every hour or so:
   `grep VmRSS /proc/$(pgrep -o -f 'main.py gateway')/status`.
3. **Web search with the model you use.** It works on a router (see
   [the re-run](docs/measured.md#re-run-on-the-published-release-2026-10-04)), but
   whether a model reaches for it unasked depends on the model.
4. **Any aarch64 router other than the Flint 2, Brume 2 and Beryl AX**, with its numbers.

Report what happened in an [issue](https://github.com/TAIPANBOX/hermes-openwrt/issues/new/choose):
the template asks for the router, the versions and the log. Before you paste a log, look
for keys and tokens in it; the package keeps them out of its own lines, but a model's
reply or a command's output can carry anything. A security problem goes through
[SECURITY.md](SECURITY.md) instead, not an issue.

To change the code yourself, [CONTRIBUTING.md](CONTRIBUTING.md) says how to build what CI
builds, which checks cover which part, and what a pull request is held to.

## What is checked, and how

Nothing here is verified by reading the archive. Every gate installs the packages into
OpenWrt's own published rootfs and asks the running system. CI runs them on an arm64 runner
(the feed's gate runs when the feed is published), and teeth scripts plant faults in the
product and require a check to catch each one.

| gate | covers |
|---|---|
| `gate-package.sh` | install, start, the key out of sight, upgrade, clean removal |
| `gate-runtime.sh` | the gateway against the installed upstream: models, providers, profiles, limits |
| `gate-luci.sh` | the web page: write-only keys, the narrow read permission, the Security page |
| `gate-unlock.sh` | the owner unlock end to end, from Telegram and from LuCI |
| `gate-usb.sh` | `hermes-usb` with real sticks made of loop devices |
| `gate-telegram.sh`, `gate-upstream.sh`, `gate-feed.sh` | the add-on, the pinned upstream, the signed feed |
| `gate-upstream-watch.sh` | the daily check that opens one issue when upstream tags a newer release |
| `gate-apk-owner.sh`, `gate-relabel.sh` | every file in every package is root's; the `aarch64_cortex-a53` package differs from the generic one only in its label |
| `gate-figures.sh` | these figures drawn from their data; every picture, link and anchor resolves |

What each check proves, one by one: [docs/checks.md](docs/checks.md).

## The signed feed

The index and every package are signed with an EC key through `apk adbsign`, and signing
happens on a workstation, never in CI: a router that trusts the key keeps trusting anything
it signs. How the package is assembled from a pinned upstream inside the target release:
[docs/build.md](docs/build.md).

## More

| | |
|---|---|
| [docs/use.md](docs/use.md) | what it is for, scheduled jobs, what it will not do |
| [docs/install-notes.md](docs/install-notes.md) | requirements in detail, a way back, removing everything |
| [docs/agent-install.md](docs/agent-install.md) | the install as an agent runs it |
| [docs/measured.md](docs/measured.md) | every hardware figure |
| [docs/usb.md](docs/usb.md) | `hermes-usb` and extroot |
| [docs/security.md](docs/security.md) | keys, profiles, the unlock, the controls |
| [docs/providers.md](docs/providers.md) | several providers and a ChatGPT subscription |
| [docs/telegram.md](docs/telegram.md) | the phone, the allowlist, a test chat |
| [docs/build.md](docs/build.md) | how it is built, the feed, status |
| [docs/checks.md](docs/checks.md) | every gate and its teeth |
| [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) | changing it, reporting a vulnerability |
