# sitecustomize for the gateway alone: the wrapper (hermes-gateway) puts this directory on PYTHONPATH
# for the gateway's exec and nothing else, and Python imports it before any of upstream's code runs.
#
# It makes the gateway non-dumpable. The wrapper hands the gateway its keys in its environment (the
# model key, the Telegram token, the openwrt-mcp token), and Linux lets any process of the same user
# read /proc/<pid>/environ of a dumpable process. The agent's own terminal runs as that same user,
# so until 0.21.5-r9 the agent could read its model key there (a Flint 2, 2026-10-08). A
# non-dumpable process's /proc entries belong to root, so the keys are root's alone again. Upstream
# already keeps the keys out of the terminal's own environment; this closes the one way left.
#
# Fail closed: a gateway that cannot hide its keys does not start.
import ctypes
import sys

PR_SET_DUMPABLE = 4
try:
    if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_DUMPABLE, 0) failed")
except Exception as e:  # noqa: BLE001 -- any failure means the keys would stay readable
    sys.stderr.write("hermes-gateway: cannot make the gateway non-dumpable (%s); not starting\n" % e)
    raise SystemExit(1)
