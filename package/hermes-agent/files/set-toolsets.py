#!/usr/bin/env python3
"""Merge UCI gateway defaults and the package-owned MCP connection into Hermes.

@codex 2026-09-19: platform_toolsets is the shipped gateway's actual contract.
This selects defaults, not an OS sandbox; explicit cron-job overrides and
operator-configured plugins/MCP servers retain their upstream semantics.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit


def main() -> int:
    if len(sys.argv) not in (3, 4):
        sys.stderr.write("usage: set-toolsets.py <home> <comma,separated,tools> [mcp-url]\n")
        return 2
    home, raw = Path(sys.argv[1]), sys.argv[2]
    try:
        import yaml
        from toolsets import TOOLSETS, validate_toolset

        wanted = list(dict.fromkeys(t.strip() for t in raw.split(",") if t.strip()))
        if any(not validate_toolset(t) and t != "no_mcp" for t in wanted):
            raise ValueError("unknown toolset; check the configured tool names")
        path = home / "config.yaml"
        config = yaml.safe_load(path.read_text()) if path.exists() else {}
        if config is None:
            config = {}
        if not isinstance(config, dict):
            raise TypeError("config.yaml must be a mapping")
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

        if len(sys.argv) == 4:
            url = sys.argv[3]
            servers = config.setdefault("mcp_servers", {})
            if not isinstance(servers, dict):
                raise TypeError("mcp_servers must be a mapping")
            owned = config.get("_openwrt_mcp_managed") is True
            if url:
                parsed = urlsplit(url)
                if (parsed.scheme not in ("http", "https") or not parsed.hostname
                        or parsed.username is not None or parsed.password is not None
                        or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in url)):
                    raise ValueError("MCP URL must be HTTP(S), without embedded credentials")
                # Also validate the port rather than persisting an unusable endpoint.
                _ = parsed.port
                if "openwrt" in servers and not owned:
                    raise ValueError("mcp_servers.openwrt is operator-owned; rename it before enabling UCI MCP")
                servers["openwrt"] = {
                    "url": url,
                    "headers": {"Authorization": "Bearer ${OPENWRT_MCP_TOKEN}"},
                }
                config["_openwrt_mcp_managed"] = True
            elif owned:
                servers.pop("openwrt", None)
                config.pop("_openwrt_mcp_managed", None)

        rendered = yaml.safe_dump(config, default_flow_style=False, sort_keys=False)
        if path.exists() and path.read_text() == rendered:
            return 0
        home.mkdir(parents=True, exist_ok=True)
        # A unique 0600 temporary file avoids following an old .yaml.tmp symlink.
        temp = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=home, prefix=".config-", delete=False) as stream:
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
