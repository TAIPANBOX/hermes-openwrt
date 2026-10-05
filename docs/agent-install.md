# Installing hermes-openwrt: a runbook for agents

This file is for an AI agent that installs or operates Hermes on an OpenWrt router over SSH.
A person wants the [README](../README.md); the commands are the same.

Rules for this file: run each step's commands, then its **check**, and go on only when the
check prints what **expect** says. On anything else, stop and report the step, the command and
its full output to the person you work for. Never improvise around a failed check.

## 0. Before anything

**Do not do these, ever:**

- Do not ask for, type, print, log or store a **PIN** or an **authenticator secret**. The owner
  sets them in step 6 themselves.
- Do not put an API key or a Telegram token on a command line other than the `printf` shown
  below (a shell builtin, so it never appears in the process list), in UCI, in a log or in your
  reply. Do not read a key file back to check it; check its mode instead.
- Do not run `apk add hermes-agent=<version>`. It pins that version in `/etc/apk/world`, and
  every later upgrade silently keeps it. Undo with `apk add hermes-agent` (no version), then
  `apk upgrade`.
- Do not use `--allow-untrusted` or `--force`. The feed is signed; if apk refuses it, something
  is wrong.
- Do not reboot, restart the network or power-cycle a router unless the person said you may,
  for that action.
- Do not set `hermes.main.profile=root` or `hermes.telegram.allow_all=1` unless the person asked
  for exactly that. Both widen what the agent on the router can do.

## 1. Preconditions

Run on the router. Each line must print what is shown after `# expect`.

```sh
cat /etc/apk/arch                                  # expect: aarch64_cortex-a53 or aarch64_generic
. /etc/openwrt_release; echo "$DISTRIB_ID $DISTRIB_RELEASE"   # expect: OpenWrt 25.12.<n>
command -v apk                                     # expect: /usr/bin/apk (vendor firmwares use opkg)
awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo   # expect: 900 or more (1 GB); 450 to 900 is 512 MB, see below
df -m /overlay | awk 'NR==2 {print $4}'            # expect: 450 or more (MB free)
grep -ow memory /sys/fs/cgroup/cgroup.controllers  # expect: memory
wget -q --spider https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.pem && echo reachable   # expect: reachable
```

- A different architecture: stop. Nothing else is built.
- Not 25.12, or no `apk`: stop. The package is for vanilla OpenWrt 25.12 only.
- 512 MB of memory, or under 450 MB free flash: Hermes fits only with the packages on a USB
  stick (extroot, [usb.md](usb.md)), one conversation at a time. Ask the person before going on.
- No `memory` controller: the service would refuse to start. Stop.

Ask the person for a backup first if they have none: `sysupgrade -b /tmp/backup.tar.gz`, then
copy it off the router.

## 2. Trust the feed and install

```sh
wget -O /etc/apk/keys/hermes-openwrt.pem https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.pem
grep -q taipanbox.github.io/hermes-openwrt /etc/apk/repositories.d/customfeeds.list 2>/dev/null || \
  echo "https://taipanbox.github.io/hermes-openwrt/25.12/$(cat /etc/apk/arch)/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list
apk update
apk add hermes-agent luci-app-hermes
```

**Check:**

```sh
apk update 2>&1 | grep -ci untrusted               # expect: 0
apk list --installed | grep -E '^(hermes-agent|luci-app-hermes|openwrt-mcp)-'   # expect: three lines, hermes-agent-0.21.5-r<n>
id hermes                                           # expect: uid=... (hermes)
uci get hermes.main.enabled                         # expect: 0 (it ships off)
```

An apk error about the repository or a signature: stop, do not retry with flags.

## 3. Give it a model

Ask the person which provider and model to use, and for the key. Any OpenAI-compatible
endpoint works; the model must support native tool calling (measured: `openai/gpt-4o-mini`,
`anthropic/claude-haiku-4.5`, `google/gemini-2.5-flash`, `qwen/qwen3-8b` work;
`google/gemma-3-12b-it` does not, see [measured.md](measured.md)).

```sh
printf '%s' '<the key>' > /etc/hermes-agent/provider.key && chmod 600 /etc/hermes-agent/provider.key
uci set hermes.main.base_url='<endpoint, e.g. https://openrouter.ai/api/v1>'
uci set hermes.main.model='<model id>'
uci commit hermes
```

**Check:**

```sh
ls -l /etc/hermes-agent/provider.key | awk '{print $1, $3}'   # expect: -rw------- root
uci get hermes.main.base_url; uci get hermes.main.model   # expect: what the person gave
```

## 4. Start it

```sh
uci set hermes.main.enabled=1 && uci commit hermes
/etc/init.d/hermes-agent restart
sleep 30
```

**Check:**

```sh
pgrep -f 'main.py gateway' >/dev/null && echo running          # expect: running
logread -e hermes | grep -cE 'refus|Not starting|not starting'  # expect: 0
ps w | grep -m1 '[m]ain.py gateway' | awk '{print $2}'          # expect: hermes
uci get hermes.main.profile                                     # expect: owner
```

