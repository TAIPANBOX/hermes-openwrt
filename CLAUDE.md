# Hermes OpenWrt invariants

`@claude` 2026-09-24: first written by Codex on 2026-09-19, amended on 2026-09-24. Each
invariant names what holds it. The upstream Python payload is installed unpatched; the
package adds one shim (`webbrowser.py`) and its own helpers under `/usr/libexec`, and
leaves out the two dependencies invariant 17 names.

`@decided 2026-09-24`: the router's own configuration (UCI) is the authority for the
primary model, its endpoint and the tool selection at every start, including restarts
procd makes on its own. A model switched from a chat lasts until the next start.

`@decided 2026-09-24`: the package is for ARM routers. x86_64 is no longer built in CI,
gated or published; the build scripts still take `ARCH=x86_64` by hand.

`@decided 2026-09-25`: the package is for OpenWrt 25.12 only. The 24.10 line, its opkg
packages, its usign-signed feed, their gates and its CI job are gone; the builds refuse
any other `RELEASE`, and the next publish drops `24.10/` from the feed.

1. Packages install, run, preserve configuration and remove cleanly on OpenWrt 25.12.
   `@decided 2026-10-05`: an upgrade leaves the service's start at boot as the owner set it;
   only an install switches it on, as OpenWrt's own `default_postinst` does
   (gate: `scripts/gate-package.sh`, bound to `features/package.feature`, teeth: `scripts/teeth.sh`).
2. Telegram is optional, disjoint from the base payload, and refuses unusable setup
   (gate: `scripts/gate-telegram.sh`).
3. All provider, Telegram and MCP credentials are read, as root, by the exec wrapper on
   every launch and respawn; procd stores paths only. A router MCP token missing at exec drops
   the MCP connection, not the service (gate: `scripts/gate-runtime.sh`).
4. UCI tool selection writes the upstream Telegram and cron platform defaults,
   including an empty selection. Invalid YAML or tool names refuse startup and
   preserve the existing file; a file that already matches UCI is left byte for byte
   (gate: `scripts/gate-runtime.sh`). This is not a global authorization allowlist:
   upstream job overrides, plugins and MCP still apply.
5. The optional MCP connection reaches the upstream loader with a token placeholder,
   preserves unrelated entries, refuses an operator entry of a different shape, adopts
   one identical to its own, and is removed when disabled (gate: `scripts/gate-runtime.sh`).
   MCP policy governs MCP calls only.
6. A nonzero memory limit is applied and read back before every gateway exec, only in
   the dedicated procd cgroup. Missing cgroup v2 memory delegation refuses startup.
   Zero lifts any ceiling an earlier start left in that cgroup, because procd on 25.12
   never removes it (gate: `scripts/gate-runtime.sh`, kernel OOM and zero-lift).
7. `@decided 2026-10-01`, superseding "the service runs as root": the gateway and every
   tool it starts run as the unprivileged user `hermes` in the owner and assistant
   profiles, and as root only in the root profile (`admin` is its old name). The exec
   wrapper is root up to its last line, because it applies the memory ceiling and reads
   the root-only key files, and then goes through `/usr/libexec/hermes-drop`: supplementary
   groups, gid, then real, effective and saved uid together, verified, with no way back.
   Its two helpers and the init's own run of the bridge run as the same user, so root never
   runs upstream's code over files the agent can write. The data directory belongs to the
   user the agent runs as: the init hands it over when its owner differs (once, not at
   every start, and never through a symlink) and refuses a directory the agent cannot write
   in. The `hermes` account stays when the package is removed, so files it owns never fall
   to another user. `apk` runs `post-upgrade`, not `post-install`, when it replaces a
   version, so the account is made by both. Neither tool defaults, nor MCP, nor memory
   controls are an OS security sandbox. `@claude` 2026-10-01, a limit named and not fixed:
   a process running as hermes, the agent's own terminal included, can read the gateway's
   environment in `/proc/<gateway>/environ`, which is where the keys are; the files on disk
   stay root-only. `@claude` 2026-10-02, 0.21.5-r5: a data directory that does not exist is
   made 0700 and any missing parent 0755, each under a umask the init sets itself, because a
   boot starts the service with 077 and `mkdir -p` then closed a new `/srv` to everyone but
   root, so `hermes` could not reach its own directory and the start was refused as "cannot
   write"; a parent that exists is left as it is, and one the agent cannot enter stops the start
   and is named with its mode. `@measured` 2026-10-02 by `ONLY="check_fresh_router_without_srv_starts
   check_unreachable_parent_is_named" ./scripts/gate-unlock.sh` against 0.21.5-r4: both red, on
   that refusal. (gate: `scripts/gate-unlock.sh` `check_gateway_runs_as_hermes_user`,
   `check_key_files_root_only`, `check_memory_ceiling_non_root`,
   `check_upgrade_hands_data_dir_to_hermes`, `check_fresh_router_without_srv_starts`,
   `check_unreachable_parent_is_named`, and `scripts/gate-package.sh`
   `check_clean_removal`; teeth: `scripts/teeth-unlock.sh`, `scripts/teeth-runtime.py`; the
   environment limit is not enforced).
