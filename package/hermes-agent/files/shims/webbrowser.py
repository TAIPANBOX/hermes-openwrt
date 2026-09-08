"""Stand-in for CPython's webbrowser on OpenWrt, where the module does not exist.

OpenWrt splits the standard library into apk packages and ships no webbrowser at all,
the same way it ships no tkinter: a router has no display and no browser to launch, so
the module would never do anything but fail. Checked on OpenWrt 25.12.4 aarch64: every
other module Hermes needs is packaged (sqlite3, ssl, ctypes, asyncio, multiprocessing,
email, http, xml, decimal, curses, readline), and webbrowser is the single gap.

Without this file `hermes --version` dies before printing anything, because the CLI's
portal subcommand imports webbrowser at module scope:

    File "hermes_cli/portal_cli.py", line 24, in <module>
        import webbrowser
    ModuleNotFoundError: No module named 'webbrowser'

The contract this implements is the real one, not an approximation of it. CPython's
webbrowser.open returns a bool meaning "a browser was successfully launched", and
callers are expected to handle False by showing the URL themselves. On a router the
honest answer to "did you open a browser" is always no, so returning False is not a
degraded mode: it is the correct answer, and it routes Hermes into the fallback path
its own authors wrote for headless machines.

get() and register() raise webbrowser.Error, which is also what upstream does when no
browser can be found, so code that probes for a specific browser fails the way it
would on any headless host rather than in some new way of ours.

The URL is logged rather than swallowed. Anyone reading `logread` after an OAuth or
pairing step needs to see the link they are meant to visit, and this is the only place
it exists on a machine with no screen.
"""

from __future__ import annotations

import logging as _logging

__all__ = ["Error", "open", "open_new", "open_new_tab", "get", "register"]

_log = _logging.getLogger("hermes.webbrowser")


class Error(Exception):
    """Same name and role as webbrowser.Error upstream."""


def open(url, new=0, autoraise=True):  # noqa: A001 - the stdlib name is the point
    """Report that no browser was opened, after making the URL findable in the log."""
    _log.warning("no browser on this device; open this URL yourself: %s", url)
    # Also to stderr: a first-run pairing step is usually watched live on a console,
    # and a log line alone would be missed by someone who has not opened logread yet.
    try:
        import sys

        print(f"open this URL in a browser: {url}", file=sys.stderr, flush=True)
    except Exception:  # pragma: no cover - printing must never break a caller
        pass
    return False


def open_new(url):
    return open(url, 1)


def open_new_tab(url):
    return open(url, 2)


def get(using=None):
    raise Error("no browser is available on OpenWrt")


def register(name, klass, instance=None, *, preferred=False):
    raise Error("no browser is available on OpenWrt")
