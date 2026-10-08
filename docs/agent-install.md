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
- Do not put an API key or a Telegram token on any command line, yours or the router's. A
  command you send as `ssh router "..."` becomes the argv of the router's `sh -c`, which any
  account on the router can read in `/proc`, the agent's own `hermes` user included, and it
  stays in your tool log. Secrets go in on standard input only (step 3), or the person pastes
  them into LuCI. Never in UCI, a log or your reply, and never read a key file back: check its
  mode instead.
- Do not run `apk add hermes-agent=<version>`. It pins that version in `/etc/apk/world`, and
  every later upgrade silently keeps it. Undo with `apk add hermes-agent` (no version), then
  `apk upgrade`.
- Do not use `--allow-untrusted` or `--force`. The feed is signed; if apk refuses it, something
  is wrong.
- Do not reboot, restart the network or power-cycle a router unless the person said you may,
  for that action. Do not upgrade packages other than Hermes's own without asking.
- Do not set `hermes.main.profile=root` or `hermes.telegram.allow_all=1` unless the person asked
  for exactly that. Both widen what the agent on the router can do.

## 1. Preconditions

Run on the router. Each line must print what is shown after `# expect`.

```sh
cat /etc/apk/arch                                  # expect: aarch64_cortex-a53 or aarch64_generic
. /etc/openwrt_release; echo "$DISTRIB_ID $DISTRIB_RELEASE"   # expect: OpenWrt 25.12.<n>
command -v apk                                     # expect: /usr/bin/apk (vendor firmwares use opkg)
awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo   # expect: 900 or more (1 GB); 450 to 900 is 512 MB, see below
df -m / | awk 'NR==2 {print $4}'                   # expect: 450 or more (MB free)
grep -ow memory /sys/fs/cgroup/cgroup.controllers  # expect: memory
wget -q --spider https://taipanbox.github.io/hermes-openwrt/hermes-openwrt.pem && echo reachable   # expect: reachable
```

- `df -m /`, not `df -m /overlay`: on a Flint 2 `/overlay` is not a mount point of its own and
  `df` answers "can't find mount point" (measured 2026-10-08); `/` shows the same free space
  wherever the overlay is.
- A different architecture: stop. Nothing else is built.
- Not 25.12, or no `apk`: stop. The package is for vanilla OpenWrt 25.12 only.
- 512 MB of memory: one conversation at a time fits, with little to spare. Tell the person.
- Under 450 MB free flash: the packages go on a USB stick first (extroot, [usb.md](usb.md)).
  Ask the person before going on.
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

Put the key in without it touching a command line. Either the person pastes it into
**Services -> Hermes Agent -> Settings** (write-only), or, where the key is in a file on your
machine (`key.txt`, one line), send it on standard input:

```sh
ssh root@<router> 'umask 077; cat > /etc/hermes-agent/provider.key' < key.txt
```

Then the model, on the router:

```sh
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
logger -t hermes-runbook start      # a marker, so the checks below read only this start
/etc/init.d/hermes-agent restart
sleep 30
```

**Check:**

```sh
pgrep -f '[m]ain.py gateway' >/dev/null && echo running        # expect: running
logread | awk '/hermes-runbook: start/{n=0;f=1} f&&/hermes/&&/refus|ot starting/{n++} END{print n+0}'   # expect: 0
[ "$(awk '/^Uid/{print $2}' /proc/$(pgrep -o -f '[m]ain.py gateway')/status)" = "$(id -u hermes)" ] && echo as-hermes   # expect: as-hermes
uci get hermes.main.profile                                     # expect: owner
```

The `[m]` in the pattern is load-bearing when you send these lines as `ssh router '...'`: the
router's `sh -c` then carries the text `main.py gateway` in its own command line, `pgrep -o -f`
picks that shell, and the checks read the wrong process (measured 2026-10-08).

