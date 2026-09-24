# Hermes OpenWrt invariants

`@claude` 2026-09-24: first written by Codex on 2026-09-19, amended on 2026-09-24. Each
invariant names what holds it. The upstream Python payload is installed unpatched; the
package adds one shim (`webbrowser.py`) and its own helpers under `/usr/libexec`.

`@decided 2026-09-24`: the router's own configuration (UCI) is the authority for the
primary model, its endpoint and the tool selection at every start, including restarts
procd makes on its own. A model switched from a chat lasts until the next start.

`@decided 2026-09-24`: the package is for ARM routers. x86_64 is no longer built in CI,
gated or published; the build scripts still take `ARCH=x86_64` by hand.

1. Packages install, run, preserve configuration and remove cleanly on each supported
   release/architecture (gate: `scripts/gate-package.sh`, `scripts/gate-ipk.sh`). On
   24.10 `ripgrep` is not declared: `@measured` 2026-09-24 by curl of downloads.openwrt.org,
   the 24.10.8 index lacks it for aarch64_generic and x86_64, and Hermes falls back to
   `grep` (gate: `scripts/gate-ipk.sh`, `check_deps_resolve`).
2. Telegram is optional, disjoint from the base payload, and refuses unusable setup
   (gate: `scripts/gate-telegram.sh`, `scripts/gate-telegram-opkg.sh`).
3. All provider, Telegram and MCP credentials are read by the exec wrapper on every
   launch and respawn; procd stores paths only. A router MCP token missing at exec drops
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
7. The service and its file/terminal tools run as root. This is documented at setup;
   neither tool defaults nor MCP nor memory controls are an OS security sandbox
   (partly gated: runtime selection tests; wording reviewed manually).
8. UCI selects the primary model, OpenAI-compatible endpoint and file-backed key, and
   the wrapper re-applies them before every exec, so upstream state such as a model saved
   from a chat cannot outlive a restart. The actual upstream resolver must then agree;
   conflicting dotenv/provider/pool/header settings refuse startup and preserve operator
   credentials. Explicit job/channel overrides and fallback chains retain upstream
   semantics (gate: `scripts/gate-runtime.sh`).
9. Runtime and LuCI scenarios bind both ways to the checks that run them, and product
   mutations must turn their named test red with green restored and empty discovery
   refused (gate: `scripts/gate-scenarios-bound.sh`, `scripts/teeth-runtime.py`,
   `scripts/teeth-luci.sh`).
10. procd respawn is bounded (`3600 5 5`): a gateway that keeps failing at start is
    retried at most five times within an hour, then left stopped, instead of being
    restarted every five seconds (gate: `scripts/gate-runtime.sh`).
11. LuCI: the read permission is exactly `hermes` status and logs plus the `hermes` UCI
    config, with no other ubus object or method (procd's service list included), no file
    access and no other scope; `set_secret` writes only its fixed slot under
    `/etc/hermes-agent`, refuses when UCI points the service at another file, and reports
    a failed write; no method returns a key (gate: `scripts/gate-luci.sh`,
    `scripts/teeth-luci.sh`).
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

Run builds before gates. `gate-runtime.sh` uses a disposable privileged container with
its own cgroup namespace and read-only host mounts; never use host cgroup namespace.
It makes no model API call. Test credentials are synthetic. Host tools are not installed.