Not running: read `logread -e hermes | tail -n 40` and match the line in
[Failures](#failures). The gateway takes 4 to 5 s to exec and about 200 MB of memory.

## 5. Telegram (only if the person wants it)

Ask the person for the bot token (from @BotFather) and their numeric Telegram id (from
@userinfobot). Only that id will be answered.

```sh
apk add hermes-agent-telegram
printf '%s' '<bot token>' > /etc/hermes-agent/telegram.token && chmod 600 /etc/hermes-agent/telegram.token
uci set hermes.telegram.enabled=1
uci add_list hermes.telegram.allow_user_id='<numeric id>'
uci commit hermes && /etc/init.d/hermes-agent restart
```

**Check:** `logread -e hermes | grep -c 'telegram is enabled but'` prints `0`, and the gateway is
running as in step 4. Then ask the person to send the bot a message; the first reply in a new
conversation may be Hermes's own onboarding question, which is expected.

## 6. Letting it change the router (the owner does this, not you)

In the default `owner` profile the agent can read the router and cannot change it until the
owner sets a second factor and unlocks. **You do not set the factor.** Tell the person:

- in the browser: **Services -> Hermes Agent -> Security** (set a PIN, add a phone by QR code,
  choose the factor); or
- over SSH, typing the PIN themselves where it is not echoed: the block under step 4 of the
  [README's install](../README.md#install).

Then `/unlock` in the private Telegram chat opens a 15-minute window, and `/lock` closes it.
Explain to the person that an open window is root for its length
([security.md](security.md)). You may check the state, which holds no secret:

```sh
uci get hermes.security.factor     # none until the owner sets one
```

## 7. USB stick (only if asked)

Moves the data directory (what is written repeatedly) to a stick; the programs stay inside.

```sh
apk add kmod-usb-storage block-mount kmod-fs-ext4 e2fsprogs
block info                          # find the stick's partition, e.g. /dev/sda1; confirm with the person
hermes-usb move /dev/sda1 --format  # ERASES that partition: only with the person's yes for this device
hermes-usb status                   # expect: the data is on the stick
```

Never point it at the router's own storage or a whole disk; it refuses both. To bring the data
back: `hermes-usb back`. Details: [usb.md](usb.md).

## Upgrading

```sh
apk update && apk upgrade
/etc/init.d/hermes-agent restart
apk list --installed | grep '^hermes-agent-'   # expect: the newest r<n> in the feed
grep hermes-agent /etc/apk/world               # expect: hermes-agent, with no "=" in it
```

An upgrade leaves the start at boot as the owner set it and does not restart a running gateway.

## Removing

```sh
hermes-usb status 2>/dev/null       # if the data is on a stick: hermes-usb back first
/etc/init.d/hermes-agent stop
apk del luci-app-hermes hermes-agent-telegram hermes-agent openwrt-mcp
```

This keeps the data directory, the keys, the configuration and the `hermes` account on
purpose. Remove those only if the person asks for everything gone:
[install-notes.md](install-notes.md#removing-it) has the commands and what to keep when
openwrt-mcp served other clients.

## Failures

Lines the service writes to `logread`, what they mean, and what to do.

| The log says | Cause | Do |
|---|---|---|
| `disabled in /etc/config/hermes; not starting` | `hermes.main.enabled` is 0 | step 4 |
| `no API key in /etc/hermes-agent/provider.key` | the key file is missing or empty | step 3 |
| `base_url is empty` / `model is empty` | UCI not set | step 3 |
| `hermes.main.profile ... must be 'owner', 'assistant' or 'root'` | a typo in the profile | `uci set hermes.main.profile=owner` |
| `hermes-memory: refusing unbounded start` | no cgroup v2 memory control | stop; the firmware lacks it (precondition) |
| `hermes-runtime: startup refused (...); operator configuration preserved` | a `.env`, provider or header setting in the data directory contradicts UCI | report the text in brackets; do not delete the person's files |
| `telegram is enabled but its client library is not installed` | the add-on is missing | `apk add hermes-agent-telegram` |
| `telegram is enabled but there is no token in ...` / `not shaped like a Telegram token` | the token file | step 5 |
| `telegram is enabled but no user is allowed to talk to it` | no allowlist | step 5, `allow_user_id` |
| `'hermes' cannot write in ...` / `cannot enter ...` | the data directory is on FAT, read-only, or a parent is closed | point `hermes.main.data_dir` at ext4, f2fs or the overlay |
| `there is no user 'hermes'` | the account is missing | report it; reinstalling hermes-agent recreates it (its install and upgrade scripts both make the account), with the person's yes |
| `could not start openwrt-mcp` / `could not pair hermes-main` | openwrt-mcp failed | `logread -e openwrt-mcp`; report it |
| the gateway starts, then stops five times within minutes | procd's bounded respawn gave up after repeated failures | read the first refusal above it |

A model that answers but will not act is usually the model: try one from the working list in
step 3 before anything else.

## Reporting

Open an issue with the [test report template](https://github.com/TAIPANBOX/hermes-openwrt/issues/new/choose):
the router, `cat /etc/apk/arch`, `cat /etc/openwrt_release`, the package versions and the log,
with keys and tokens removed. A security problem goes to [SECURITY.md](../SECURITY.md), never
an issue.
