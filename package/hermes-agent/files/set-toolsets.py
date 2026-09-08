#!/usr/bin/env python3
"""Write the router's toolset choice into Hermes' own config.yaml.

Why this exists rather than a command-line flag
-----------------------------------------------
The init script used to pass `--toolsets a,b,c` to `hermes gateway run`. That flag does
not exist on the gateway subcommand, so the service died at argument parsing on every
start, with the shipped default configuration, on every router. It was invisible to the
gates because they ran `hermes gateway run` themselves with an environment and no
arguments, and visible on the LuCI overview page the moment somebody looked at the log.

`--toolsets` DOES exist as a global option, and putting it before the subcommand parses
cleanly. That is worse, not better: its own help says it applies to `-z/--oneshot` and
`--tui`, so the gateway would ignore it and the setting would appear to work.

What the gateway actually reads is the `toolsets` key of $HERMES_HOME/config.yaml.

Merging, not writing
--------------------
This file belongs to Hermes and holds whatever the agent has learned about itself. Only
the one key the router owns is touched; everything else is read, kept, and written back.
An unreadable or corrupt file is left alone and reported, because replacing it would
destroy state the router cannot regenerate.
"""
from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: set-toolsets.py <hermes-home> <comma,separated,toolsets>\n")
        return 2
    home, raw = Path(sys.argv[1]), sys.argv[2]

    wanted = [t.strip() for t in raw.split(",") if t.strip()]
    if not wanted:
        return 0

    try:
        import yaml
    except ImportError:
        sys.stderr.write("set-toolsets: no yaml module, leaving config.yaml alone\n")
        return 0

    path = home / "config.yaml"
    config: dict = {}
    if path.exists():
        try:
            loaded = yaml.safe_load(path.read_text()) or {}
        except Exception as exc:
            sys.stderr.write(f"set-toolsets: {path} will not parse ({exc}); leaving it alone\n")
            return 0
        if not isinstance(loaded, dict):
            sys.stderr.write(f"set-toolsets: {path} is not a mapping; leaving it alone\n")
            return 0
        config = loaded

    if config.get("toolsets") == wanted:
        return 0

    config["toolsets"] = wanted
    home.mkdir(parents=True, exist_ok=True)
    # Written beside the target and renamed, so a power cut during the write cannot
    # leave a router with a half-written config it will refuse to parse at next boot.
    tmp = path.with_suffix(".yaml.tmp")
    tmp.write_text(yaml.safe_dump(config, default_flow_style=False, sort_keys=False))
    tmp.replace(path)
    sys.stderr.write(f"set-toolsets: toolsets = {', '.join(wanted)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
