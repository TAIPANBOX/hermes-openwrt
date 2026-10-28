#!/usr/bin/env python3
"""Turn the pinned upstream archive into the exact set of wheels a router package ships.

Runs INSIDE the target OpenWrt rootfs, for the same reason build.sh does: pip resolves
against the interpreter and libc it runs under, and the router's are the ones that count.

    resolve.py build   <archive> <workdir>              build the Hermes wheel, write constraints
    resolve.py closure <workdir> <extras> [req ...]     print name==version, one per line
    resolve.py pin     <workdir> <project> <extra>      print upstream's requirement for project

Why a wheel is built here at all

Upstream stopped publishing to PyPI after 0.19.0, and from 0.21 its setup.py refuses to
build a wheel or sdist unless HERMES_NIX_BUILD=1, the flag its own Nix derivation sets.
That derivation is the packaging upstream supports: a wheel of the Python packages, with
skills, locales and the MCP catalogue shipped beside it and found through HERMES_BUNDLED_*
variables. build.sh reproduces that layout; this file produces the wheel the same way.

Why the versions come from uv.lock

pyproject.toml pins only upstream's direct dependencies; everything under them floats.
uv.lock at the pinned commit is what upstream actually tested, so every package is
constrained to its version there. A package the lock holds at two versions (scipy, for
two Python ranges) is left to pip and reported.

Why the exclusion is a graph walk and not a deletion

HERMES_EXCLUDE names upstream dependencies the router package leaves out. Deleting their
directories after install would leave behind whatever only they pulled in, and would
leave the dist-info of a package that is not there. So the closure is walked from Hermes
itself, through each requirement whose marker holds, never entering an excluded name.
What pip resolved but the walk never reached is printed to stderr, so the cost of the
exclusion is visible on every build.

Why a few libraries are newer than the lock

HERMES_LIBRARY_FIXES names libraries, name==version, carried newer than uv.lock for security
advisories published after the pinned commit. Each replaces its lock line, and where Hermes's
own pyproject.toml pins one exactly (Pillow==12.3.0, say), that pin is moved to the same version
before the wheel is built, so the installed metadata declares what ships and nothing disagrees.
Python code is not touched. A fix that is not newer than the lock, names a library the lock does
not have, or meets a pin it cannot satisfy by moving an exact version stops the build: each one
is a decision about a version, and a stale one would go on claiming it.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import zipfile
from pathlib import Path

from pip._vendor.packaging.markers import default_environment
from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.utils import canonicalize_name
from pip._vendor.packaging.version import Version

PIP = [sys.executable, "-m", "pip"]
QUIET = ["--quiet", "--no-cache-dir", "--disable-pip-version-check"]


def die(msg: str) -> "None":
    raise SystemExit(f"resolve.py: {msg}")


def excluded() -> set[str]:
    return {canonicalize_name(n) for n in os.environ.get("HERMES_EXCLUDE", "").split()}


def library_fixes() -> dict[str, str]:
    fixes: dict[str, str] = {}
    for item in os.environ.get("HERMES_LIBRARY_FIXES", "").split():
        req = Requirement(item)
        spec = list(req.specifier)
        if len(spec) != 1 or spec[0].operator != "==" or req.extras or req.marker:
            die(f"HERMES_LIBRARY_FIXES: {item!r} is not name==version")
        fixes[canonicalize_name(req.name)] = spec[0].version
    return fixes


def retarget_pins(pyproject: Path, fixes: dict[str, str]) -> None:
    """Move every exact pin of a fixed library in pyproject.toml to the fixed version."""
    text = pyproject.read_text()
    project = tomllib.loads(text)["project"]
    specs = list(project.get("dependencies", []))
    for group in project.get("optional-dependencies", {}).values():
        specs.extend(group)
    for spec in sorted(set(specs)):
        req = Requirement(spec)
        name = canonicalize_name(req.name)
        if name not in fixes or req.specifier.contains(fixes[name], prereleases=True):
            continue
        pinned = [s for s in req.specifier if s.operator == "=="]
        if len(list(req.specifier)) != 1 or not pinned:
            die(f"pyproject.toml requires {spec!r}, which {name}=={fixes[name]} does not satisfy")
        moved = spec.replace(f"=={pinned[0].version}", f"=={fixes[name]}", 1)
        if f'"{spec}"' not in text:
            die(f"pyproject.toml does not quote {spec!r} as expected; cannot move its pin")
        text = text.replace(f'"{spec}"', f'"{moved}"')
        print(f"resolve.py: pyproject pin {spec} -> {moved}", file=sys.stderr)
    pyproject.write_text(text)


# ---------------------------------------------------------------- build

def build(archive: str, workdir: str) -> None:
    work = Path(workdir)
    src = work / "src"
    wheels = work / "wheel"
    work.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as tf:
        tops = {m.name.split("/", 1)[0] for m in tf.getmembers()}
        if len(tops) != 1:
            die(f"archive has {len(tops)} top-level entries, expected one")
        tf.extractall(work, filter="data")
    top = work / tops.pop()
    if src.exists():
        subprocess.run(["rm", "-rf", str(src)], check=True)
    top.rename(src)

    with open(src / "pyproject.toml", "rb") as fh:
        version = tomllib.load(fh)["project"]["version"]
    want = os.environ.get("HERMES_VERSION")
    if want and version != want:
        die(f"archive declares hermes-agent {version}, upstream.env pins {want}")
    fixes = library_fixes()
    retarget_pins(src / "pyproject.toml", fixes)

    env = dict(os.environ, HERMES_NIX_BUILD="1")
    subprocess.run(PIP + ["wheel", *QUIET, "--no-deps", "-w", str(wheels), str(src)],
                   check=True, env=env, stdout=subprocess.DEVNULL)
    built = sorted(wheels.glob(f"hermes_agent-{version}-*.whl"))
    if len(built) != 1:
        die(f"expected one hermes_agent {version} wheel in {wheels}, found {len(built)}")

    with open(src / "uv.lock", "rb") as fh:
        lock = tomllib.load(fh)
    pins: dict[str, str | None] = {}
    for pkg in lock["package"]:
        source = pkg.get("source", {})
        if "editable" in source or "virtual" in source:
            continue
        name = canonicalize_name(pkg["name"])
        if name in pins and pins[name] != pkg["version"]:
            print(f"resolve.py: {name} is locked at several versions; left to pip", file=sys.stderr)
            pins[name] = None
            continue
        pins.setdefault(name, pkg["version"])
    for name, version in sorted(fixes.items()):
        locked = pins.get(name)
        if name not in pins:
            die(f"HERMES_LIBRARY_FIXES names {name}, which upstream's lock does not have")
        if locked is None:
            die(f"HERMES_LIBRARY_FIXES names {name}, which the lock holds at several versions")
        if Version(version) <= Version(locked):
            die(f"HERMES_LIBRARY_FIXES carries {name} {version}, not newer than the lock's {locked}: drop it")
        pins[name] = version
        print(f"resolve.py: {name} {locked} -> {version} (HERMES_LIBRARY_FIXES)", file=sys.stderr)
    lines = [f"{n}=={v}" for n, v in sorted(pins.items()) if v]
    (work / "constraints.txt").write_text("\n".join(lines) + "\n")
    print(built[0])


# ---------------------------------------------------------------- closure

def wheel_of(work: Path) -> Path:
    found = sorted((work / "wheel").glob("hermes_agent-*.whl"))
    if len(found) != 1:
        die(f"run `resolve.py build` first: {len(found)} hermes wheels in {work / 'wheel'}")
    return found[0]


def report(work: Path, requirements: list[str]) -> list[dict]:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "report.json"
        subprocess.run(
            PIP + ["install", *QUIET, "--root-user-action=ignore", "--only-binary=:all:",
                   "--dry-run", "--ignore-installed", "--report", str(out),
                   "--target", str(Path(tmp) / "t"),
                   "-c", str(work / "constraints.txt"), *requirements],
            check=True, stdout=subprocess.DEVNULL,
        )
        return json.loads(out.read_text())["install"]


def active(req: Requirement, extras: set[str], env: dict) -> bool:
    if req.marker is None:
        return True
    return any(req.marker.evaluate(dict(env, extra=e)) for e in (extras | {""}))


def closure(workdir: str, extras: str, extra_reqs: list[str]) -> None:
    work = Path(workdir)
    root = f"{wheel_of(work)}[{extras}]" if extras else str(wheel_of(work))
    items = report(work, [root, *extra_reqs])
    dists = {canonicalize_name(i["metadata"]["name"]): i for i in items}
    drop = excluded()
    env = default_environment()

    # An exclusion that matches nothing is not harmless: it means upstream renamed or
    # dropped the package, and the list would go on claiming a decision about nothing.
    stale = drop - set(dists)
    if stale:
        die(f"HERMES_EXCLUDE names {' '.join(sorted(stale))}, which upstream no longer resolves")
    reached: set[str] = set()
    todo: list[tuple[str, set[str]]] = [("hermes-agent", {e for e in extras.split(",") if e})]
    for r in extra_reqs:
        req = Requirement(r)
        todo.append((canonicalize_name(req.name), set(req.extras)))
    seen: set[tuple[str, frozenset]] = set()
    while todo:
        name, ex = todo.pop()
        if name in drop or (name, frozenset(ex)) in seen:
            continue
        seen.add((name, frozenset(ex)))
        if name not in dists:
            die(f"{name} is required but pip did not resolve it")
        reached.add(name)
        for spec in dists[name]["metadata"].get("requires_dist") or []:
            req = Requirement(spec)
            if active(req, ex, env):
                todo.append((canonicalize_name(req.name), set(req.extras)))

    unreached = sorted(set(dists) - reached)
    print(f"resolve.py: {len(dists)} resolved, {len(reached)} shipped; left out with "
          f"HERMES_EXCLUDE={' '.join(sorted(drop)) or '-'}: {' '.join(unreached) or 'nothing'}",
          file=sys.stderr)
    for name in sorted(reached - {"hermes-agent"}):
        meta = dists[name]["metadata"]
        print(f"{meta['name']}=={meta['version']}")


# ---------------------------------------------------------------- pin

def pin(workdir: str, project: str, extra: str) -> None:
    whl = wheel_of(Path(workdir))
    with zipfile.ZipFile(whl) as zf:
        meta = next(n for n in zf.namelist() if n.endswith(".dist-info/METADATA"))
        text = zf.read(meta).decode()
    want = canonicalize_name(project)
    for line in text.splitlines():
        if not line.startswith("Requires-Dist:"):
            continue
        req = Requirement(line.split(":", 1)[1].strip())
        if canonicalize_name(req.name) != want or req.marker is None:
            continue
        if re.search(rf"""extra\s*==\s*['"]{re.escape(extra)}['"]""", str(req.marker)):
            req.marker = None
            print(str(req))
            return
    die(f"hermes-agent declares no {project} under its {extra} extra; upstream has moved it")


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[0] == "build":
        build(argv[1], argv[2])
    elif len(argv) >= 3 and argv[0] == "closure":
        closure(argv[1], argv[2], argv[3:])
    elif len(argv) == 4 and argv[0] == "pin":
        pin(argv[1], argv[2], argv[3])
    else:
        die("usage: build <archive> <workdir> | closure <workdir> <extras> [req ...] | "
            "pin <workdir> <project> <extra>")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
