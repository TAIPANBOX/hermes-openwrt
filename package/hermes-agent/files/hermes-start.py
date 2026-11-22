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
#
# It also keeps a Console key from being sent as Claude Code (0.21.5-r27). Upstream's
# agent/anthropic_credentials.py `_is_oauth_token` calls any `sk-ant-` key that does not begin `sk-ant-api`
# an OAuth token, and for api.anthropic.com an OAuth token goes out as Claude Code: Authorization: Bearer,
# the claude-code and oauth betas, a claude-code user agent and a "You are Claude Code" system line.
# Anthropic's Console keys begin `sk-ant-usr-` now, so on 2026-11-22 every request a router made with its
# own API key was refused with "Your credit balance is too low to access the Anthropic API", where the
# same key sent as x-api-key answered. An OAuth token begins `sk-ant-oat` (upstream's own credential pool
# classifies by that prefix), so here the shape test says OAuth only for those, and for the other shapes
# it already knew (eyJ, cc-); every other `sk-ant-` key is an API key. The package never signs in to
# Anthropic with a subscription, so no key it hands a provider is meant to be anything else.
# It is done as a hook on the import, not by importing upstream here: main.py sets up its environment
# before it imports anything of upstream's, and this file must not import any of it first. Upstream's
# modules take the function by name when they are imported, which is after the hook has run.
import importlib.abc
import importlib.machinery
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

_CREDENTIALS = "agent.anthropic_credentials"
_OAUTH_PREFIX = "sk-ant-oat"


def _api_key_shapes(module):
    original = getattr(module, "_is_oauth_token", None)
    if not callable(original) or not hasattr(module, "anthropic_route_is_oauth"):
        # Fail closed, as with the stack: an upstream whose key test is not where this expects would
        # send a Console key as Claude Code, and silently refused for credit.
        raise ImportError("hermes: upstream's Anthropic key test is not where hermes-start expects it; not starting")

    def _is_oauth_token(key):
        if isinstance(key, str) and key.startswith("sk-ant-") and not key.startswith(_OAUTH_PREFIX):
            return False
        return original(key)

    _is_oauth_token.__doc__ = original.__doc__
    module._is_oauth_token = _is_oauth_token


class _PatchedLoader:
    def __init__(self, inner):
        self._inner = inner

    def create_module(self, spec):
        return self._inner.create_module(spec)

    def exec_module(self, module):
        self._inner.exec_module(module)
        _api_key_shapes(module)


class _ApiKeyShapes(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path=None, target=None):
        if name != _CREDENTIALS:
            return None
        spec = importlib.machinery.PathFinder.find_spec(name, path)
        if spec is None or spec.loader is None:
            return None
        spec.loader = _PatchedLoader(spec.loader)
        return spec


sys.meta_path.insert(0, _ApiKeyShapes())

if len(sys.argv) < 2:
    sys.stderr.write("hermes-start: run by /usr/bin/hermes with upstream's main.py as its first argument\n")
    raise SystemExit(2)
script = sys.argv[1]
del sys.argv[0]
sys.path[0] = os.path.dirname(os.path.abspath(script))
runpy.run_path(script, run_name="__main__")
