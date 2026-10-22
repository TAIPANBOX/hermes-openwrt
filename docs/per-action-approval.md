# Per-action approval for high-impact router changes

This is the design as it was written on 2026-10-22, before any of it was built, kept as the record
of why the pieces are where they are. Where the build differs, the difference is in the next
section; what holds now is in CLAUDE.md (invariants 18 and 26), `docs/security.md`, and
openwrt-mcp's README and `features/approval.feature`.

## What was decided, and where the build differs

`@decided 2026-10-22` (the owner's choices on the open questions of section 9, paraphrased):

1. Approving a held change takes the PIN and a code from the app, both; tier 3 is off until both
   exist.
2. The card comes from the same bot the agent talks through, not a second one; before the code is
   asked for, the plugin restates the headline openwrt-mcp wrote.
3. A WireGuard client's configuration is handed over on a one-time LuCI page (stage 6, not built
   yet); until then `wg_new_client` is refused to the agent's client outright.
4. A change may be proposed while the window is closed, within limits: one waiting at a time, six
   an hour, none for an hour after three rejections in a row.
5. `/unlock` and approvals go through a client of the owner's own, `hermes-main-owner`, whose token
   only the plugin holds. It adds no step for the owner: the package pairs it.
6. One person approves, `hermes.security.approver_id`.
7. NTP server changes and an open Wi-Fi into a trusted zone are held too.

`@claude 2026-10-22`, where the build differs from the text below:

- With exactly one Telegram id allowed and no approver chosen, that id approves; with several,
  none does until one is chosen, and a high-impact change is refused rather than held. A choice of
  mine, made because it adds no step for the owner of a router only they talk to.
- A reboot is granted to the agent's client only through a hold policy, and only when someone can
  approve; with nobody, it is not granted at all, as before.
- An unknown firewall keyword reads as the one that opens (a redirect target other than SNAT is a
  DNAT, a policy other than REJECT or DROP an ACCEPT), and keywords are read trimmed and in any
  case: found in review.
