#!/usr/bin/env python3
"""Work out exactly which distributions the Telegram add-on must ship.

Run inside the target rootfs, where pip resolves against the router's own interpreter
and libc. Prints one `name==version` per line on stdout, and refuses in two cases that
would each produce a package that is broken only once somebody installs both halves.

Refusal 1: a package the base already ships would have to change version.
    Two OpenWrt packages cannot own the same file. If Telegram needs httpx 0.29 while
    hermes-agent ships 0.28, this add-on cannot express that, and the honest outcome is
    to fold Telegram into the base package instead of beside it.

Refusal 2: the delta is empty.
    Then the base already carries Telegram and this package has no reason to exist.

Deliberately not hardcoded: the pin comes from hermes-agent's own metadata, under its
`messaging` extra. Taking that extra whole would also pull Discord with voice (PyNaCl)
and Slack onto a router that was asked for Telegram.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import urllib.request


def upstream_telegram_pin(version: str) -> str:
    """The python-telegram-bot requirement hermes-agent itself declares."""
    url = f"https://pypi.org/pypi/hermes-agent/{version}/json"
    with urllib.request.urlopen(url, timeout=60) as fh:
        meta = json.load(fh)
    for req in meta["info"].get("requires_dist") or []:
        if req.lower().startswith("python-telegram-bot") and re.search(
            r"""extra\s*==\s*['"]messaging['"]""", req
        ):
            return req.split(";")[0].strip()
    raise SystemExit(
        f"delta.py: hermes-agent {version} declares no python-telegram-bot under its "
        f"messaging extra. Upstream has moved it; find where before packaging."
    )


def resolve(*requirements: str) -> dict[str, str]:
    """The full set pip would install, as {canonical name: version}."""
    with tempfile.NamedTemporaryFile(suffix=".json") as report:
        subprocess.run(
            [
                sys.executable, "-m", "pip", "install",
                "--quiet", "--no-cache-dir", "--disable-pip-version-check",
                "--root-user-action=ignore", "--only-binary=:all:",
                "--dry-run", "--report", report.name,
                "--target", tempfile.mkdtemp(),
                *requirements,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        with open(report.name) as fh:
            data = json.load(fh)
    return {
        item["metadata"]["name"].lower().replace("_", "-"): item["metadata"]["version"]
        for item in data["install"]
    }


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: delta.py <hermes-version> <extras>")
    version, extras = sys.argv[1], sys.argv[2]

    pin = upstream_telegram_pin(version)
    print(f"delta.py: upstream pins {pin}", file=sys.stderr)

    profile = f"hermes-agent[{extras}]=={version}"
    base = resolve(profile)
    full = resolve(profile, pin)

    changed = sorted(k for k in set(full) & set(base) if full[k] != base[k])
    if changed:
        print(
            "delta.py: Telegram would change the version of a package hermes-agent\n"
            "delta.py: already ships, which two packages cannot both own:",
            file=sys.stderr,
        )
        for name in changed:
            print(f"delta.py:   {name}: base {base[name]} -> with telegram {full[name]}",
                  file=sys.stderr)
        print("delta.py: fold Telegram into the base package rather than beside it.",
              file=sys.stderr)
        return 1

    added = sorted(set(full) - set(base))
    if not added:
        print("delta.py: the delta is empty; the base package already carries Telegram",
              file=sys.stderr)
        return 1

    print(f"delta.py: {len(base)} in the base, {len(full)} with telegram, "
          f"{len(added)} added", file=sys.stderr)
    for name in added:
        print(f"{name}=={full[name]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
