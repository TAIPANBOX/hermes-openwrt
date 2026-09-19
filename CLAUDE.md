# Hermes OpenWrt invariants

@codex 2026-09-19: packaging and runtime contract; the upstream Python payload is unmodified.

1. Packages install, run, preserve configuration and remove cleanly on each supported
   release/architecture (gate: `scripts/gate-package.sh`, `scripts/gate-ipk.sh`).
2. Telegram is optional, disjoint from the base payload, and refuses unusable setup
   (gate: `scripts/gate-telegram.sh`, `scripts/gate-telegram-opkg.sh`).
3. All provider, Telegram and MCP credentials are read by the exec wrapper on every
   launch and respawn. procd stores paths only (gate: `scripts/gate-runtime.sh`).
4. UCI tool selection writes the upstream Telegram and cron platform defaults,
   including an empty selection. Invalid YAML or tool names refuse startup and
   preserve the existing file (gate: `scripts/gate-runtime.sh`). This is not a global
   authorization allowlist: upstream job overrides, plugins and MCP still apply.
5. The optional MCP connection reaches the upstream loader with a token placeholder,
   preserves unrelated entries, refuses ownership collisions and is removed when
   disabled (gate: `scripts/gate-runtime.sh`). MCP policy governs MCP calls only.
6. A nonzero memory limit is applied and read back before every gateway exec, only in
   the dedicated procd cgroup. Missing cgroup v2 memory delegation refuses startup.
   Zero explicitly disables the ceiling (gate: `scripts/gate-runtime.sh`, kernel OOM).
7. The service and its file/terminal tools run as root. This is documented at setup;
   neither tool defaults nor MCP nor memory controls are an OS security sandbox
   (partly gated: runtime selection tests; wording reviewed manually).
8. New runtime scenarios bind both ways to discovered test methods, and product
   mutations must turn their named test red with green restored and empty discovery
   refused (gate: `scripts/gate-scenarios-bound.sh`, `scripts/teeth-runtime.py`).

Run builds before gates. `gate-runtime.sh` uses a disposable privileged container with
its own cgroup namespace and read-only host mounts; never use host cgroup namespace.
It makes no model API call. Test credentials are synthetic. Host tools are not installed.
