#!/usr/bin/env python3
"""Merge UCI gateway defaults and the package-owned MCP connection into Hermes.

@codex 2026-09-19: platform_toolsets is the shipped gateway's actual contract.
This selects defaults, not an OS sandbox; explicit cron-job overrides and
operator-configured plugins/MCP servers retain their upstream semantics.

@decided 2026-09-24: two profiles; assistant turns off terminal, code execution and
file tools and applies wherever no profile is set, existing routers included; admin
keeps every selected tool, as root.

How, and why these three: an optional profile argument governs agent.disabled_toolsets,
which model_tools._compute_tool_definitions always subtracts after enabled_toolsets
is resolved (upstream #17309), which hermes_cli.tools_config._get_platform_tools
also subtracts last from the per-platform list above, and which cron/scheduler.py
layers over per-job overrides (#25752); delegated sub-agents inherit it. file goes
with the other two because the file tool's own sensitive-path guard does not cover
/usr/lib/hermes-agent and could otherwise rewrite the agent's own code to lift the
restriction. Entries outside those three are the operator's and are left alone
either way. Omitting the argument leaves agent.disabled_toolsets untouched.
"""
from __future__ import annotations

import copy
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

# The three toolsets a non-root "assistant" profile must never receive. Fixed
# order: this is the order missing names are appended in, so the file is
# deterministic to read and to test.
GOVERNED = ("code_execution", "file", "terminal")


def _validate_endpoint(value: str, label: str) -> None:
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value)):
        raise ValueError(f"{label} must be HTTP(S), without embedded credentials")
    # Also validate the port rather than persisting an unusable endpoint.
    _ = parsed.port


