# Keys, profiles and the owner unlock

## The web interface

`luci-app-hermes` adds **Services -> Hermes Agent**: an overview with service state,
version, free space where the data lives, which keys are set and a live log tail, and a
settings page for the endpoint, the model, the keys, router access, Telegram and toolsets, a
Providers page for the further providers and a ChatGPT subscription, and a Security page that
sets the PIN, adds a phone and chooses what unlocking the agent asks for (under "Setting up what
unlocking asks for", below).

It looks like every other LuCI page, and two things about it are not cosmetic.

**The key fields are write-only.** They read `stored`, never a key: the page can store one
and can ask whether one exists, and no method returns one, which is the next section.

**The log tail is the only way to see the service without SSH**, and it is not decoration.
The worst defect this package ever shipped, a flag the CLI rejects that killed the service
at argument parsing on every start, was found by opening that box in a browser after weeks
of green gates. There is a check for it now.

## Keys go in and do not come out

![The settings page can write a key and can ask whether one is present; nothing returns one](security.svg)

A key put in UCI is world-readable, printed in full by `uci show`, and present in every
support bundle. So keys live in root-only files under `/etc/hermes-agent`, and the fields
are write-only: the page can store one and can ask whether one exists, and no method
returns one.

`scripts/gate-luci.sh` asserts that rather than trusting it. It writes a canary through
the RPC and then requires that no readable method mentions it.

The page manages the three key files in `/etc/hermes-agent`. If UCI points the service
at a different file, the page says so and does not write its own slot, and a write that
fails is reported as not saved. Read-only access to the page covers its status and log
calls, the Security page's status call (facts only: is a PIN set, is a phone enrolled) and its
own UCI configuration, and nothing else: not procd's service list, where a service's
environment can be read, and no file on the router. Everything that writes a key or a PIN, or
returns a phone's QR code, is in the write permission alone.

A key is also kept out of the programs the backend runs. jshn's `json_load`, which every LuCI
rpcd backend reaches for, puts the whole message on a `jshn` command line, which any account on
the router can read from `/proc` while it runs, and `json_get_var` exports what it reads to every
program started afterwards. The backend here reads the message from a pipe with `jsonfilter` and
exports nothing, and `gate-luci.sh` and `gate-unlock.sh` record every start of the programs that
could be handed one and require that the key, the PIN and a phone's secret are in none of their
arguments or environments. Until LuCI r13 `set_secret` did use `json_load`, so a key was on a
command line for the moment it took to parse it.

## Letting it touch the router

### Who the agent runs as

From 0.21.5-r3 the gateway, and every command, file and code tool it starts, run as
`hermes`, an account the package creates with no password and no login shell. They run as
root only if the profile says `root`, which has to be chosen and prints a warning at every
start. Before that the whole agent was root, and a model that was talked into a bad
command, or simply wrong, had the router.

The exec wrapper is still root until its last line, because it applies the memory ceiling
and reads the root-only key files. It then hands over to `/usr/libexec/hermes-drop`, which
gives up root for good: supplementary groups, then the group, then the real, effective and
saved user ids together, and it checks afterwards that all of it took and that
`setuid(0)` is refused, or the agent does not start. The wrapper's two helpers and the init's
own check of the configuration run as `hermes` as well, so root never runs upstream's code
over files the agent can write. `nice 10` and the memory cgroup are inherited across the
drop; the agent cannot lift its own ceiling.

The data directory belongs to `hermes`. The first start after an upgrade from a release
that ran as root hands the existing directory over, sessions, memory and jobs kept, and
says so; later starts do not walk it again. A data directory that does not exist yet is
made 0700, and any parent that is missing is made readable and enterable by everyone (0755),
whatever umask the service was started with: a boot's umask would otherwise close a new `/srv`
to everyone but root, and `hermes` could not reach its own directory (seen in a QEMU OpenWrt
25.12.5 with no `/srv`, where the start was refused as "cannot write"). A parent that already
exists is left as it is, and if `hermes` cannot enter one the start stops and names it and its
mode. A directory the agent cannot write in, a FAT
stick or a read-only mount, stops the start with the reason. The `hermes` account stays
when the package is removed, with the data directory, so that files it owns never fall to
a user later given the same id, and a reinstall finds it. `apk` runs a package's
`post-upgrade` script, not its `post-install` one, when it replaces a version, so the
package has both; the upgrade does not restart a running gateway, it says to, and until
that restart the old gateway keeps running as root. Only an install switches the service's
start at boot on; an upgrade leaves it as it was, so a router whose owner switched it off
(`service hermes-agent disable`) keeps it off, as OpenWrt's own packages do; `service
hermes-agent enable` switches it back on, an upgrade no longer does it for you.

`hermes` and `hermes-login` run from a root shell act as `hermes` when the data directory
they work on belongs to `hermes`, so `HERMES_HOME=/srv/hermes hermes cron create ...` over
SSH leaves nothing the gateway cannot update. `HERMES_OPENWRT_AS_ROOT=1` turns that off.

The gateway's environment holds the keys. Until 0.21.5-r9 a process running as `hermes`, the
agent's own terminal included, could read them in `/proc/<gateway>/environ`. From r9 the gateway
makes itself non-dumpable before any of upstream's code runs, so those entries are root's: as
`hermes` the read is refused, which `check_gateway_keys_hidden_from_its_user` proves against the
real wrapper. Upstream keeps the model key out of the terminal's own environment, and its file
tool refuses `/proc/self/environ`. The agent can still use its key, which is what it is for:
give it one with a spending limit. Tool defaults, MCP policy and the memory ceiling are not an
operating system sandbox.

### Profiles

`hermes.main.profile` chooses what the agent may use, and an unset one means `owner`:

| profile | runs as | tools | the router |
|---|---|---|---|
| `owner` (default) | `hermes` | every tool the toolsets list selects | read through openwrt-mcp; changed only through it, after an unlock |
| `assistant` | `hermes` | no terminal, code execution or file tools | only through an MCP server you set up yourself |
| `root` (`admin` is its old name) | root | every tool the toolsets list selects | directly, and through openwrt-mcp, with no unlock |

```sh
uci set hermes.main.profile=root && uci commit hermes && /etc/init.d/hermes-agent restart
```

The LuCI settings page offers all three, owner first, and shows `admin` as root. Saving it with
no profile set writes `owner`, the default, so saving never puts the agent back to root.

Any other value refuses to start rather than guess which was meant. A router whose
`/etc/config/hermes` already names `admin` keeps running as root, and every start says so
in the log; a router whose file names no profile at all is the one that stops running as
root. Starting the service prints which profile applies and how to change it.

One turn makes at most 20 model calls with tools (`hermes.main.max_turns`, 1 to 500),
and a turn that reaches the limit gets one more, without tools, to sum up what it found.
Upstream allows 90, and on 2026-09-24 a bot in the assistant profile, asked for something
it had no tool for, spent all 90 before it answered. The same day, with this revision on
both routers and each asked for its own uptime: in the profile now called root it ran
`uptime` and answered in two model calls; with the limit set to 1 it stopped after the
first call, which had already run `uptime`, and the summary answered from that; in
assistant, told what it cannot do, it said so at once, in one call.

### The owner profile: reading is free, changing needs you

The package depends on openwrt-mcp, which is not in OpenWrt's feed, so this repository's
feed carries a build of it from [TAIPANBOX/openwrt-mcp](https://github.com/TAIPANBOX/openwrt-mcp),
a fork of [GlassOnTin/openwrt-mcp](https://github.com/GlassOnTin/openwrt-mcp) that adds the
owner's second factor, built from a pinned commit of the fork's `main`, version 0.5.0.2 since
0.21.5-r11 (`scripts/build-openwrt-mcp.sh`, which uses that repository's own `mkapk.sh`; the
commit is the one in `.github/workflows/ci.yml`). Upstream has the code factor and its
enrolment; the PIN, a factor per policy (`pin`, `pin+totp`), the lockout, `mfa_lock`, the
two-step enrolment and the redaction of every `uci_get` answer are the fork's, and its README
documents them. `hermes-agent` depends on `openwrt-mcp>=0.5.0.2`, the first version that
redacts, so an upgrade of the agent cannot leave an older one beside it.

At every start in the owner profile, as root, the package makes sure openwrt-mcp is
enabled and running; pairs one client for the agent, `hermes-main`, if
`/etc/hermes-agent/router-mcp.token` is missing, into a root-only file; and writes that
client's policies into `/etc/config/openwrt-mcp`, in sections named `hermes_main_*` and in
no others. The connection's URL defaults to openwrt-mcp's own loopback address. The
policies are written in the order openwrt-mcp has to see them, because it takes the first
one of a client that covers a call:

| policy | grants | unlock |
|---|---|---|
| `hermes_main_read_ubus` | `ubus_call`, by method: `system.board`, `system.info`, `network.interface.dump`, `network.interface.*.status`, `network.device.status`, `iwinfo.devices`, `iwinfo.info`, `iwinfo.assoclist`, `dhcp.ipv6leases`, `luci-rpc.getDHCPLeases`, `luci-rpc.getHostHints`, `luci-rpc.getNetworkDevices` | none |
| `hermes_main_read_uci` | `uci_get` on `system`, `dhcp`, `firewall`, `network` and `wireless`, from an openwrt-mcp that redacts (below); otherwise on `system`, `dhcp`, `firewall` and `network`'s loopback, globals, lan and wan sections | none |
| `hermes_main_read_log` | `logread` | none |
| `hermes_main_change` | `uci_apply`, `uci_confirm`, any setting, each apply rolled back unless confirmed | the factor |
| `hermes_main_change_ubus` | `ubus_call`, by method: `network.reload`, `network.restart`, an interface's `up`, `down` and `renew` (by `network.interface` or the interface's own object), `network.wireless.up`, `.down` and `.reconf`, and `rc.init` (start, stop, restart, reload, enable or disable a service) | the factor |

`exec` and `wg_new_client` are not granted: the second answers with a WireGuard private
key, and whatever a tool answers goes to the model provider.

**What an open window allows.** Since 0.21.5-r11 an open window lets the agent change
settings, the VPN and services, and nothing else by name: settings through `uci_apply`, which
undoes a change nobody confirms (after a reboot too), and the ubus calls above, which bring a
setting into effect or restart a service. No policy the package writes grants rpcd's `file`
object (it runs commands and writes files), `system.sysupgrade` or
`system.validate_firmware_image`, `system.reboot` (a reboot cannot be rolled back, so it is left
to you), `system.signal`, `uci` over ubus (it would go around `uci_apply`'s rollback), procd's
`service` object (`service.set` starts any command), `rpc-sys` (packages and upgrades) or
`exec`; openwrt-mcp refuses each of them before it reaches ubus, window or not. Until r11 the
change policy granted `ubus_call` on everything, and a window was root for its length.

What is still wide, said plainly: `uci_apply` covers every setting, and some settings are
themselves commands the router runs as root, a firewall `include` script or a dnsmasq
`dhcpscript` among them. Until openwrt-mcp refuses those options in `uci_apply`, which a
separate change to it does, an agent in an open window can still reach a root command that
way. A ubus call has no rollback: a service stopped stays stopped until it is started again.
Every call is in openwrt-mcp's audit log. Installing packages is not possible from a window at
all. What the unlock protects against is the time outside the window: an agent misled by a web
page, or anyone who gets the bot to talk, cannot change the router without you.

Each tool has a policy of its own, so one tool's scope globs
cannot widen another's, and no read is a glob over a whole ubus object: `system.*` would
include `system.reboot`. What the agent reads (addresses, hosts, the log, the settings above)
is sent to the model provider, which is what reading means; read them as that before turning
the profile on. A policy of your own for `hermes-main` is yours, and if it grants a change
without a factor, no unlock applies to it.

**Wi-Fi and network settings, never their keys.** Setting up a guest Wi-Fi means reading the
wireless config, and a router's `wireless` and `network` configs hold its secrets beside its
settings: the Wi-Fi passphrases, a WireGuard private key, a PPPoE password. From openwrt-mcp
0.5.0.2 every `uci_get` answer has each secret option replaced by `'<redacted>'`, for every
client and with no way to turn it off, `uci_apply` refuses that marker as a value, and
`openwrt-mcp status --json` says so in `capabilities.uci_get_redacts_credentials`. At every
start the package reads that and grants `uci_get` on `wireless` and the whole of `network` only
when it is `true`. When it is missing (an older openwrt-mcp has no such key) or the status
cannot be read, the grants stay as they were before 0.21.5-r11, `network`'s named sections
only, and the start says why in one line. apk replaces openwrt-mcp's program on an upgrade
without restarting the daemon, so when one is running the package also asks it, through
`/health`, which version it is; when that is not the installed version it restarts openwrt-mcp
once, and if the old one is still the one serving it keeps the narrow grants and names the
version in the log. Two limits, named: openwrt-mcp decides what is secret by the option's name,
so a secret inside an option whose name gives no sign of it (a token pasted into a DDNS update
address, a password inside `pppd_options`) is not redacted; and `ubus call network.wireless
status`, which returns each Wi-Fi interface's configuration with its key, is not redacted at
all, so the package never grants it.

`hermes.security` sets what unlocking asks for, and the Security page (below) writes it for you:

```sh
uci set hermes.security.factor=pin         # none (the default), pin, totp or pin+totp
uci set hermes.security.window=15m         # how long one unlock keeps changes open
uci set hermes.security.max_failures=5     # wrong attempts in a row, then
uci set hermes.security.lockout=15m        # unlocking is refused this long
uci commit hermes && /etc/init.d/hermes-agent restart
```

With the factor `none`, which is what a fresh install has, the change policy is not
written at all, so nothing can change the router through the agent until you set one, and
the agent is told so. With one set, a change is refused until the owner unlocks it; the
refusal names the second factor, and the agent is told to ask its owner to send /unlock
in the private chat and never to ask for a PIN or a code in a message. The model is not
offered openwrt-mcp's `mfa_unlock` and `mfa_lock` tools at all (`tools.exclude` on the
package-written `mcp_servers.openwrt` entry, in every profile), and since 0.21.5-r10 not `exec`
or `wg_new_client` either: it is never granted them, and on 2026-10-08 models that were offered
`exec` pinged through it, were refused, and reported ping as blocked instead of using their own
terminal, where ping works. The agent is told to run network diagnostics there. Also since r10,
upstream's tool search is off (`tools.tool_search.enabled: 'off'` in the agent's `config.yaml`)
unless you set it yourself: it hid every MCP tool behind a search the models did not make, so
they never saw openwrt-mcp's tools and tried `uci` in the terminal, which as `hermes` fails.
The owner note also tells the agent that a UCI section name holds only letters, digits and
underscores, that a port forward is a firewall `redirect`, not a `rule`, and to read a change
back with `uci_get` and report only what the router holds. Unlocking is per agent:
a second agent would be `hermes-<name>`, with its own token, its own policies and its own
window. An unconfirmed `uci_apply` is undone from a snapshot under `/etc/openwrt-mcp`, not
in `/tmp`, so it is undone after a reboot as well as after its timeout.

### Setting up what unlocking asks for

Both ways reach the same place: openwrt-mcp keeps the PIN, as a salted hash, and the secret of
the phone, and `hermes.security` names which of them the agent's change policy asks for. Each
factor is optional, and so is having one: with none, nothing can change the router through the
agent.

**In LuCI**, Services -> Hermes Agent -> Security, in the owner profile. The page shows what is
in force (the profile, the factor, whether a PIN is set, whether a phone is enrolled or being
added, the window, the failure limit and the lockout) and does three things:

- **The PIN**, 4 to 8 digits, typed twice. Neither field is ever filled in from the router, and
  nothing can read the PIN back: the page can say that one is set, and that is all. Clear PIN is
  refused while the factor in force asks for it.
- **A phone.** The page shows a QR code, and the secret to type by hand, once, and asks for the
  code the app shows now. The phone counts only when that code is right. Until then the phone in
  force, if there is one, stays in force and the new secret unlocks nothing. Leaving the page, or
  Cancel, takes the QR off it; nothing keeps it, so starting again makes a new one.
- **The factor**, none, PIN, app code or both, with the window, the number of wrong tries and the
  lockout. A choice is open only when what it needs exists: PIN needs a PIN, app code needs an
  enrolled phone (one still being added does not count), and both need both. That is what keeps
  you from choosing something no unlock could satisfy. Saving writes `hermes.security` and asks
  procd to reload, which restarts the agent, which writes openwrt-mcp's change policy from it.

The window that is open right now cannot be shown: openwrt-mcp keeps it in memory and a separate
process cannot see it. `/lock` in the Telegram chat closes it.

The page needs the agent to have been started once in the owner profile, which is what pairs
`hermes-main` with openwrt-mcp; before that it says so and offers nothing. It offers nothing in
the root and assistant profiles either, where there is no change policy for a factor to guard,
when its status call fails, and when openwrt-mcp is not answering. The backend refuses the same
calls, so a stale tab or a hand-made request gets the same answer.

**Over SSH**, the QR code is printed in the terminal:

```sh
stty -echo; read -r PIN; stty echo; printf '%s\n' "$PIN" | openwrt-mcp pin set hermes-main; unset PIN
openwrt-mcp mfa enrol hermes-main --pending --qr
openwrt-mcp mfa activate hermes-main <code from the app>
uci set hermes.security.factor=pin+totp    # none, pin, totp or pin+totp
uci commit hermes && /etc/init.d/hermes-agent restart
```

`--pending` is the point: it keeps the new secret apart until `activate` has seen a current code, so
a scan that did not work cannot replace the phone in force. Without it `openwrt-mcp mfa enrol` takes
effect at once. On the command line nothing stops you setting a factor before its PIN or phone
exists; then every unlock is refused until they do, and `openwrt-mcp mfa status` says so. The page
cannot be put in that state, and the command line can.

What this does not do, named:

- The six-digit code you type to add a phone is an argument of the `openwrt-mcp mfa activate` the
  backend runs, so it is readable in `/proc` for the moment that takes. It is spent as soon as it
  works. The PIN and the phone's secret are never an argument or in the environment of anything the
  backend starts: the PIN goes to openwrt-mcp on standard input, and the secret is printed by
  openwrt-mcp and handed back to the page once.
- LuCI over plain HTTP carries the PIN and the QR code across your network unencrypted, as it does
  every key typed into the other pages. The page says so when it is served over HTTP. On a network
  you do not trust, use HTTPS, or the SSH way.
- A wrong code at activation is not counted or limited. It is six digits, from a session that is
  already signed in to LuCI.
- The page shows what is in force, and an unlock window is not part of that, as above.

### Unlocking from Telegram

The owner unlocks in the same private chat the agent answers in. With the factor set,
any of these opens the window (the first, `/unlock`, always works; the others are for
whoever finds typing the command a nuisance):

| factor | send |
|---|---|
| `pin` | `/unlock 4821`, or just the PIN |
| `totp` | `/unlock 503917`, or just the six-digit code from the app |
| `pin+totp` | `/unlock 4821 503917`, or the same without `/unlock` |

Exactly what the bot accepts, from `openwrt_unlock.py`:

- One message: `/unlock`, a space, then the PIN, the code, or the PIN and the code. A space or a
  comma separates them, and `/unlock@<your bot's name>` works as Telegram writes it.
- The same digits as a message of their own, with no `/unlock`, once a factor is set.
- A PIN is 4 to 8 digits and a code is 6. With `pin+totp` the PIN comes first.
- `/unlock` on its own opens nothing. The bot deletes it and answers with what to send; with
  the factor `pin` that is "That does not look like what this router asks for. Send /unlock
  followed by your PIN (4 to 8 digits)." Send the PIN after it, as its own message or as
  `/unlock 4821`.

`/lock` closes the window at once. The bot deletes the message first, then asks
openwrt-mcp, and answers only the outcome: open until what time, refused, or locked out
until what time. The message never reaches the model and is written to no log and to no
conversation. If the bot cannot delete it (a failed call to Telegram), it says so and asks
you to delete it yourself. A wrong PIN is not told apart from a wrong code, and five wrong
tries close unlocking for fifteen minutes, which openwrt-mcp counts, not the plugin. A
message that does not fit what the factor asks for (a PIN where a code is wanted) is held
back, deleted and answered with what to send, and is not counted.

Only an id listed in `hermes.telegram.allow_user_id` may try. That is stricter than
chatting: someone paired with the bot, or let in by `allow_all`, cannot use up your five
tries. Anyone else is dropped without an answer. In a group the answer is that
`/unlock` works only in the private chat, where the bot can delete the message, and
nothing is unlocked.

How it is kept from the model, four times over, because the first line can fail to be
wired without anyone noticing and each is tested alone (`scripts/gate-unlock.sh`):

1. A Telegram-native handler, registered by the plugin `openwrt-unlock`, runs before every
   handler the adapter has and consumes the update, so the adapter does not see it at all,
   busy or not. This matters: a message sent while a turn runs is steered, redirected or
   queued by Hermes without passing its `pre_gateway_dispatch` hook.
2. The `pre_gateway_dispatch` hook drops it, for anything that reaches the gateway without
   passing the first.
3. Every request to the model is scrubbed of any line of a user message that is a PIN, a
   code or an `/unlock`, which is what stops a PIN typed on a line of its own inside a
   longer message.
4. The Telegram library prints every update, text included, at DEBUG before any handler
   runs, so the plugin holds that logger at INFO, and Hermes' log redaction carries
   patterns for the `/unlock` forms.

**The agent is told the window is open.** The unlock message is not in the conversation, which is
the point, and an agent that had asked for `/unlock` then saw nothing after it and went on
asking, on a Brume 2 on 2026-10-02. So when the daemon answers an unlock with the time the window
ends, the plugin remembers it, and through upstream's `pre_llm_call` hook it adds one line to your
next message while the window is open: that you have unlocked router changes until that time, and
that a change which was waiting for it should be done now. The line holds no PIN and no code, and
the plugin never keeps either. `/lock`, a lockout and the end of the window all end it, and the
line is taken out of the earlier turns the request replays as well, so after `/lock` the agent
is not left reading "do it now". A scheduled job is not told, since it may not change the router
inside a window. The plugin knows only the windows it saw open: one opened some other way, or
one still open when the gateway restarted, is not announced, and the agent then finds out as it
did before, from a refusal that tells it to ask you to unlock.

The plugin lives in the package's own site-packages with a `hermes_agent.plugins` entry
point, which makes it root's files that the agent, running as `hermes`, cannot rewrite;
the bridge enables it in the owner profile only, in `plugins.enabled`, and takes it out of
`plugins.disabled` there. It is Python standard library only, and what fails on the secret
path drops the message: Hermes lets a message proceed when a hook raises, so nothing on that
path raises. A scheduled job cannot change the router even while a window is open: a
`pre_tool_call` hook refuses `uci_apply`, `uci_confirm` and any `ubus_call` outside the
read list, for a run Hermes marks as scheduled. That holds for a subagent the job hands
the change to: on a Brume 2 on 2026-10-04, with a window open, a job limited to one run
(`--repeat 1`) delegated a `uci_apply` to a subagent (synchronously, as Hermes 0.21.5 runs
delegation from a scheduled job), the subagent's call was refused with "a scheduled job
cannot change the router", and openwrt-mcp's audit log shows no change after the unlock.
The agent is told that if one of your
messages is replaced by a notice that it was removed, it should answer what it was doing
and ask you to send `/unlock` again.

What this does not do, measured and named:

- A PIN alone on a line of a longer message is removed from what the model is sent, and
  stays in the chat and in the conversation database. Send it on its own.
- In a log line, `/unlock <PIN> <code>` and `<PIN> <code>` in a quoted form leave the last
  four digits of the code visible if a log line ever carried them. Hermes masks a match whole
  and leaves the first six and last four characters of anything of 18 or more, a pattern
  must start with two literal characters, and what follows a PIN has none. The gate shows
  that nothing reaches a log in the first place, so this is the last of four lines.
- With a factor set, a line of 4 to 8 digits in what you type is taken for a PIN or a code:
  held back when it is the whole message, and replaced in the request when it is one line
  of several, which includes a number you pasted.
- With `allow_all`, anyone may chat and none may unlock.
- A scheduled job that hands its work to a subagent asynchronously is not measured, and no
  gate covers the subagent path. The synchronous path was measured on hardware, as above.
- In a window, a setting that is itself a command (a firewall include, a dnsmasq script) can
  still be written through `uci_apply` until openwrt-mcp refuses those options, as above. The gateway's own environment holds the
  router token and is readable by any process of the `hermes` user, as invariant 7 says.

### Pairing openwrt-mcp yourself

In the assistant and root profiles the package neither pairs nor writes policies. The
optional [openwrt-mcp](https://github.com/TAIPANBOX/openwrt-mcp) connection adds
policy checks to calls sent through that server, and its policy does not constrain local
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
writes, in this release's shape or the earlier one, which is then adopted. If the token
file is missing when the gateway starts, it starts without this connection and says so
in the log. Clearing the URL removes only the package-managed entry.

This path was exercised on both test routers on 2026-09-27: the openwrt-mcp apk (built
from its `apk` branch for `aarch64_cortex-a53`) installed with `apk add --allow-untrusted`
on vanilla OpenWrt 25.12.5, listening on 127.0.0.1:8730 only, and was removed cleanly
afterward. On the Brume 2, hermes-agent registered the connection's 9 MCP tools through
this UCI wiring, and a `uci_apply` of the system description sent without confirmation
rolled back on its own once the 30 second window ran out. On the Flint 2, granted only
read scopes, board, firmware and interface calls answered and an ungranted `exec` call
was denied by policy. One scope shape needs care: openwrt-mcp matches a grant's scope
with Go's `path.Match`, so a scope on an anonymous UCI section reads its own `[0]` as a
character class rather than a literal index. Grant `system.@system\[0\].description`,
brackets escaped, not the unescaped form its own denial hint suggests (reported upstream
as GlassOnTin/openwrt-mcp#3). That run predates the owner profile. The owner profile has
since run on a Brume 2 on 2026-10-02: a change asked for while locked was refused, a wrong
`/unlock` from Telegram was refused and the right one accepted, and a change made in the
window it opened (`uci_apply` then `uci_confirm` on the system description) went through.
The gates run the rest of it in OpenWrt's own rootfs in a container.

UCI also selects the primary model and OpenAI-compatible endpoint through
`model.default`, `model.base_url` and `model.provider` in Hermes config. They are
written again before every start, including the restarts procd makes on its own, so a
model switched from a chat lasts until the next start. The endpoint can be anywhere the
router reaches, a model gateway on the LAN included: the gateway is also handed
`CUSTOM_BASE_URL` with the same address, which is where upstream's auxiliary calls (the
session title, for one) look for it, so they go to the same endpoint with the same key
(before 0.21.5-r8 an endpoint on the LAN refused every start). Upstream reads that variable
first on every route that would end at OpenRouter's default address, so a fallback to
OpenRouter, or a local-server alias such as `ollama` with no endpoint of its own, also goes to
the UCI endpoint with the main key: a fallback chain does not leave that endpoint, and the
OpenRouter key is not sent to it. Credentials remain environment
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
accidental memory growth; the root profile's tools can modify system controls, and in
the other profiles the agent cannot lift the ceiling it runs under. Verify the controller
on the target router before testing.

procd retries a gateway that fails at start at most five times within an hour and then
leaves it stopped, so a refusal is logged a handful of times rather than every five
seconds. It also runs the service at nice 10, so the router's own work keeps the
processor; "Under the router's own work" above has the measurement.