- The design held the internet port put into a bridge. The build holds any rewiring instead (a
  VLAN table, a device's ports or base, what an interface sits on), whatever it names, since
  following every way netifd resolves a device did not converge in review; a guest network on a
  new port-less `br-<name>` bridge the kernel does not have yet still runs in the window. Also held,
  from review: an uplink network put into a trusted zone, what a zone takes by device or subnet,
  and raw nftables fragments.
- The plugin polls every 5 s and closes each MCP session it opens; openwrt-mcp writes no audit line
  for an answered `action_list`, so the poll does not wear the flash.
- The design's names `TestTier3HeldWithWindowOpen` and the rest are the tests in openwrt-mcp; the
  hermes-openwrt checks are `check_agent_cannot_unlock_itself`,
  `check_no_change_policy_without_held_capability`, `check_high_impact_change_held_in_window`,
  `check_held_change_approved_from_the_chat`, `check_held_change_rejected_from_the_chat` and
  `check_owner_token_never_reaches_the_agent`.

---

Design only, 2026-10-22; nothing built or run. Read at hermes-openwrt `docs/readme-current` (0.21.5-r14), openwrt-mcp `8eff834` (0.5.0.4; main is at `9864474`) and upstream Hermes `f97608f`. References are `file:line` at those commits; "inference" marks what was not read or run.

## 1. The decision

openwrt-mcp classifies every call it has authorised. A tier-3 call does not run: it is held in openwrt-mcp's memory as an immutable record with a hash, and only a second, owner-only client can approve it, with a fresh factor, against that hash. The `openwrt-unlock` plugin is the messenger: it shows the card openwrt-mcp wrote, carries the factor on the existing secret path and tells the agent the outcome. The model never sees a code, the owner token or the card's controls.

## 2. What exists today

- The window is per client, in memory, opened by `Attempt` (`mfa.go:29-33`, `:551-578`); `mfaGate` only asks whether it is open (`tools.go:143-161`).
- Policies are first-match glob allow-lists (`config.go:327-353`). Arguments are not scope, so `rc.init` can stop the firewall in a window, a named limit (`CLAUDE.md:331-334`).
- `mfa_unlock` needs no grant (`tools.go:570`) and the agent's token is in its terminal (`CLAUDE.md:75-77`), so the agent can already spend the owner's tries (inference).
- The plugin calls openwrt-mcp with the agent's token (`openwrt_unlock.py:299-318`, `hermes-gateway:57`).
- `system.reboot` and `wg_new_client` are never granted (`hermes-agent.init:78`, `:251-253`). `wg_new_client` writes GL.iNet's `wireguard_server` and stores the client's private key on the router (`wireguard.go:225`, `:304`); stock OpenWrt 25.12 has no such config (inference).
- "Pending" already names an apply awaiting `uci_confirm` (`server.go:201-208`), so new records are **held actions**.

## 3. Flow

| # | Step | Where, and why |
|---|---|---|
| 1 | The model calls `uci_apply`, `ubus_call` or `wg_new_client` as today. | Hermes; nothing new to route around. |
| 2 | Policy authorises the scope; the classifier runs next, before the window check. | openwrt-mcp: root, holds policy and factors, the only path to a change. A gateway check is skipped by a terminal call with the same token. |
| 3 | Tier 3: store id (5 letters, so the PIN scrubber `openwrt_unlock.py:61` leaves it), client, tool, normalised input, card, base fingerprint (SHA-256 of every config read), expiry (10 min); hash = SHA-256 of all. Return, not as an error, `HELD KQWPT until 12:44; the owner was asked; do not retry`; audit outcome `HELD`. | Memory only, like the window: a restart drops it. Flash holds redacted audit lines (`audit.go:97-119`). |
| 4 | The agent client reads its own records (`action_status`); the approver client `hermes-main-owner` reads cards and hashes (`action_list`). | openwrt-mcp. |
| 5 | The plugin polls `action_list` with the owner token every 5 s (`spawn_task`, upstream `plugins.py:418-428`) and sends the card verbatim, plain text, with [Approve] [Reject]. | Plugin; the card never passes through the model. |
| 6 | Approve, or `/approve KQWPT`: the plugin restates the headline and asks for PIN and code; the group -1 handler (`openwrt_unlock.py:460-505`) takes the next fitting message, deletes and scrubs it (`:238-258`). | Plugin: the existing secret path, extended to `/approve`. |
| 7 | `action_approve{id, hash, pin, code}`, owner token. In order: approver of that client; id live; hash equal; fingerprint unchanged; no apply awaiting confirmation (`server.go:328-333`); policy still grants. Then a new `Verify` checks factors, counts failures, spends the TOTP step and never opens the window (unlike `mfa.go:574-577`). Then the stored input runs through the tool's own function (`refuseCodeExec` included, `server.go:364`), rollback 300 s. | openwrt-mcp. A failed precondition costs no try. |
| 8 | Reply: the agent's outcome, plus an owner-only artifact (a WireGuard config). | openwrt-mcp. |
| 9 | The plugin edits the card and starts an agent turn with `inject_message` (`plugins.py:603-635`; the bridge sets `allow_gateway_injection`): "KQWPT applied; rollback at 12:41; check, then uci_confirm <token>", or rejected, or expired. | Plugin. The agent confirms after its check, as decided for windows (`CLAUDE.md:439-442`); without the turn the rollback fires first. |

Reject is one tap with no code. `/lock` also rejects every held action.

## 4. What is shown is what is applied

```
Router change waiting (KQWPT, ref 3f9a12c0, until 12:44)
OPENS THE ROUTER TO THE INTERNET: tcp 2222 from any address to 192.168.1.20:22
firewall.ssh_nas, new redirect
  + src 'wan'  + src_dport '2222'  + proto 'tcp'
  + dest 'lan'  + dest_ip '192.168.1.20'  + dest_port '22'  + name 'ssh_nas'
```

- Rendered by openwrt-mcp from the record; the headline is a template filled with parsed values (`netip`, integers), and an unparsable value is shown as such.
- Every changed key, before and after, redacted by option name (`uci_redact.go`); model-chosen strings only quoted after their key; no agent "reason".
- Over 3500 characters: refused, never truncated.
- The button carries `owa:<id>:<16 hex of hash>` (64-byte limit, `adapter.py:4301`); `/approve` sends the hash of the card the plugin received. A mismatch is refused.

## 5. Classification

Built-ins are compiled in with no switch, as `uci_noexec.go:11-17` argues. A new UCI section `approval` per client (approver, factor, ttl, max_open, max_per_hour, pause_after_rejects, `list hold`, `list refuse`) only adds rules; a change policy naming a missing or invalid one fails the config load. A policy with `option hold '1'` grants scopes that are always held.

Predicates read the resulting state: the batch applied to a RAM copy of the configs with `uci -c <tmp> -P <tmp>` (as `hermes-agent.init:281`), read with `uci -X show` (as `uci_noexec.go:326-345`), compared with before. WAN zones list `wan` or `wan6` or have `masq 1`; the WAN device is `network.wan.device` before the change.

| Candidate | Rule | Tier |
|---|---|---|
| Reboot | `system.reboot`, only in a hold policy; refused while an apply awaits confirmation, which a restart rolls back (`server.go:489-509`) | 3 |
| Port to the WAN | an enabled `redirect` or `rule`, src a WAN zone or `*`, target not DROP or REJECT (unset counts as open), absent before | 3 |
| Firewall weakened | a WAN zone's effective input or forward becomes ACCEPT; a `forwarding` from a WAN zone; the WAN-zone set changes; the WAN device joins a non-WAN interface or bridge | 3 |
| VPN routing | any change to a `wireguard_*` section or wireguard interface; a route or rule to 0.0.0.0/0 or ::/0; anything in `pbr` | 3 |
| Upstream DNS | dnsmasq `server`, `address`, `noresolv`, `resolvfile`, `rebind_protection`; `dhcp_option` 6; `host`, `domain`, `cname` names with a dot; interface `dns`, `peerdns` | 3 |
| Stopping a guard | `rc.init` stop or disable of firewall, dropbear, uhttpd, rpcd, openwrt-mcp, network, dnsmasq (closes the limit above) | 3 |
| `wg_new_client` | only in a hold policy, when opted in; private key only in the owner artifact; the router keeps the public key | 3 |
| Human only | configs hermes, openwrt-mcp, rpcd, dropbear, uhttpd, luci, fstab, ucitrack; `file.*`, `system.sysupgrade`, `service.*`, `uci.*`, `exec`; built in for a client with an approval section, whatever a hand grant says | refused |
| Unsure | state not buildable or parsable, a section type unreadable, a predicate errors | 3 if the card renders, else refused |
| The rest of `MCP_CHANGE_UCI` and `MCP_CHANGE_UBUS` (`hermes-agent.init:92-93`) | | 2 |

Since predicates read state, a split is held on the call that completes it: a redirect made from `lan` then moved to `wan`, a zone rename, a bridge edit taking in the WAN port.

## 6. Threats

| Threat | Control |
|---|---|
| Injected approval spam | one open action per client, 6 an hour, paused an hour after 3 rejections; scheduled jobs cannot propose (`openwrt_unlock.py:637-654`) |
| Approval fatigue | a code every time; no "always", unlike upstream's prompt (`adapter.py:4277-4281`); one action per card; 10 min expiry |
| A fake card from the agent | the plugin restates the real headline before the code; a separate bot (Q2) removes the case |
| Replay | id single-use; the TOTP step spent per client (`mfa.go:636-639`), shared with `/unlock` |
| Drift | fingerprint re-checked; staged `uci changes` refuse (`server.go:339-341`) |
| Telegram takeover | PIN and phone code; only `approver_id`; the lockout; no keys through Telegram by default (Q3) |
| Agent spends the tries | approval only from the owner client, whose token the plugin pops from `os.environ` at register (upstream strips plugin keys only for terminal providers, `local_env_policy.py:270-279`) |
| The window | approval neither opens nor extends it; a window approves nothing; one apply at a time; one failure budget |

## 7. Changes by repo

**openwrt-mcp** (Go, on main, whose `addToolShaped` is the hook): `approval.go`, `classify.go`, the call in the gate, tools `action_status`, `action_withdraw` (own client), `action_list`, `action_approve`, `action_reject` (approver), `MFAStore.Verify`, outcome `HELD`, capability `actions_held_for_approval`, a stock-OpenWrt `wg_new_client`, `features/approval.feature`.

**hermes-openwrt**: the init pairs `hermes-main-owner` into a root-only token file, writes `hermes_main_approval` and `hermes_main_hold`, and writes no change policy unless the capability is reported and the section reads back (`mcp_daemon_caps`, `hermes-agent.init:126-169`); the wrapper exports and unsets the owner token (`hermes-gateway:39`, `:57`); the plugin gains the callback handler, `/approve`, `/reject`, poll, card, injected turn and scrub patterns; the bridge hides approver tools (`set-toolsets.py:243`) and sets `allow_gateway_injection`; LuCI Security gains approver, factor, delivery; invariant 18 and `docs/security.md` change.

**Upstream needs no patch.** Plugin Telegram handlers include a `CallbackQueryHandler` scoped by `pattern` (`plugins.py:856-860`), hoisted ahead of core (`adapter.py:2947-2965`); inline keyboards are python-telegram-bot's, as the adapter uses (`adapter.py:4227-4229`). Not used: `pre_tool_call`'s `approve` directive and `register_approval_transport` (`plugins.py:1859-1863`, `:430-454`): they decide in the gateway, without a factor, and a terminal call skips them. Fallback without buttons: `/approve <id>`, then the factor; `/reject <id>`. How the plugin finds the DM's `session_key` is not yet read (inference).

## 8. Testing (T3)

Each check is committed alone and run first against r14 and `8eff834`, where it must fail.

| Invariant | Check | Teeth mutant | Hardware |
|---|---|---|---|
| Tier 3 never runs on a window | `TestTier3HeldWithWindowOpen` per candidate (today the redirect applies) | predicate gives 2 | Flint 2: card shown, `nft list ruleset` unchanged |
| Only the shown batch runs | `TestApproveRefusesAnotherHash` | args out of the hash | |
| Approver and fresh factor only | `TestAgentClientCannotApprove`, `TestApproveStepSpent`, `TestApproveNeverOpensWindow` | approver check skipped; replay `<=` made `<`; `Attempt` reused | approve; replay refused |
| Drift refuses, no try spent | `TestApproveRefusedAfterDrift` | fingerprint skipped | LuCI edit, then approve |
| State, not call | `TestSplitRedirectHeldOnSecondCall`, `TestWanPortIntoLanBridgeHeld`, `TestZoneRenameHeld` | batch classified alone | split via the terminal |
| Unsure is stricter | `TestUnreadableTypeHeld` | error gives 2 | |
| Limits, expiry | `TestHeldExpires`, `TestOneOpenPerClient`, `TestRestartDropsHeld` | TTL ignored; max_open +1 | |
| Key only to the owner | `TestWgPrivateKeyOnlyInOwnerArtifact` (result, audit, UCI) | artifact in agent result | Flint 2 |
| Nothing secret reaches the model | `gate-unlock.sh` `check_approve_never_reaches_model`, `check_owner_token_not_in_terminal` | no pop; no scrub | |
| No change policy without approval | `check_no_change_policy_without_held_capability` | written anyway | |

Mutation targets: each predicate's comparison, the WAN-zone set, each hash field, the approver check, the factor list, the TTL and max_open bounds, the replay and fingerprint comparisons, artifact routing; each reported with its catching test. Hardware runs record and restore the router's state (invariant 15).

## 9. Open decisions

1. Approval needs PIN and phone code? **Recommended: yes**, tier 3 off until both exist; a code alone by opt-in; a PIN alone never (not fresh).
2. Cards from a separate bot the agent never writes through? **Recommended: yes.**
3. WireGuard config by LuCI one-time page or Telegram document? **Recommended: LuCI**, the key stays on the LAN; Telegram by opt-in, deleted after 10 min.
4. Proposals while the window is closed? **Recommended: yes**, within the limits.
5. `/unlock` through the owner client too, so the agent cannot spend tries? **Recommended: yes.**
6. Several allowed Telegram ids? **Recommended: one explicit `approver_id`**, tier 3 off until set.
7. More held rules (NTP servers, which the codes depend on; open Wi-Fi into a trusted zone)? **Recommended: yes.**

## 10. Effort, agent-time

| Stage | Content | Time |
|---|---|---|
| 1 | openwrt-mcp: store, hash, approver, tools, `Verify`, reboot and rc.init rules, tests, teeth | 1 day |
| 2 | State classifier, split tests, mutation run | 1.5 days |
| 3 | hermes-openwrt: init, wrapper, plugin, bridge, gate-unlock checks, `/unlock` via owner client | 1.5 days |
| 4 | LuCI, docs, invariant 18 | 0.5 day |
| 5 | Flint 2 runs | 0.5 day |
| 6 | Separate bot; stock-OpenWrt `wg_new_client` | 1.5 days |

About 6.5 days; stages 1 to 5 stand without 6.
