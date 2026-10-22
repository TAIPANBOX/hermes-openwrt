#!/usr/bin/env python3
"""Run the gateway inside ujail, OpenWrt's own sandbox, so that nothing the agent runs can read
the router's secrets.

    hermes-jail <data_dir> <user> <command> [argument ...]    as root: the wrapper's last line
    hermes-jail --init <user> <command> [argument ...]       inside the sandbox, its first process

Installed as /usr/libexec/hermes-jail. The exec wrapper (hermes-gateway) runs it for the owner
and assistant profiles, after it has read the keys and applied the memory ceiling; the root
profile runs without it.

@decided 2026-10-22: the agent's own tools never read the router's secrets.

Why a sandbox and not file modes. A router keeps secrets in files every user may read:
/etc/config/wireless is 0644 where first boot made it so, libuci keeps a file's mode on every
commit (uci file.c, uci_file_commit), so the Wi-Fi key the owner sets in LuCI stays readable by
everyone, and hostapd's runtime file in /var/run holds the same passphrase. openwrt-mcp redacts
them when the agent reads the router through it, but the agent's terminal, file and search tools
run as the user hermes and opened the files directly (a Flint 2, 2026-10-22). Changing the modes
of the router's files would be the package reaching into the system and would miss the next
package that keeps a secret somewhere else. So the gateway, and so every process the agent
starts, sees only what is listed below; anything not listed is not there at all.

What the sandbox has, read-only unless said: /bin, /sbin, /lib and /usr (the programs, Python,
the package itself); a few files of /etc a program needs (passwd and group for the drop, hosts,
the CA certificates, the time zone, the release); the data directory, writable; a /tmp of its
own, writable, which is emptied at every start; its own /proc and /sys; and the
router's /etc/resolv.conf, which ujail adds itself. The network is the router's, so ping, DNS,
routes and the model and Telegram connections work as before. Not there: /etc/config, /overlay,
/rom, /root, /var and the rest of /tmp, the router's own processes, and ubus. The agent reads
and changes the router through openwrt-mcp, over the network, exactly as before.

What ujail is given: -E, so a sandbox that cannot be built stops the start instead of running
the gateway without one; the environment by name only (-e NAME), so no key reaches a command
line; and never -c (no_new_privs), which would stop the setuid ping the agent needs. ujail stays
root, outside the sandbox, as its supervisor, like procd; it runs none of this package's code.

Inside, ujail gives the sandbox a pid namespace of its own, so the first process there is pid 1:
the kernel delivers it only signals it handles and hands it every orphan. That is this file's
--init: it gives up root for good through hermes-drop's own code, makes itself non-dumpable (it
holds the keys in its environment, and the agent's terminal runs as the same user), starts the
command, forwards the stop signals to it, reaps whatever ends, and exits with the command's
status. When it exits the kernel ends everything else in the sandbox.

Python standard library only, like the rest of what runs on the router.
"""
import ctypes
import importlib.util
import os
import shutil
import signal
import stat
import sys
from importlib.machinery import SourceFileLoader

UJAIL = "/sbin/ujail"
NAME = "hermes-agent"
SELF = "/usr/libexec/hermes-jail"
DROP = "/usr/libexec/hermes-drop"
PYTHON = "/usr/bin/python3"
# The sandbox's /tmp on the router's side, emptied and handed to the agent's user at every start.
TMP = "/tmp/hermes-agent.sandbox-tmp"
READ_ONLY = ("/bin", "/sbin", "/lib", "/usr",
             "/etc/passwd", "/etc/group", "/etc/hosts", "/etc/ssl", "/etc/TZ", "/etc/localtime",
             "/etc/openwrt_release", "/etc/openwrt_version", "/etc/os-release",
             "/etc/protocols", "/etc/services")
# ujail passes at most 64 environment entries and drops the rest without failing; one is its own.
MAX_ENV = 60
FORWARD = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT, signal.SIGUSR1, signal.SIGUSR2)
PR_SET_DUMPABLE, PR_GET_DUMPABLE = 4, 3


