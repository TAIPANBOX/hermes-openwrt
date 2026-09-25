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

Both resolutions go through package/upstream/resolve.py, the one the base package is
built with: the same wheel, the same uv.lock versions and the same HERMES_EXCLUDE. A
delta computed any other way would describe a base tree that is not the one on the
router, and would carry nemo-relay back in as "added by Telegram", since Hermes declares
it and only the base build leaves it out.
"""
from __future__ import annotations

import os
import subprocess
import sys

RESOLVE = os.path.join(os.environ.get("UPSTREAM_SRC", "/upstream-src"), "resolve.py")


def run(*args: str) -> str:
    return subprocess.run([sys.executable, RESOLVE, *args], check=True,
                          capture_output=False, stdout=subprocess.PIPE, text=True).stdout


def resolve(workdir: str, extras: str, *requirements: str) -> dict[str, str]:
    """The set the package build would install, as {canonical name: version}."""
    out = {}
    for line in run("closure", workdir, extras, *requirements).split():
        name, version = line.split("==", 1)
        out[name.lower().replace("_", "-")] = version
    return out


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: delta.py <upstream-workdir> <extras>")
    workdir, extras = sys.argv[1], sys.argv[2]

    pin = run("pin", workdir, "python-telegram-bot", "messaging").strip()
    print(f"delta.py: upstream pins {pin}", file=sys.stderr)

    base = resolve(workdir, extras)
    full = resolve(workdir, extras, pin)

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