def main() -> int:
    if len(sys.argv) not in (3, 4, 6, 7):
        sys.stderr.write(
            "usage: set-toolsets.py <home> <comma,separated,tools> [mcp-url [base-url model [profile]]]\n")
        return 2
    home, raw = Path(sys.argv[1]), sys.argv[2]
    # profile only ever follows the full mcp-url/base-url/model form: both real
    # callers (the init and the exec wrapper) always pass all five before it, so
    # there is no shorter form in which a 4th or 5th argument could be mistaken
    # for a profile. Omitted entirely, agent.disabled_toolsets is left untouched,
    # which keeps every existing caller (and test) that predates profiles unchanged.
    profile = sys.argv[6] if len(sys.argv) == 7 else None
    if profile is not None and profile not in ("assistant", "admin"):
        sys.stderr.write(f"hermes-config: profile must be 'assistant' or 'admin', not {profile!r}\n")
        return 2
    try:
        import yaml
        from toolsets import TOOLSETS, validate_toolset

        wanted = list(dict.fromkeys(t.strip() for t in raw.split(",") if t.strip()))
        if any(not validate_toolset(t) and t != "no_mcp" for t in wanted):
            raise ValueError("unknown toolset; check the configured tool names")
        path = home / "config.yaml"
        config = yaml.safe_load(path.read_text(encoding="utf-8")) if path.exists() else {}
        if config is None:
            config = {}
        if not isinstance(config, dict):
            raise TypeError("config.yaml must be a mapping")
        # Compared against at the end, by data rather than by rendered text, so a
        # human-added comment or a hand-typed quoting style is never destroyed by a
        # run that would not otherwise have changed anything.
        original = copy.deepcopy(config)
        platforms = config.setdefault("platform_toolsets", {})
        if not isinstance(platforms, dict):
            raise TypeError("platform_toolsets must be a mapping")
        known = config.get("known_plugin_toolsets") or {}
        if not isinstance(known, dict):
            raise TypeError("known_plugin_toolsets must be a mapping")
        for platform in ("telegram", "cron"):
            previous = platforms.get(platform, [])
            plugins = known.get(platform, []) or []
            if not isinstance(previous, list) or not isinstance(plugins, list):
                raise TypeError("platform selections must be lists")
            # Preserve explicit plugin/custom/MCP selections, including no_mcp.
            # Known-but-absent plugins stay disabled in upstream's resolver.
            extras = [name for name in previous if isinstance(name, str)
                      and (name not in TOOLSETS or name in plugins)]
            platforms[platform] = list(dict.fromkeys(wanted + extras))

        if len(sys.argv) >= 4:
            url = sys.argv[3]
            owned = config.get("_openwrt_mcp_managed") is True
            if url:
                _validate_endpoint(url, "MCP URL")
                servers = config.setdefault("mcp_servers", {})
                if not isinstance(servers, dict):
                    raise TypeError("mcp_servers must be a mapping")
                expected = {"url": url, "headers": {"Authorization": "Bearer ${OPENWRT_MCP_TOKEN}"}}
                # An operator may already have pasted in exactly this entry by hand,
                # e.g. from an earlier manual setup. Adopt it rather than refuse: only
                # a DIFFERENT entry is a real collision.
                if "openwrt" in servers and not owned and servers["openwrt"] != expected:
                    raise ValueError("mcp_servers.openwrt is operator-owned; rename it before enabling UCI MCP")
                servers["openwrt"] = expected
                config["_openwrt_mcp_managed"] = True
            elif owned:
                # Read-only here: an absent mcp_servers must not be created just to
                # immediately find there is nothing in it to remove.
                servers = config.get("mcp_servers")
                if isinstance(servers, dict):
                    servers.pop("openwrt", None)
                config.pop("_openwrt_mcp_managed", None)

        if len(sys.argv) in (6, 7):
            endpoint, model = sys.argv[4:6]
            _validate_endpoint(endpoint, "model endpoint")
            if not model.strip() or any(ord(c) < 32 for c in model):
                raise ValueError("model name is empty or contains control characters")
            model_config = config.get("model") or {}
            if isinstance(model_config, str):
                model_config = {"default": model_config}
            if not isinstance(model_config, dict):
                raise TypeError("model must be a mapping or model name")
            if model_config.get("api_key") not in (None, "", "${OPENAI_API_KEY}"):
                raise ValueError("model.api_key is operator-owned; move it before enabling the UCI model")
            model_config.update(default=model, provider="custom", base_url=endpoint,
                                api_mode="chat_completions", api_key="${OPENAI_API_KEY}")
            config["model"] = model_config

        # Profiles govern agent.disabled_toolsets, never platform_toolsets above:
        # see the module docstring for why (upstream subtracts it as a final,
        # always-applied step, so it holds regardless of what toolsets says).
        if profile == "assistant":
            # A key left with no value is null in YAML, and upstream reads null as
            # empty for both (`... or {}`, `... or []`), so this does too.
            if config.get("agent") is None:
                config["agent"] = {}
            agent_cfg = config["agent"]
            if not isinstance(agent_cfg, dict):
                raise ValueError("agent must be a mapping")
            disabled = agent_cfg.get("disabled_toolsets")
            if disabled is None:
                disabled = []
            if not isinstance(disabled, list) or not all(isinstance(t, str) for t in disabled):
                raise ValueError("agent.disabled_toolsets must be a list of strings")
            disabled = list(disabled)
            for name in GOVERNED:
                if name not in disabled:
                    disabled.append(name)
            agent_cfg["disabled_toolsets"] = disabled
        elif profile == "admin":
            agent_cfg = config.get("agent")
            if agent_cfg is not None:
                if not isinstance(agent_cfg, dict):
                    raise ValueError("agent must be a mapping")
                disabled = agent_cfg.get("disabled_toolsets")
                if disabled is not None:
                    if not isinstance(disabled, list) or not all(isinstance(t, str) for t in disabled):
                        raise ValueError("agent.disabled_toolsets must be a list of strings")
                    kept = [name for name in disabled if name not in GOVERNED]
                    if kept:
                        agent_cfg["disabled_toolsets"] = kept
                    else:
                        # Consistent with the rest of this file: never leave a key
                        # behind that now holds nothing (see _openwrt_mcp_managed).
                        agent_cfg.pop("disabled_toolsets", None)

        if path.exists() and config == original:
            return 0
        home.mkdir(parents=True, exist_ok=True)
        rendered = yaml.safe_dump(config, default_flow_style=False, sort_keys=False, allow_unicode=True)
        # A unique 0600 temporary file avoids following an old .yaml.tmp symlink.
        temp = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=home, prefix=".config-", delete=False,
                                             encoding="utf-8") as stream:
                temp = Path(stream.name)
                stream.write(rendered)
                stream.flush()
                os.fsync(stream.fileno())
            temp.replace(path)
        finally:
            if temp is not None and temp.exists():
                temp.unlink()
    except Exception as exc:  # noqa: BLE001 - fail closed without leaking YAML snippets
        # Do not log YAML exception snippets, which may contain operator secrets.
        message = str(exc) if isinstance(exc, ValueError) else type(exc).__name__
        sys.stderr.write(f"hermes-config: configuration refused ({message}); existing file preserved\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