def die(message: str) -> None:
    sys.stderr.write(f"hermes-jail: {message}\n")
    sys.exit(1)


def fresh_tmp(user: str) -> None:
    """TMP, empty, the agent's user's own and closed to everyone else. Never through a symlink:
    whatever is at the path is removed first, a link as a link."""
    import pwd
    try:
        entry = pwd.getpwnam(user)
    except KeyError:
        die(f"there is no user {user!r}")
    try:
        st = os.lstat(TMP)
    except FileNotFoundError:
        st = None
    if st is not None:
        if stat.S_ISDIR(st.st_mode):
            shutil.rmtree(TMP)
        else:
            os.unlink(TMP)
    os.mkdir(TMP, 0o700)
    os.chown(TMP, entry.pw_uid, entry.pw_gid)


def outside(data_dir: str, user: str, command: list) -> None:
    if os.geteuid() != 0:
        die("must start as root: it builds the sandbox before the drop")
    if user == "root":
        die("the root profile runs without the sandbox; the wrapper does not call this for it")
    if not os.access(UJAIL, os.X_OK):
        die(f"{UJAIL} is missing; install procd-ujail. Not starting without the sandbox")
    if not os.path.isdir(data_dir) or os.path.islink(data_dir):
        die(f"the data directory {data_dir} is not a directory")
    names = sorted(os.environ)
    if len(names) > MAX_ENV:
        die(f"{len(names)} environment entries, more than ujail passes ({MAX_ENV}); not starting with some of them dropped")
    fresh_tmp(user)
    argv = [UJAIL, "-n", NAME, "-E", "-p", "-s"]
    for path in READ_ONLY:
        if os.path.lexists(path):
            argv += ["-r", path]
    argv += ["-w", data_dir, "-w", f"{TMP}:/tmp"]
    for name in names:
        argv += ["-e", name]
    argv += ["--", PYTHON, "-I", "-B", SELF, "--init", user] + command
    try:
        os.execv(UJAIL, argv)
    except OSError as exc:
        die(f"cannot run {UJAIL}: {exc.strerror}")


def nondumpable() -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0 or libc.prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) != 0:
        die("cannot make the sandbox's first process non-dumpable, so its keys would be readable; not starting")


def init(user: str, command: list) -> int:
    spec = importlib.util.spec_from_file_location("hermes_drop", DROP, loader=SourceFileLoader("hermes_drop", DROP))
    hermes_drop = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hermes_drop)
    hermes_drop.become(user)
    nondumpable()
    # The handlers go in before the fork: pid 1 ignores a signal it has no handler for, so a stop
    # that came between the fork and a later signal() would be lost and the stop would wait for
    # procd's kill. One that comes before the gateway exists is kept and passed on once it does.
    child, pending = 0, []

    def forward(signum, _frame):
        if not child:
            pending.append(signum)
            return
        try:
            os.kill(child, signum)
        except ProcessLookupError:
            pass  # already gone; the loop below collects it

    for sig in FORWARD:
        signal.signal(sig, forward)
    child = os.fork()
    if child == 0:
        for sig in FORWARD:
            signal.signal(sig, signal.SIG_DFL)
        try:
            os.execvp(command[0], command)
        except OSError as exc:
            sys.stderr.write(f"hermes-jail: cannot run {command[0]}: {exc.strerror}\n")
        os._exit(127)
    for signum in pending:
        forward(signum, None)
    while True:
        try:
            pid, status = os.waitpid(-1, 0)
        except ChildProcessError:
            return 1
        if pid == child:
            code = os.waitstatus_to_exitcode(status)
            return code if code >= 0 else 128 - code


def main(argv) -> int:
    if len(argv) >= 4 and argv[1] == "--init":
        return init(argv[2], argv[3:])
    if len(argv) >= 4 and not argv[1].startswith("-"):
        outside(argv[1], argv[2], argv[3:])
    sys.stderr.write("usage: hermes-jail <data_dir> <user> <command> [argument ...]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
