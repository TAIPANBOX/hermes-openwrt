# Run by /usr/bin/hermes in front of upstream's entry point, as
#   python3 /usr/lib/hermes-agent/hermes-start /usr/lib/hermes-agent/site-packages/hermes_cli/main.py ARGS
# and nothing else. Installed without the executable bit: it is not a command.
#
# It gives every thread Hermes starts a stack of THREAD_STACK bytes, then runs main.py exactly as
# `python3 main.py ARGS` would (argv, sys.path[0], __name__ == "__main__"), so the command line still
# reads "hermes_cli/main.py gateway run" for every pgrep and check that looks for it.
#
# Why: musl gives a thread 128 KiB of stack unless the program asks for more, and CPython 3.13 does
# not ask (glibc gives the size of `ulimit -s`, 8 MiB, which is what upstream is built and tested
# with). Upstream runs each model call and each tool in a thread of its own, and a turn with a tool
# ran out of that stack: on a Beryl AX with OpenWrt 25.12.6 and 0.21.5-r25 every such turn died with
# SIGSEGV (rc 139) in a CLI chat and in the gateway, where a scheduled job took the whole gateway
# down. Nothing printed a line: faulthandler's alternate stack belongs to the main thread, so a
# thread that overflows its own has nowhere to run the handler. threading.stack_size() is the one
# setting every thread started from Python honours (threading, concurrent.futures, asyncio's
# executor, the cron scheduler), and it must be made before the first of them starts, which is here,
# before any of upstream's code is imported.
#
# Fail closed: a Hermes whose threads keep musl's default would die at its first tool, and silently,
# so one that cannot have the stack does not start.
import os
import runpy
import sys
import threading

# 4 MiB. Measured with OpenWrt 25.12.6's own CPython 3.13.18 (musl), on x86_64 and on aarch64_cortex-a53
# (under qemu-user), against r25's tree:
# - the tool turn itself died at 256 KiB and finished from 320 KiB, on both;
# - input nested from outside (json.loads, json.dumps, repr, pickle of a list 200000 deep, in a thread)
#   killed the process below 1.66 MiB on x86_64 and below 1.75 MiB on aarch64; only above that did
#   CPython's own recursion guard, sized for glibc's 8 MiB, raise RecursionError instead.
# Such input reaches a thread that is already as deep as the turn, so the need is the two together,
# about 2.1 MiB on aarch64: 4 MiB is the smallest power of two above it.
# A stack is reserved, not spent: only the pages a thread touches count towards its memory, so the
# peak resident size of a tool turn moved by less than a run-to-run difference between 1, 4 and 8 MiB.
THREAD_STACK = 4 * 1024 * 1024

try:
    threading.stack_size(THREAD_STACK)
except Exception as e:  # noqa: BLE001 -- any failure leaves musl's default in force
    sys.stderr.write("hermes: cannot give the agent's threads a %d KiB stack (%s); not starting\n"
                     % (THREAD_STACK // 1024, e))
    raise SystemExit(1)

if len(sys.argv) < 2:
    sys.stderr.write("hermes-start: run by /usr/bin/hermes with upstream's main.py as its first argument\n")
    raise SystemExit(2)
script = sys.argv[1]
del sys.argv[0]
sys.path[0] = os.path.dirname(os.path.abspath(script))
runpy.run_path(script, run_name="__main__")
