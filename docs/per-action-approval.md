# Per-action approval for high-impact router changes

Since 0.21.5-r16, with luci-app-hermes 0.21.5-r4 and openwrt-mcp 0.5.0.5, a high-impact change waits
for the owner's approval of that one change, given from Telegram with the PIN and a code from the
app. The feed carries it in hermes-agent 0.21.5-r22, luci-app-hermes 0.21.5-r6 and openwrt-mcp
0.5.0.8-r1. This page is how the pieces fit together. Setting it up and approving, with pictures:
[approval.md](approval.md); what is held, in plain words: [security.md](security.md#high-impact-changes-wait-for-your-approval);
the rules that decide: openwrt-mcp's README and `features/approval.feature`.

## What was decided

`@decided 2026-10-22` (the owner's choices, paraphrased):

1. Approving a held change takes the PIN and a code from the app, both; approvals are off until
   both exist.
2. The card comes from the same bot the agent talks through; before the code is asked for, the
   plugin restates the headline openwrt-mcp wrote.
3. `wg_new_client` is refused to the agent's client outright, since its answer carries a private
   key.
4. A change may be proposed while the window is closed, within limits: one waiting at a time, six
   an hour, none for an hour after three rejections in a row.
5. `/unlock` and approvals go through a client of the owner's own, `hermes-main-owner`, whose token
   only the plugin holds. It adds no step for the owner: the package pairs it.
6. One person approves, `hermes.security.approver_id`.
7. NTP server changes and an open Wi-Fi into a trusted zone are held too.

Made in the build, `@claude 2026-10-22`:

- With exactly one Telegram id allowed and no approver chosen, that id approves; with several, none
  does until one is chosen, and a high-impact change is refused rather than held. It adds no step
  for the owner of a router only they talk to.
- A reboot is granted to the agent's client only through a hold policy, and only when someone can
  approve; with nobody, it is not granted at all.
- An unknown firewall keyword reads as the one that opens (a redirect target other than SNAT is a
  DNAT, a policy other than REJECT or DROP an ACCEPT), and keywords are read trimmed and in any case.
- Any rewiring is held (a VLAN table, a device's ports or base, what an interface sits on), whatever
  it names. A guest network on a new port-less `br-<name>` bridge the kernel does not have yet runs
  in the window. Also held: an uplink network put into a trusted zone, what a zone takes by device
  or subnet, and raw nftables fragments.
- The plugin polls every 5 s and closes each MCP session it opens; openwrt-mcp writes no audit line
  for an answered `action_list`, so the poll does not wear the flash.

## Who does what

openwrt-mcp classifies every call it has authorised. A high-impact call does not run: it is held in
openwrt-mcp's memory as a record that cannot change, with a hash, and only a second, owner-only
client can approve it, with a fresh factor, against that hash. The `openwrt-unlock` plugin is the
messenger: it shows the card openwrt-mcp wrote, carries the factor on the unlock's secret path and
tells the agent the outcome. The model never sees a code, the owner's token or the card's controls.

| piece | runs as | what it does |
|---|---|---|
| openwrt-mcp | root | classifies each authorised call, holds the high-impact ones, writes the card, checks the factor, applies exactly the held change |
| the init | root, at every start | pairs `hermes-main-owner` into `/etc/hermes-agent/router-mcp-owner.token` (0600), writes the approval section `hermes_main_approval` and names it from both change policies and the package policy, writes the hold policy `hermes_main_hold` when someone can approve, and writes no change policy unless openwrt-mcp reports `actions_held_for_approval` and the approval section reads back |
| the gateway wrapper | root, then `hermes` | hands the owner's token to the gateway's own exec, in the owner profile only; the gateway takes it out of its environment before upstream runs and gives it to the plugin once, so no process the agent starts inherits it |
| the plugin `openwrt-unlock` | `hermes`, in the gateway | lists held changes every 5 s, sends each card with Approve and Reject, restates the headline, carries the PIN and code to openwrt-mcp, edits the card with the outcome and starts a turn for the agent |
| the bridge | `hermes`, at every start | keeps `action_list`, `action_approve` and `action_reject` from the model in every profile, leaves it `action_status` and `action_withdraw`, and lets the plugin start a turn (`allow_gateway_injection`) in the owner profile |
| LuCI, Security | root, through rpcd | who approves, chosen from the allowed Telegram ids; `approvals_ready` once a PIN and a phone exist |

## The flow

| # | Step | Where, and why there |
|---|---|---|
| 1 | The model calls `uci_apply` or `ubus_call`, as for any change. | Hermes; nothing new to route around. |
| 2 | The policy authorises the scope; the classifier runs next, before the window check, so a held change is held with the window open or closed. | openwrt-mcp: root, the one path to a change. A check in the gateway would be skipped by a terminal call with the same token. |
| 3 | A held change becomes a record: a five-letter id (which the PIN scrubber leaves alone), the client, the tool, the normalised input, the card, a fingerprint of every config it was checked against, an expiry of 10 minutes, and a SHA-256 hash of all of it. The agent is told, not as an error, `HELD <id> until <time>`: the owner was asked, do not retry. The audit outcome is `HELD`. | openwrt-mcp's memory, like the window: a restart drops held changes. |
| 4 | The agent's client reads its own records (`action_status`) and may withdraw one (`action_withdraw`); the owner's client reads cards and hashes (`action_list`). | openwrt-mcp. |
| 5 | The plugin lists held changes with the owner's token every 5 s and sends a new card verbatim, as plain text, to the approver's private chat with Approve and Reject. | The plugin; the card never passes through the model. |
| 6 | Approve, or `/approve <id>`: the plugin restates the headline openwrt-mcp holds and asks for the PIN and the code. The next fitting message from the approver is deleted first, kept out of every request to the model, and sent once. | The plugin, on the unlock's secret path. |
| 7 | `action_approve` with the id, the hash, the PIN and the code, on the owner's token. openwrt-mcp checks, in order: the approver of that client, the id still waiting, the hash, the fingerprint (the router unchanged since), no apply awaiting confirmation, the policy still granting; a failed precondition costs no try. Then the factor, against the same five tries as an unlock, with the code's step spent and the window never opened. Then the stored input runs through the tool's own function, its refusal of settings that run code included, with a rollback of 300 s. | openwrt-mcp. |
| 8 | The plugin edits the card and starts a turn for the agent with `inject_message`, in the session the change was proposed from: applied, check the router and confirm; or rejected; or expired. | The plugin. The agent confirms after its check; a change nobody confirms rolls back. |

Reject is one tap and needs no code. `/lock` also rejects every held change.

## What is shown is what is applied

```
Router change waiting for you (KQWPT, ref 3f9a12c0, expires in 10 min)
Asked by hermes-main:
OPENS THE ROUTER TO THE INTERNET: tcp 2222 from any address to 192.168.1.20:22

firewall.ssh_nas, new redirect
  + dest 'lan'
  + dest_ip '192.168.1.20'
  ...
```

- openwrt-mcp writes the card from the record: the headline is a template filled with parsed values,
  and every changed key is listed with its value before and after.
- A secret's value is shown as `<redacted>`, and what the agent chose is quoted after its key with
  anything unprintable escaped. The agent writes no part of the card.
- A card over 3500 characters is refused, never cut short.
- The Approve button carries `owa:<id>:<16 hex of the hash>`, Reject `owr:` the same; `/approve`
  sends the hash of the card the plugin received. A different hash is refused.

## What is held

openwrt-mcp decides on the state a change would leave: the batch applied with the router's own `uci`
to a copy of the configuration in RAM, read back and compared with before. So a change split over
two calls is held on the call that completes it: a redirect made from `lan` and then moved to
`wan`, a zone renamed, a bridge taking in the internet port.

| headline on the card | what it covers |
|---|---|
| OPENS THE ROUTER TO THE INTERNET | an enabled `redirect` or `rule` from an internet zone or `*` whose target is not DROP or REJECT |
| WEAKENS THE FIREWALL | an internet zone that accepts or forwards what comes in, a forwarding from the internet, a change in which zones face the internet or what a zone takes by device or subnet, an uplink network put into a trusted zone, raw nftables |
| REWIRES THE NETWORK | a VLAN, a device's ports or base, what an interface sits on |
| CHANGES VPN OR POLICY ROUTING | a WireGuard interface or peer, a route or rule for every destination, pbr |
| CHANGES WHO ANSWERS DNS | dnsmasq's upstream servers and rebind protection, a name with a dot answered locally, an interface's DNS servers, DHCP option 6 |
| CHANGES THE ROUTER'S TIME SERVERS | the NTP servers the app codes depend on |
| OPENS WI-FI WITHOUT A PASSWORD INTO A TRUSTED NETWORK | an open Wi-Fi on a network in a trusted zone (input ACCEPT, not facing the internet), or such a zone made trusted |
| STOPS A SERVICE THAT GUARDS THE ROUTER | `rc.init` stop or disable of the firewall, dropbear, uhttpd, rpcd, openwrt-mcp, network or dnsmasq |
| REBOOTS THE ROUTER | `system.reboot`, granted only through the hold policy |
| COULD NOT BE CHECKED | a state that cannot be built or read: held when its card renders, refused otherwise |

What only a person may do is refused to the agent's client whatever a grant says: running a command,
issuing a WireGuard client, the configs of hermes, openwrt-mcp, rpcd, dropbear, uhttpd, LuCI, fstab
and ucitrack, and rpcd's file object, a firmware, a signal, procd's service object, uci and rpc-sys
over ubus. The approval section can hold or refuse more (`list hold`, `list refuse`), never less.
The rest of the change policies' scope runs in the window as before.

## Threats and controls

| Threat | Control |
|---|---|
| A flood of cards from an injected agent | one waiting change per client, six an hour, none for an hour after three rejections in a row; a scheduled job proposes nothing |
| Approving by habit | a code every time, one change per card, no "always", a 10-minute expiry |
| A message from the agent made to look like a card | the plugin restates openwrt-mcp's headline before it asks for the code |
| Replay | an id is used once, and the code's step is spent per client, shared with `/unlock` |
| The router changed since the card | the fingerprint is checked again, and staged `uci changes` refuse the apply |
| A taken-over Telegram session | the PIN and the phone's code, one approver, the lockout, and no key ever handed over in the chat |
| The agent spending the owner's tries | unlocking and approving only from the owner's client, whose token the agent never has |
| The window | approving neither opens nor extends it, a window approves nothing, one apply at a time, one budget of wrong tries |

## How it is checked

In this repository: six checks of `scripts/gate-unlock.sh` against the real gateway, plugin and
daemon (`check_agent_cannot_unlock_itself`, `check_no_change_policy_without_held_capability`,
`check_high_impact_change_held_in_window`, `check_held_change_approved_from_the_chat`,
`check_held_change_rejected_from_the_chat`, `check_owner_token_never_reaches_the_agent`); seven
tests of `scripts/test-runtime.py`, from the owner's client and its policies to a bare PIN sent
while a change waits, which opens no window (0.21.5-r17); and two LuCI checks that only an allowed
id can be chosen to approve. `scripts/teeth-unlock.sh` faults 74 to 86, `scripts/teeth-runtime.py`
and `scripts/teeth-luci.sh` faults 43 to 46 plant the faults these checks catch. In openwrt-mcp:
the nineteen scenarios of `features/approval.feature`, each bound to its tests.

On a Flint 2 (OpenWrt 25.12.5, owner profile, one Telegram id allowed), 2026-10-22:

- 20:09 to 20:15 BST, r16, LuCI r4 and openwrt-mcp 0.5.0.5 from CI, the owner's client driven with
  its token as the plugin drives it: the agent's own `mfa_unlock` was refused without a try; the
  owner's opened the window; a port forward from wan in the open window answered `HELD`, with the
  firewall file and the ruleset unchanged; `action_approve` with the PIN and a fresh code applied
  it, and fw4 had `tcp dport 2224 dnat ip to 192.168.1.250:22`; the same approval again was refused;
  a second one, approved after a firewall section was added by hand, was refused for the changed
  configuration; reject needed no factor; `mfa_lock` closed the window. In one turn of
  `anthropic/claude-haiku-5.5` asked for a port forward, the agent read with `uci_get`, called
  `uci_apply` once, got `HELD`, did not retry, and said it waits for the owner's approval.
- 22:52 BST, r16, LuCI r4 and openwrt-mcp 0.5.0.5 from the feed, the PIN and a phone set by the owner
  in LuCI: asked through Telegram for the same port forward, the agent got `HELD`, the card came from
  the bot, `/approve` and then the PIN and a code applied it, fw4 had the rule, and the agent, told
  the outcome in its chat, read the router back and called `uci_confirm` itself twelve seconds later.

Each run recorded the router's state first and put it back after. Since openwrt-mcp 0.5.0.6 a code
from the app is accepted until 60 s after it leaves the app's screen, so it can be typed after the
PIN.
