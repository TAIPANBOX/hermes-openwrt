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

1. Packages install, run, preserve configuration and remove cleanly on OpenWrt 25.12
   (gate: `scripts/gate-package.sh`).
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
   stay root-only (gate: `scripts/gate-unlock.sh` `check_gateway_runs_as_hermes_user`,
   `check_key_files_root_only`, `check_memory_ceiling_non_root`,
   `check_upgrade_hands_data_dir_to_hermes`, and `scripts/gate-package.sh`
   `check_clean_removal`; teeth: `scripts/teeth-unlock.sh`, `scripts/teeth-runtime.py`; the
   environment limit is not enforced).
8. UCI selects the primary model, OpenAI-compatible endpoint and file-backed key, and
   the wrapper re-applies them before every exec, so upstream state such as a model saved
   from a chat cannot outlive a restart. The actual upstream resolver must then agree;
   conflicting dotenv/provider/pool/header settings refuse startup and preserve operator
   credentials. Explicit job/channel overrides and fallback chains retain upstream
   semantics (gate: `scripts/gate-runtime.sh`).
9. Runtime, LuCI and unlock scenarios bind both ways to the checks that run them, and
   product mutations must turn their named test red with green restored and empty
   discovery refused (gate: `scripts/gate-scenarios-bound.sh`, `scripts/teeth-runtime.py`,
   `scripts/teeth-luci.sh`, `scripts/teeth-unlock.sh`).
10. procd respawn is bounded (`3600 5 5`): a gateway that keeps failing at start is
    retried at most five times within an hour, then left stopped, instead of being
    restarted every five seconds (gate: `scripts/gate-runtime.sh`).
11. LuCI: the read permission is exactly `hermes` status and logs plus the `hermes` UCI
    config, with no other ubus object or method (procd's service list included), no file
    access and no other scope; `set_secret` writes only its fixed slot under
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
    dropped at the next one, so "Saved" is never shown twice (gate: `scripts/gate-luci.sh`,
    `scripts/teeth-luci.sh`, `scripts/test-luci-views.mjs`).
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
    nice 10 (README, "Under the router's own work") (gate: `scripts/gate-runtime.sh`,
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
    guards the time outside the window, and the README says so. With factor `none`, the default, no change policy is written,
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
    digits. `@claude` 2026-10-02, how it is built (the Hermes side, 0.21.5-r4): the owner
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
    `HERMES_CRON_SESSION` context variable and in its session and task ids); a job that
    delegates to a subagent is not proven (gate: `scripts/gate-unlock.sh`, the fifteen
    Hermes-side checks, `scripts/unlock-harness.py`; teeth: `scripts/teeth-unlock.sh`).
    The LuCI Security page and the SSH enrolment are not built, and
    `scripts/gate-unlock.sh` lists their three scenarios as NOT IMPLEMENTED and fails
    until they are (gate: `scripts/gate-unlock.sh`, red by design until then; teeth:
    `scripts/teeth-unlock.sh`, `scripts/gate-runtime.sh`, `scripts/teeth-runtime.py`).

Run builds before gates. `gate-runtime.sh` uses a disposable privileged container with
its own cgroup namespace and read-only host mounts; never use host cgroup namespace.
It makes no model API call. Test credentials are synthetic. Host tools are not installed.