Not running: read `logread | sed -n '/hermes-runbook: start/,$p' | tail -n 40` and match the line in
[Failures](#failures). The gateway takes 4 to 5 s to exec and about 200 MB of memory.

## 5. Telegram (only if the person wants it)

Ask the person for the bot token (from @BotFather) and their numeric Telegram id (from
@userinfobot). Only that id will be answered.

The token goes in the same way as the key: pasted into LuCI by the person, or on standard
input from a file (`ssh root@<router> 'umask 077; cat > /etc/hermes-agent/telegram.token' < token.txt`).

```sh
apk add hermes-agent-telegram
uci set hermes.telegram.enabled=1
uci add_list hermes.telegram.allow_user_id='<numeric id>'
logger -t hermes-runbook start
uci commit hermes && /etc/init.d/hermes-agent restart
```

**Check:** after 30 s, `logread | awk '/hermes-runbook: start/{n=0;f=1} f&&/telegram is enabled but/{n++} END{print n+0}'`
prints `0`, and the gateway is running as in step 4. Then ask the person to send the bot a message; the first reply in a new
conversation may be Hermes's own onboarding question, which is expected.

## 6. Letting it change the router (the owner does this, not you)

In the default `owner` profile the agent can read the router and cannot change it until the
owner sets a second factor and unlocks. **You do not set the factor.** Tell the person:

- in the browser: **Services -> Hermes Agent -> Security** (set a PIN, add a phone by QR code,
  choose the factor); or
- over SSH, typing the PIN themselves where it is not echoed: the block under step 4 of the
  [README's install](../README.md#install).

Then `/unlock` in the private Telegram chat opens a 15-minute window, and `/lock` closes it.
Tell the person to put the PIN in the same message: `/unlock 4821` with the factor `pin`,
`/unlock 503917` with `totp`, `/unlock 4821 503917` with `pin+totp` (or the same digits alone,
without `/unlock`). `/unlock` on its own is answered "That does not look like what this router
asks for. Send /unlock followed by your PIN (4 to 8 digits)." and opens nothing. On the
Security page the PIN and the factor have a Save each: a PIN saved while the factor is `none`
unlocks nothing until PIN is chosen under "What unlocking asks for" and saved there.
Explain to the person what an open window allows: settings, the VPN and services, never a
command, a firmware or a reboot, with the one gap security.md names
([security.md](security.md)). You may check the state, which holds no secret:

```sh
uci get hermes.security.factor     # none until the owner sets one
```

## 7. USB stick (only if asked)

Moves the data directory (what is written repeatedly) to a stick; the programs stay inside.

```sh
apk add kmod-usb-storage block-mount kmod-fs-ext4 e2fsprogs
block info                          # find the stick's partition, e.g. /dev/sda1; confirm with the person
grep '^/dev/sda' /proc/mounts       # mounted already (block-mount does that)? umount it first
hermes-usb move /dev/sda1 --format  # ERASES that partition: only with the person's yes for this device
hermes-usb status                   # expect: /srv/hermes is on /dev/sda1 (UUID ...), ... KiB free
```

Never point it at the router's own storage or a whole disk; it refuses both. To bring the data
back: `hermes-usb back`. Details: [usb.md](usb.md).

## Upgrading

Only Hermes's own packages; the rest of the router is the person's to upgrade.

```sh
apk update
apk upgrade hermes-agent luci-app-hermes openwrt-mcp    # add hermes-agent-telegram if it is installed
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

Ask first whether openwrt-mcp served other clients before Hermes; if it did, leave it out of
`apk del`. This keeps the data directory, the keys, the configuration and the `hermes` account on
purpose. Remove those only if the person asks for everything gone:
[install-notes.md](install-notes.md#removing-it) has the commands and what to keep when
openwrt-mcp served other clients.

## Failures

Lines the service writes to `logread`, what they mean, and what to do.

| The log says | Cause | Do |
|---|---|---|
| apk: `Connection aborted`, `wget: exited with error 4`, then `N errors;` | a download from downloads.openwrt.org was cut off; the packages it names are not installed | run the same `apk add` again until it ends with `OK:`; never `--force` |
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
| `... Not starting.` naming a stick, a lock or a copy left by hermes-usb | the data is on a USB stick that is not there, or a move was interrupted | `hermes-usb status`; plug the stick in, or report what it names |
| `hermes.security.factor must be ...`, `... window and lockout are durations ...`, `... max_failures must be ...` | a bad value in `hermes.security` | report it to the owner; the factor is theirs |
| `there is no user 'hermes'` | the account is missing | report it; reinstalling hermes-agent recreates it (its install and upgrade scripts both make the account), with the person's yes |
| `could not start openwrt-mcp` / `could not pair hermes-main` | openwrt-mcp failed | `logread -e openwrt-mcp`; report it |
| `openwrt-mcp ... does not report that uci_get redacts credentials` | an openwrt-mcp older than 0.5.0.2; the agent runs, but cannot read wireless or the whole of network | `apk update && apk upgrade openwrt-mcp`, then restart hermes-agent |
| `the openwrt-mcp running is ..., not the installed ...` | the daemon from before an upgrade is still serving and a restart did not replace it | `service openwrt-mcp restart`, then restart hermes-agent; report it if the line comes back |
| the gateway starts, then stops five times within minutes | procd's bounded respawn gave up after repeated failures | read the first refusal above it |

A diagnosis whose every ping says `permission denied (are you root?)` is a package before 0.21.5-r9:
`apk upgrade hermes-agent`, which brings iputils-ping.

A model that answers but will not act is usually the model: try one from the working list in
step 3 before anything else.

## Reporting

Open an issue with the [test report template](https://github.com/TAIPANBOX/hermes-openwrt/issues/new/choose):
the router, `cat /etc/apk/arch`, `cat /etc/openwrt_release`, the package versions and the log,
with keys and tokens removed. A security problem goes to [SECURITY.md](../SECURITY.md), never
an issue.
