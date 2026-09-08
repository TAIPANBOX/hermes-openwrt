#!/usr/bin/env python3
"""Refuse to assemble a package on the wrong libc.

pip resolves wheels for the interpreter it runs under. Run on a glibc machine, it picks
manylinux wheels that load nothing on OpenWrt, and the failure surfaces at import time
on the router rather than here. Silent success is the dangerous outcome, so this exits
non-zero and says which script to run instead.

Three probes, cheapest first, and every one of them may legitimately be unavailable:
`packaging` is not in OpenWrt's stdlib split, and `ldd` does not exist on macOS. An
absent probe is not a pass. Falling through means musl was never positively identified,
and the answer is no.
"""
import subprocess
import sys
import sysconfig


def is_musl() -> bool:
    if "musl" in sysconfig.get_platform() + (sysconfig.get_config_var("SOABI") or "") + sys.version:
        return True
    try:
        from packaging.tags import sys_tags
        return any("musl" in str(tag) for tag in sys_tags())
    except ImportError:
        pass
    try:
        out = subprocess.run(["ldd", sys.executable], capture_output=True, text=True)
        return "musl" in (out.stdout + out.stderr)
    except (FileNotFoundError, OSError):
        return False


if is_musl():
    raise SystemExit(0)

sys.stderr.write(
    "musl-guard: this interpreter is not musl, so pip here resolves the wrong wheels.\n"
    f"musl-guard: it is {sys.implementation.name} {sys.version.split()[0]} "
    f"on {sysconfig.get_platform()}.\n"
    "musl-guard: run build-in-container.sh, which does this inside the target rootfs.\n"
)
raise SystemExit(1)
