#!/usr/bin/env python3
"""Apply and verify the gateway's cgroup v2 ceiling before starting upstream.

@codex 2026-09-19: procd places instance1 in this cgroup before exec. Never
change a parent/root group's memory limit when delegation is unavailable.
"""
import re
import sys
from pathlib import Path

CGROUP_ROOT = Path("/sys/fs/cgroup")
MEMBERSHIP = Path("/proc/self/cgroup")
INSTANCE = "/services/hermes-agent/instance1"


def limit_bytes(raw: str) -> int:
    if not re.fullmatch(r"[0-9]{1,7}", raw) or int(raw) > 1048576:
        raise ValueError("mem_max_mb must be 0..1048576")
    return int(raw) * 1024 * 1024


def _instance_membership():
    return [line[3:] for line in MEMBERSHIP.read_text().splitlines() if line.startswith("0::")]


def _write_verified(target: Path, value: str) -> None:
    target.write_text(value)
    if target.read_text().strip() != value:
        raise RuntimeError(f"{target.name} did not retain its configured value")


def _lift_previous_ceiling() -> None:
    # Explicitly disabling the ceiling must never refuse, even when the cgroup is
    # unavailable: only lift what THIS gateway's own dedicated cgroup may still carry
    # from an earlier start, and only files that are actually there. procd on 25.12
    # never removes an instance's cgroup, so an old memory.max otherwise survives
    # every later restart that asks for no limit at all.
    if _instance_membership() != [INSTANCE]:
        return
    group = CGROUP_ROOT / INSTANCE.lstrip("/")
    for name, value in (("memory.max", "max"), ("memory.swap.max", "max"),
                        ("memory.oom.group", "0")):
        target = group / name
        if target.exists():
            _write_verified(target, value)


def apply(raw: str) -> None:
    size = limit_bytes(raw)
    if not size:
        _lift_previous_ceiling()
        return
    membership = _instance_membership()
    if membership != [INSTANCE]:
        raise RuntimeError("gateway is not in its dedicated procd cgroup")
    # Enable accounting down the existing procd hierarchy, never set a limit on it.
    for relative in ("", "services", "services/hermes-agent"):
        parent = CGROUP_ROOT / relative
        if "memory" not in (parent / "cgroup.controllers").read_text().split():
            raise RuntimeError("cgroup v2 memory controller unavailable")
        subtree = parent / "cgroup.subtree_control"
        if "memory" not in subtree.read_text().split():
            subtree.write_text("+memory")
        if "memory" not in subtree.read_text().split():
            raise RuntimeError("memory controller delegation failed")
    group = CGROUP_ROOT / INSTANCE.lstrip("/")
    # Kill this gateway and its descendants together; bound swap separately so it
    # cannot turn a memory fault into unbounded swapping on the router.
    for name, value in (("memory.max", str(size)), ("memory.swap.max", "0"),
                        ("memory.oom.group", "1")):
        _write_verified(group / name, value)


def main() -> int:
    try:
        if len(sys.argv) != 2:
            raise ValueError("usage: hermes-memory <mem_max_mb>")
        apply(sys.argv[1])
    except (OSError, ValueError, RuntimeError) as exc:
        sys.stderr.write(f"hermes-memory: refusing unbounded start: {exc}. "
                         "Requires writable cgroup v2 memory control; set mem_max_mb=0 "
                         "only to explicitly run without a limit.\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