8. UCI selects the primary model, OpenAI-compatible endpoint and file-backed key, and
   the wrapper re-applies them before every exec, so upstream state such as a model saved
   from a chat cannot outlive a restart. The actual upstream resolver must then agree;
   conflicting dotenv/provider/pool/header settings refuse startup and preserve operator
   credentials. Explicit job/channel overrides and fallback chains retain upstream
   semantics (gate: `scripts/gate-runtime.sh`).
   `@decided 2026-10-05`: an endpoint on the LAN works as UCI names it, with nothing added by
   hand to the agent's `.env`. `@claude` 2026-10-05, how (0.21.5-r8): the wrapper exports
   `CUSTOM_BASE_URL` equal to the UCI endpoint, because upstream's auxiliary clients (the
   session title among them) resolve bare `custom`, which takes `model.base_url` off loopback
   only when `model.provider` is `custom` (upstream #14676), and ours is `uci`: such an endpoint
   fell to OpenRouter's default address with no key and the preflight refused every start. The
   preflight protects `CUSTOM_BASE_URL` like `OPENAI_BASE_URL`; a `.env` line with the same
   address, written exactly as UCI has it, is accepted. `@claude` 2026-10-05, a side effect named
   and kept: upstream reads `CUSTOM_BASE_URL` first on every route that ends in its OpenRouter
   fallback, so an `openrouter` route (a fallback entry, a job) and a local-server alias with no
   endpoint of its own resolve to the UCI endpoint with the main key, never the OpenRouter key;
   a fallback to OpenRouter therefore does not leave the UCI endpoint. `@measured` 2026-10-05 by `./scripts/gate-runtime.sh
   RuntimeTests.test_endpoint_on_the_lan_starts_and_answers` against 0.21.5-r7: red, on
   "startup refused (AuthError)", the line a Flint 2 logged the same day (gate:
   `scripts/gate-runtime.sh` `check_endpoint_on_the_lan_starts_and_answers`,
   `check_dotenv_cannot_move_the_endpoint_the_wrapper_names`,
   `check_routes_that_would_reach_openrouter_stay_on_the_lan_endpoint`; teeth: `scripts/teeth-runtime.py`).
9. Runtime, LuCI and unlock scenarios bind both ways to the checks that run them, and
   product mutations must turn their named test red with green restored and empty
   discovery refused (gate: `scripts/gate-scenarios-bound.sh`, `scripts/teeth-runtime.py`,
   `scripts/teeth-luci.sh`, `scripts/teeth-unlock.sh`).
10. procd respawn is bounded (`3600 5 5`): a gateway that keeps failing at start is
    retried at most five times within an hour, then left stopped, instead of being
    restarted every five seconds (gate: `scripts/gate-runtime.sh`).
11. LuCI: the read permission is exactly `hermes` status, logs and security_status plus the
    `hermes` UCI config, with no other ubus object or method (procd's service list included),
    no file access and no other scope. `@claude` 2026-10-02, a deliberate change at LuCI r13:
    security_status joined the grant, which until then was status and logs. It answers
    facts only (the profile, the factor in force and its window, failure limit and lockout,
    whether a PIN is set, whether a phone is enrolled or being added, and whether openwrt-mcp
    answers and has the agent's client), never a PIN, a phone's secret, an otpauth address or
    a QR, and exactly those keys; set_pin, clear_pin, enrol_start, enrol_activate and
    set_factor are write permission alone, since enrol_start returns the QR once to the call
    that asked and set_pin takes a PIN. Nothing the caller sends reaches a shell and no
    secret reaches a program's arguments or environment: the backend reads the message from
    a pipe with jsonfilter and exports nothing, never jshn's json_load (which puts the whole
    message on a command line) or json_get_var (which exports what it reads), and the one
    reply that holds a secret is written with printf. That covers `set_secret` too, which
    used json_load until LuCI r13. The PIN goes to `openwrt-mcp pin set hermes-main` on
    standard input only. The Security calls apply to the owner profile only and refuse
    elsewhere, refuse when the agent's client is not paired or openwrt-mcp does not answer,
    and set_factor refuses a factor whose prerequisite does not exist (pin needs a PIN set,
    totp an active phone, pin+totp both; a phone still being added does not count), refuses a
    window or lockout the init would refuse, and commits `hermes.security` without another
    LuCI session's staged changes; clear_pin refuses while the factor in force asks for the
    PIN. The page offers what the backend would accept and nothing otherwise, never fills a
    PIN field, and shows a phone's QR and secret once, taking them off the page when the
    phone is activated, when the page is left or on Cancel. `set_secret` writes only its fixed slot under
    `/etc/hermes-agent`, refuses when UCI points the service at another file, and reports
    a failed write; no method returns a key. `status` reports the free space where the
    data directory lives or, before the first start, where it will be created, for the
    directory the service uses (an empty option included), and never creates it. A
    further provider's slot is `provider:<name>`, a name the service accepts and never
    `provider` (the main key's file), confined to `/etc/hermes-agent/<name>.key`, refused
    when UCI points that provider elsewhere. ChatGPT sign-in, its status and sign-out are
    write-permission calls; the sign-in runs detached so the call returns at once, and
    `chatgpt_signed_in` comes from the name upstream files the tokens under, never from
    the tokens. `status` reads the agent's version from its installed metadata and never
    runs `hermes`. The Providers page deletes a provider's key with the provider, unless
    UCI points it at a file the page does not manage, and what the pages say just before
    a reload is shown after it, once: for Save & Apply only once LuCI reports the apply
    went through, and never when older than ten minutes. A Save & Apply with nothing for
    LuCI to apply (a key alone goes past UCI, and LuCI then neither announces nor reloads)
    says "Saved" at once, unless a key failed; what an unannounced apply left waiting is
    dropped at the next one, so "Saved" is never shown twice (gate: `scripts/gate-luci.sh`
    `check_read_acl_is_narrow`, `check_secret_never_returned`, `check_security_status_reports_facts_only`,
    `check_security_factor_never_outruns_what_exists`, `check_security_refused_outside_the_owner_profile`,
    `check_security_page_calls_are_granted` and the four `check_security_*` page checks in
    `scripts/test-luci-views.mjs`, and `scripts/gate-unlock.sh` `check_luci_pin_write_only`;
    teeth: `scripts/teeth-luci.sh`, `scripts/teeth-unlock.sh`).
12. `@decided 2026-09-24`: two profiles, chosen in `hermes.main.profile`, govern which
    tools the agent may use. assistant disables terminal, code execution and file tools
    regardless of what the `toolsets` list selects; admin leaves every selected tool
    available, running as root as today. assistant applies wherever no profile is set,
    including on an existing router's configuration from before this option existed, and
    an unrecognised value refuses to start (gate: `scripts/gate-runtime.sh`,
    `scripts/teeth-runtime.py`).
    `@decided 2026-09-24`, later the same day, superseding the default above: admin
    applies wherever no profile is set, existing routers included; assistant is chosen,
    and it tells the agent it has no terminal, code execution or file tools (gate:
    `scripts/gate-runtime.sh`, `scripts/teeth-runtime.py`).
    `@decided 2026-10-01`, superseding both: three profiles, and one old name. owner applies
    wherever no profile is set, existing routers included, so an upgraded router whose
    profile was unset stops running its agent as root, and the start says so; it runs as
    `hermes` with every selected tool and reaches the router only through openwrt-mcp
    (invariant 18). assistant runs as `hermes` with terminal, code execution and file tools
    off, as before. root is the old admin: every selected tool, as root, no unlock, an
    explicit choice that prints a warning at every start; `admin` is accepted as another
    name for it. An unrecognised value still refuses to start (gate: `scripts/gate-runtime.sh`,
    `scripts/teeth-runtime.py`, `scripts/gate-unlock.sh` `check_root_profile_is_opt_in_and_warned`).
13. The service runs at nice 10, so the router's own work keeps the processor: on a
    Brume 2 carrying a WireGuard tunnel on 2026-09-24, a conversation at the default
    priority took a third of the tunnel's throughput while it ran and a quarter at
    nice 10 (docs/measured.md, "Under the router's own work") (gate: `scripts/gate-runtime.sh`,
    `scripts/teeth-runtime.py`).
14. One turn makes at most `hermes.main.max_turns` model calls with tools, 20 unless
    changed, written into upstream's `agent.max_turns`, which the gateway turns into its
    per-turn budget; a turn that reaches it gets one more call, without tools, to sum up
    (upstream's `agent/turn_finalizer.py`). A value outside 1 to 500 refuses to start. On
    2026-09-24 one assistant turn spent all of upstream's default of 90 (gate:
    `scripts/gate-runtime.sh`, `scripts/teeth-runtime.py`).
15. `@decided 2026-09-24`: the routers this package is built for and checked on, and the
    only ones the repository names, are the GL.iNet Flint 2 (GL-MT6000) and Brume 2
    (GL-MT2500), two form factors of one job, with Wi-Fi and without. A finding made on
    another box is described by its architecture. Hardware checks run on both and
    record the router's state first, then restore it (gate:
    `scripts/gate-named-routers.sh`, teeth: `scripts/teeth-named-routers.sh`, both in
    CI's `scenarios` job; the restore is not enforced).
    `@decided 2026-10-04`: the Beryl AX (GL-MT3000) is a third test router, for the case of
    512 MB of memory and about 200 MB of free flash, where Hermes runs from a USB stick; it may be
    named and drawn. The lab's other box stays unnamed (gate: the same, `OTHERS` in
    `scripts/gate-named-routers.sh`).
16. `@decided 2026-09-25`: more than one provider on one router, working at the same time.
    Each UCI `provider` section (base_url, key_file, model, label) becomes an entry in
    upstream's `providers` map whose key_env is `HERMES_PROVIDER_<NAME>_KEY`; the wrapper
    reads the key file at every exec, a missing key drops only that provider, procd holds
    paths only, and the preflight guards those keys like the main one. A name upstream
    already gives a built-in provider is refused, and so is a bad section anywhere in the
    list; the operator's own entries are never touched. Every chat starts on the main
    model and /model switches that chat only. The main model itself is the `uci` entry
    of `providers` (key_env OPENAI_API_KEY), not upstream's bare `custom`, so a model
    picked with /model's buttons or typed keeps the main key on every endpoint,
    openrouter.ai included; `uci` is refused as a section name, and an operator entry
    by that name refuses the start. `openai-api` is kept out of /model, because
    OPENAI_API_KEY holds the main key for whatever endpoint UCI names. The `anthropic`
    extra ships, since /model picks upstream's native transport for api.anthropic.com. A
    ChatGPT subscription signs in with `hermes-login chatgpt`, into the service's data
    directory, and out with `--logout`; the Providers page manages all of it (gate:
    `scripts/gate-runtime.sh`, `scripts/teeth-runtime.py`, `scripts/gate-luci.sh`).
17. `@decided 2026-09-25`: the package carries upstream Hermes 0.21.5, from a pinned tag of
    the upstream repository, since PyPI stops at 0.19.0; and the router package leaves out
    NVIDIA's Relay runtime (nemo-relay, upstream falls back to a no-op host) and the
    HEIC/AVIF decoder (pillow-heif). `@measured` 2026-09-25 by the aarch64 25.12 build:
    together 49 MB of an unpacked 278 MB; the package left at 71 MB, against 57 for 0.19.0.
    `package/upstream/upstream.env` pins the version, tag, commit and the checksum of the
    commit's archive, and names what is left out; `fetch.sh` refuses an archive with
    another checksum. Upstream refuses to build a wheel outside its Nix derivation, so
    `resolve.py` builds it as that derivation does (`HERMES_NIX_BUILD=1`), constrains every
    library to upstream's `uv.lock` at that commit, and walks the dependency graph without
    entering an excluded name; an exclusion upstream no longer resolves stops the build.
    The Telegram delta is computed through the same resolution. Skills, optional skills,
    locales and the MCP catalogue ship under `/usr/share/hermes-agent` and are found
    through upstream's `HERMES_BUNDLED_*` variables, set in `/usr/lib/hermes-agent/hermes-env`
    for the launcher and `hermes-login`; `HERMES_MANAGED` is deliberately not set, since
    upstream then blocks its own config writes. The package records its upstream in
    `/usr/lib/hermes-agent/upstream` (gate: `scripts/gate-upstream.sh`, teeth:
    `scripts/teeth-upstream.sh`).

18. `@decided 2026-10-01`: in the owner profile the agent reads the router freely and
    changes it only through openwrt-mcp, which runs as root and decides. The package pairs
    one openwrt-mcp client per agent, `hermes-main`, into a root-only token file, and writes
    that client's policies into `/etc/config/openwrt-mcp`, in sections named
    `hermes_main_*` and no others, at every start: one read policy per tool, ubus methods
    by name and never a whole object, `uci_get` on system, dhcp, firewall and the default
    network sections, `logread`; and last, because openwrt-mcp takes the first policy that
    covers a call, one change policy (`ubus_call`, `uci_apply`, `uci_confirm`) that asks the factor in
    `hermes.security` for everything it grants. `exec` is never granted, and neither is
    `wg_new_client`, whose answer is a private key that would reach the model provider
    (gate: `scripts/gate-unlock.sh` `check_change_policy_hands_out_no_private_key`).
    `@claude` 2026-10-01: an open unlock window is root for its length, since `ubus_call` on
    everything reaches rpcd's `file` object and `uci_apply` a firewall include; the unlock
    guards the time outside the window, and docs/security.md says so. With factor `none`, the default, no change policy is written,
    so nothing can change the router until the owner sets a factor, and the agent says so.
    The model is never offered `mfa_unlock` or `mfa_lock` (`tools.exclude` in the
    package-written `mcp_servers.openwrt` entry, in every profile), and is told to ask the
    owner for /unlock in the private chat and never to ask for a PIN or a code in a message.
    Unlocking is per agent: `hermes-<name>` has its own token and its own window.
    An unconfirmed change is undone from a snapshot under `/etc/openwrt-mcp`, not `/tmp`,
    so a reboot does not keep it. `@claude` 2026-10-01: wireless is not readable, and neither
    is the whole of network, since a router running WireGuard keeps its private key in a
    network section and a read goes to the model provider; the first design listed network
    whole, and `MCP_READ_UCI` in the init is the one line that says otherwise. Read answers
    (state, addresses, hosts, the log) are sent to the model provider; that is what reading
    means. This stage proves reads, refusals, the factor's configuration, per-agent unlock
    and the rollback.
    `@decided 2026-10-01` (the owner's, paraphrased): unlocking happens in the same Telegram
    chat as the agent; the message that unlocks is removed from the chat at once and never
    reaches the model; the factor is the owner's choice (PIN, app code, or both); five wrong
    tries lock unlocking for fifteen minutes; the window is fifteen minutes; a PIN is 4 to 8
    digits. `@claude` 2026-10-02, how it is built (the Hermes side, 0.21.5-r4, and r5 below): the owner
    sends /unlock and /lock, or a bare PIN, a bare code, or a PIN and a code, whichever the
    factor in `hermes.security` asks for. The plugin `openwrt-unlock` takes it: it ships in the package's own site-packages with an entry
    point (root's files, which the agent cannot rewrite), the bridge enables it in the
    owner profile only and takes it out of `plugins.disabled`, and it is stdlib Python.
    The message is deleted from the chat first, then openwrt-mcp is asked with the token
    the gateway already holds, and the owner is told only the outcome. Whatever fails on
    that path drops the message: upstream lets a message proceed when a hook raises, so
    nothing on it raises. Only an id in `TELEGRAM_ALLOWED_USERS` may try (allow_all and
    pairing do not count), anyone else is dropped without a check, a count or an answer; a
    group gets an answer and no unlock; a message that does not fit the factor is held
    back and not counted. Four lines, each tested alone: a Telegram-native handler placed
    before the adapter's own, so busy or not the adapter never sees the message; the
    `pre_gateway_dispatch` hook; an `llm_request` middleware that removes any line that is
    a PIN, a code or an /unlock from every user message in every request to the model; and
    redaction patterns plus the Telegram library's own DEBUG logger held at INFO, because
    that library prints each update, text included, before any handler. `@claude`
    2026-10-02, limits named and not fixed: a PIN alone on a line of a longer message is
    removed from the request but stays in the chat and in the conversation database;
    the redaction patterns leave the last four digits of a code that followed a PIN in a
    log line (a pattern cannot match more than 17 characters without leaving ten of them
    visible, and what follows a PIN has no literal start to match); a line of 4 to 8
    digits in what the owner types is removed from the request when a factor is set,
    which includes a pasted number. A change a scheduled job asks for is refused by a
    `pre_tool_call` hook even while a window is open (upstream marks a cron run in the
    `HERMES_CRON_SESSION` context variable and in its session and task ids). A job that
    delegates to a subagent is refused too, measured for synchronous delegation only:
    `@measured` 2026-10-04 on a Brume 2, 0.21.5-r5, by `uci add_list hermes.main.toolsets=delegation`,
    a window opened with the owner PIN through openwrt-mcp's `mfa_unlock`, then (as `hermes`)
    `hermes cron create 1m "<delegate a uci_apply of system.@system[0].description to a
    subagent>" --repeat 1 --deliver local`; the gateway ran it once, delegate_task ran the
    batch synchronously, the subagent's `mcp__openwrt__uci_apply` got "a scheduled job cannot
    change the router", and openwrt-mcp's audit log shows no apply after the unlock (record:
    the private execution journal, evidence hermes-openwrt-2026-10-04-hw). Not gated:
    no container check covers the subagent path, and async delegation is not measured. `@claude` 2026-10-02, 0.21.5-r5: the agent is told
    the window is open, because the unlock message is never shown to it and an agent that had
    asked for /unlock went on asking after it was given (seen on a Brume 2 through Telegram).
    The plugin remembers the end of a window from the daemon's own answer, and through
    upstream's `pre_llm_call` hook adds one line to the owner's next message while it is open,
    saying the owner has unlocked changes until that time and that a waiting change should be done
    now: nothing about the PIN or a code, which the plugin never keeps. A lock, a lockout or the
    end of the window ends it, and the line is removed from the earlier turns a request replays,
    since upstream replays each user message with what was injected into it (`llm_request` drops
    any such line that no longer names the window open now); a scheduled job is not told. It knows
    only windows it saw open: one opened elsewhere, or still open when the gateway restarted,
    is not announced, and the agent finds out from a refusal as before (gate:
    `scripts/gate-unlock.sh`, the eighteen Hermes-side checks, `scripts/unlock-harness.py`,
    among them `check_agent_told_window_is_open` and `check_agent_not_told_after_window_ends`;
    teeth: `scripts/teeth-unlock.sh`).
    `@decided 2026-10-01` (the owner's, paraphrased): setup happens once, in LuCI with a QR code
    to scan or over SSH with the QR code in the terminal; the first code from the app must be
    entered before the factor is switched on; the PIN field is write-only. `@claude` 2026-10-02,
    how that is built, the last stage (LuCI r13, hermes-agent unchanged at 0.21.5-r4, whose shipped config file shows the same two steps since r5):
    the owner sets a factor in LuCI, Services -> Hermes Agent -> Security, or over SSH with
    `openwrt-mcp pin set hermes-main` and `openwrt-mcp mfa enrol hermes-main --pending --qr`
    then `openwrt-mcp mfa activate hermes-main <code>`, which prints the QR in the terminal.
    A phone is added in two steps: `--pending` keeps the new secret apart, and it takes the
    place of the one in force only when a current code of its own proves the scan worked, so
    nothing is in force before the first code is entered and a second start of the enrolment
    leaves the first phone in force. The QR is returned once, to the call that asked, and no
    call returns it again (invariant 11). What unlocks is the owner's choice and each factor is
    optional, so the page offers a factor only when what it needs exists (gate:
    `scripts/gate-unlock.sh` `check_luci_enrol_shows_qr_and_verifies`, `check_cli_enrol_prints_qr`,
    `check_luci_pin_write_only`, against the installed luci-app-hermes and the real daemon, with a
    QR decoder in `scripts/qr_decode.py` that checks every block's Reed-Solomon syndromes;
    teeth: `scripts/teeth-unlock.sh`, `scripts/teeth-luci.sh`). `@claude` 2026-10-02, limits
    named and not fixed: the six-digit code typed to activate a phone is an argument of the
    `openwrt-mcp mfa activate` the backend runs, readable in /proc for that moment and spent
    when it works; LuCI over plain HTTP carries the PIN and the QR unencrypted (the page says
    so); an activation attempt is not counted by openwrt-mcp; the page needs the agent to
    have been started once in the owner profile, since that is what pairs hermes-main; the
    unlock window that is open cannot be shown, because openwrt-mcp keeps it in memory and a
    separate process cannot see it.
19. `@claude` 2026-10-02: every file in every package is root's, whoever ran the build.
    `apk mkpkg` records each file's owner as found on disk, with no option to override it, and
    a Linux CI runner's uid 1001 became `nobody` on the router, /etc/hermes-agent and its key
    files included; a Mac never shows it, because Docker Desktop presents a bind mount as root.
    So every mkpkg call goes through `scripts/mkpkg-root.sh`, which packages the tree as root's
    and hands it back after (gate: `scripts/gate-apk-owner.sh`, reading the built packages,
    in CI; teeth: `scripts/teeth-apk-owner.sh`, a uid 1001 tree built in the container's own
    filesystem). Also caught by gate-unlock `check_key_files_root_only` once it ran in CI.

20. `@claude` 2026-10-04: a newer upstream Hermes is noticed without anyone looking. A daily
    workflow (`.github/workflows/upstream-watch.yml`, job permissions `contents: read` and
    `issues: write` only) runs `scripts/upstream-watch.sh`, which compares the tag
    `package/upstream/upstream.env` pins with upstream's latest release by version order and
    opens one issue for a newer one, never a second for the same release, open or closed, matched
    on the release alone since the pin named in an older title may have moved. It fails instead of
    passing when it cannot read upstream or this repository's issues, or when a tag is not in the
    vYEAR.MONTH.DAY form it can order. It never moves the pin: a new upstream is built, gated and
    run on both routers first. Not enforced: GitHub stops a scheduled workflow after 60 days
    without activity in the repository, and it then runs only by hand (gate:
    `scripts/gate-upstream-watch.sh` against a stand-in `gh`, bound to
    `features/upstream-watch.feature`, in CI's `scenarios` job and before each daily run;
    teeth: `scripts/teeth-upstream-watch.sh`).

21. `@decided 2026-10-04`: Hermes installs to the router's own storage by default, and a USB stick
    is an option that one command sets up. `@claude` 2026-10-04, how: `hermes-usb move <partition>
    [--format]` moves the data directory (what is written again and again; the programs are written
    once) to an ext4 partition of a USB disk with nothing on that disk mounted. The one record that
    the data is on a stick is the fstab section `hermes_data`, written in one commit once the stick
    is mounted and checked, removed in one commit once the data is back inside; a section that
    exists means "on a stick", so one disabled or without a UUID is refused, never read as "inside".
    One check, `/usr/lib/hermes-agent/hermes-usb-check`, reads it, the top mount on the data
    directory from `/proc/self/mountinfo`, hermes-usb's lock (with its pid) and the copies an
    interrupted run leaves under fixed names; the init, the gateway wrapper procd respawns, the
    `hermes` launcher run as root when `HERMES_HOME` is the stick's directory, hermes-login and
    `/etc/hotplug.d/block/90-hermes-usb` all ask it: without the stick nothing of Hermes starts or
    writes inside; the stick's own arrival starts an enabled service, its departure stops it, other
    devices change nothing. Before copying, hermes-usb waits for the gateway's process (read from
    upstream's JSON pid record) and for the service's group to hold no process (read, not sized); it
    switches only when every file's checksum and the file count match; it never moves into a
    directory that exists, sets the inside copy aside until the stick is mounted and checked, and
    puts everything back when a step fails. Every commit of the record is read back from
    `/etc/config/fstab` itself, not through uci's view of fstab, which includes changes waiting in
    `/tmp/.uci`: `@measured` 2026-10-04 in `openwrt/rootfs:aarch64_generic-25.12.4`, a `uci commit
    fstab` onto a full tmpfs bound over `/etc/config` returned 0 and left the file 0 bytes. So it
    needs 256 KiB free there first, refuses while someone else's fstab changes wait uncommitted
    (checked again after the copy, which can take minutes), commits only with a copy of the file
    in RAM, and reads the result with uci itself (a copy under another package name, so the
    changes waiting for fstab in `/tmp/.uci` play no part, and refused while a change waits there
    under the copy's own name): a commit that did not land, the record not as asked, any other section changed,
    or a file uci cannot parse, a file cut off inside a value included, or left empty where it held
    more than the record, is undone
    (the change reverted, the file put back from that copy by a rename) before switching anything;
    `back` whose record removal does not land says so and leaves Hermes refusing to start inside;
    when the file could not be put back either, each command says so and names the copy it kept
    in `/tmp`, under a name of its own. It refuses to move a directory another process has a file or
    its working directory or root in (a path with spaces and a file deleted while open included),
    and a root shell's `hermes` asks for the data directory however
    its path is spelled, so hermes-usb's lock binds it too. It refuses, changing nothing, a device not on USB, a
    whole disk, a disk with a partition mounted, a data directory that is a mount point, reached
    through a symbolic link, on another filesystem, named in the fstab or in a system tree, a stick
    too small (before `--format` erases it), another filesystem unless `--format` (every inode table
    written at once, no blocks reserved for root), and a router without the USB packages (it prints
    the `apk add` line). `back` takes the data only from its own stick, keeps what lay underneath
    the mount point, and removes the fstab section last; `forget --yes` gives up a stick that is not
    mounted (partly gated: `scripts/gate-usb.sh`, bound to `features/usb.feature`, teeth
    `scripts/teeth-usb.sh`; not gated: a disk held by another device and a partition in use as
    swap, which a loop device cannot show, the moment of a power cut itself, INT and TERM, and
    hermes-login's own wait for the sign-in, during which the stick is not asked again, and a
    command the user `hermes` runs by hand, since that user cannot read a device's UUID; in the root
    profile the gateway, running as root, writes under the empty mount point in the seconds
    between the stick going and the stop; two hermes-usb runs started at the same moment over a
    stale lock; a process that opens the data directory after the check and before the switch, or
    maps a file in it without keeping it open; a process whose root directory is in it, which is
    looked for and not gated; a power cut while the file is put back; another `uci commit fstab`,
    from LuCI or a shell, landing in the moment between the copy and the read-back, which is then
    taken for a failed commit and put back over; a deletion of the record staged in uci and not
    committed, which the start check reads as done).

22. `@decided 2026-10-05`: the README keeps the install steps, for a person and an agent alike,
    and shows the measured runs as figures and tables; the long explanations live under `docs/`,
    and `docs/agent-install.md` is the install written for an agent, as checks and the output
    each must give. `@claude` 2026-10-05, how it stays true: the README's own figures
    (`docs/rerun.svg`, `docs/install-flow.svg`, `docs/unlock.svg`) are drawn by
    `scripts/figures.py` from `docs/measurements/figures.json` and committed as drawn, and every
    picture, relative link and #anchor in README.md, CONTRIBUTING.md, SECURITY.md and docs/*.md
    resolves (gate: `scripts/gate-figures.sh`, bound to `features/docs.feature`, in CI's
    `scenarios` job; teeth: `scripts/teeth-figures.sh`; not gated: the older hand-drawn SVGs,
    whose numbers are not read from the data file, and the commands in docs/agent-install.md,
    which no check runs).

Run builds before gates. `gate-runtime.sh` uses a disposable privileged container with
its own cgroup namespace and read-only host mounts; never use host cgroup namespace.
It makes no model API call. Test credentials are synthetic. Host tools are not installed.
