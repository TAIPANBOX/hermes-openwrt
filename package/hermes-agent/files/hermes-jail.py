#!/usr/bin/env python3
"""Run the gateway inside ujail, OpenWrt's own sandbox, so that nothing the agent runs can read
the router's secrets.

    hermes-jail <data_dir> <user> <command> [argument ...]    as root: the wrapper's last line
    hermes-jail --init <user> <command> [argument ...]       inside the sandbox, its first process

Installed as /usr/libexec/hermes-jail. The exec wrapper (hermes-gateway) runs it for the owner
and assistant profiles, after it has read the keys and applied the memory ceiling; the root
profile runs without it, and so does `hermes` run by hand from a root shell.

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
the CA certificates and nothing else of /etc/ssl, the time zone, the release), each taken only
when it resolves to a file or directory owned by root; the data directory, writable; a /tmp of
its own, writable, emptied at every start; a /proc of its own and the router's /sys, read-only;
and the router's /etc/resolv.conf, which ujail adds itself. resolv.conf and the time zone are
the files present at the start: a change to them reaches the sandbox at the next start. The
network is the router's, so ping, DNS, routes and the model and Telegram connections work as
before. Not there: /etc/config, /overlay, /rom, /root, /var and the rest of /tmp, the router's own
processes, and ubus. The agent reads and changes the router through openwrt-mcp, over the
network, exactly as before.

What ujail is given: the environment by name only (-e NAME), so no key reaches a command line;
-t 8, its own SIGKILL for the sandbox 8 s after a stop, inside procd's 10 (the init's
term_timeout); and never -c (no_new_privs), which would stop the setuid ping the agent needs.
ujail fails rather than run the gateway without the sandbox when it cannot build it; a path it
is asked to stage and cannot is skipped silently, so --init checks the ones the gateway needs.
ujail stays root, outside the sandbox, as its supervisor, like procd; it runs none of this
package's code.

Inside, ujail gives the sandbox a pid namespace of its own, so the first process there is pid 1:
the kernel delivers it only signals it handles and hands it every orphan, and when it ends the
kernel ends everything else in the sandbox. That is this file's --init, which, in this order:
takes the stop signals at once (one that came before the gateway exists is passed on when it
does); dies with ujail (PR_SET_PDEATHSIG, armed again after the drop, which clears it), so a
supervisor procd killed never leaves a gateway running unsupervised beside the next one; narrows
the bounding set to CAP_NET_RAW, so a setuid program can give no more than ping needs; gives up
root for good through hermes-drop's own code; makes itself non-dumpable (it holds the keys in its
environment, and the agent's terminal runs as the same user) and checks it; checks the data
directory and /tmp are writable and the CA certificates there; starts the command; passes the
stop signals on and, 5 s after the first, kills the command, as procd did before the sandbox;
reaps whatever ends; and exits with the command's status, 128 plus the signal for one killed.

Python standard library only, like the rest of what runs on the router.
"""
import ctypes
import importlib.util
import os
import pwd
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
# The sandbox's /tmp on the router's side: a directory of the agent's user inside one only root can
# enter, so nothing outside the sandbox can swap it for a link before ujail binds it.
TMP_PARENT = "/tmp/hermes-agent.sandbox"
TMP = TMP_PARENT + "/tmp"
DIRS = ("/bin", "/sbin", "/lib", "/usr")
ETC = ("/etc/passwd", "/etc/group", "/etc/hosts", "/etc/ssl/certs", "/etc/ssl/cert.pem",
       "/etc/ssl/openssl.cnf", "/etc/TZ", "/etc/localtime", "/etc/openwrt_release",
       "/etc/openwrt_version", "/etc/os-release", "/etc/protocols", "/etc/services")
CA_FILES = ("/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem")
# A data directory over any of these would bring them into the sandbox.
COVERS = ("/etc", "/overlay", "/rom", "/root", "/tmp/run", "/var", "/proc", "/sys", "/dev",
          "/usr", "/lib", "/bin", "/sbin", "/boot")
# ujail passes at most 64 environment entries and drops the rest without failing; one is its own.
MAX_ENV = 60
STOP = (signal.SIGTERM, signal.SIGINT, signal.SIGQUIT)
FORWARD = STOP + (signal.SIGHUP, signal.SIGUSR1, signal.SIGUSR2)
GRACE = 5      # seconds from the first stop signal to SIGKILL for the command, as procd gave it
UJAIL_TERM = 8  # ujail's own SIGKILL for the sandbox, inside procd's term_timeout of 10
PR_SET_PDEATHSIG, PR_GET_DUMPABLE, PR_SET_DUMPABLE, PR_CAPBSET_DROP = 1, 3, 4, 24
CAP_NET_RAW = 13

libc = ctypes.CDLL(None, use_errno=True)


def die(message: str) -> None:
    sys.stderr.write(f"hermes-jail: {message}\n")
    sys.exit(1)


def remove(path: str) -> None:
    """Whatever is at path, gone: a directory as a tree, anything else, a link included, as itself."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(st.st_mode):
        shutil.rmtree(path)
    else:
        os.unlink(path)


def fresh_tmp(entry: pwd.struct_passwd) -> None:
    """TMP, empty and the agent's user's own, inside TMP_PARENT, root's and 0700."""
    for attempt in range(3):
        try:
            st = os.lstat(TMP_PARENT)
        except FileNotFoundError:
            try:
                os.mkdir(TMP_PARENT, 0o700)
            except FileExistsError:
                continue  # planted between the two calls: look again
            st = os.lstat(TMP_PARENT)
        if stat.S_ISDIR(st.st_mode) and st.st_uid == 0 and stat.S_IMODE(st.st_mode) == 0o700:
            break
        remove(TMP_PARENT)
    else:
        die(f"{TMP_PARENT} keeps being replaced; not starting")
    remove(TMP)
    os.mkdir(TMP, 0o700)
    os.chown(TMP, entry.pw_uid, entry.pw_gid)


def staged_etc() -> list:
    """ujail's -r for each file of /etc the sandbox carries, bound from where it resolves, and only
    when that is root's: /etc/TZ and /etc/localtime point into /tmp on a router, where a link left by
    another user must not decide what ujail, as root, binds into the sandbox."""
    out = []
    for path in ETC:
        real = os.path.realpath(path)
        try:
            st = os.stat(real)
        except OSError:
            continue
        if st.st_uid != 0 or not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
            continue
        out += ["-r", real if real == path else f"{real}:{path}"]
    return out


def check_data_dir(data_dir: str) -> str:
    real = os.path.realpath(data_dir)
    if not os.path.isabs(data_dir) or ":" in data_dir or real != data_dir.rstrip("/"):
        die(f"the data directory {data_dir} must be a plain absolute path with no ':' and no link in it")
    if not os.path.isdir(real):
        die(f"the data directory {data_dir} is not a directory")
    for covered in COVERS:
        if real == "/" or real == covered or covered.startswith(real + "/") or real.startswith(covered + "/"):
            die(f"the data directory {data_dir} would bring {covered} into the sandbox; set hermes.main.data_dir to a path such as /srv/hermes")
    return real


def outside(data_dir: str, user: str, command: list) -> None:
    if os.geteuid() != 0:
        die("must start as root: it builds the sandbox before the drop")
    if user == "root":
        die("the root profile runs without the sandbox; the wrapper does not call this for it")
    if not os.access(UJAIL, os.X_OK):
        die(f"{UJAIL} is missing; install procd-ujail. Not starting without the sandbox")
    try:
        entry = pwd.getpwnam(user)
    except KeyError:
        die(f"there is no user {user!r}")
    data_dir = check_data_dir(data_dir)
    names = sorted(os.environ)
    if len(names) > MAX_ENV:
        die(f"{len(names)} environment entries, more than ujail passes ({MAX_ENV}); not starting with some of them dropped")
    fresh_tmp(entry)
    argv = [UJAIL, "-n", NAME, "-E", "-p", "-s", "-t", str(UJAIL_TERM)]
    for path in DIRS:
        argv += ["-r", path]
    argv += staged_etc()
    argv += ["-w", data_dir, "-w", f"{TMP}:/tmp"]
    for name in names:
        argv += ["-e", name]
    argv += ["--", PYTHON, "-I", "-B", SELF, "--init", user] + command
    try:
        os.execv(UJAIL, argv)
    except OSError as exc:
        die(f"cannot run {UJAIL}: {exc.strerror}")


def prctl(option: int, arg: int, what: str) -> int:
    ret = libc.prctl(option, arg, 0, 0, 0)
    if ret < 0:
        die(f"{what} failed (errno {ctypes.get_errno()}); not starting")
    return ret


def narrow_bounding_set() -> None:
    try:
        last = int(open("/proc/sys/kernel/cap_last_cap").read())
    except (OSError, ValueError):
        die("cannot read /proc/sys/kernel/cap_last_cap; not starting")
    for cap in range(last + 1):
        if cap != CAP_NET_RAW:
            prctl(PR_CAPBSET_DROP, cap, f"dropping capability {cap} from the bounding set")
    bound = [line.split()[1] for line in open("/proc/self/status") if line.startswith("CapBnd:")]
    if not bound or int(bound[0], 16) != 1 << CAP_NET_RAW:
        die(f"the bounding set is {bound}, not CAP_NET_RAW alone; not starting")


def init(user: str, command: list) -> int:
    # Stop signals first of all: pid 1 ignores a signal it has no handler for, so one that came
    # before these lines would be lost and the stop left to procd's kill.
    state = {"child": 0, "pending": [], "stopping": False}

    def forward(signum, _frame):
        if not state["child"]:
            state["pending"].append(signum)
            return
        # the grace starts when the command is told to stop, not before it exists
        if signum in STOP and not state["stopping"]:
            state["stopping"] = True
            signal.alarm(GRACE)
        try:
            os.kill(state["child"], signum)
        except ProcessLookupError:
            pass  # already gone; the loop below collects it

    def grace_over(_signum, _frame):
        if state["child"]:
            try:
                os.kill(state["child"], signal.SIGKILL)
            except ProcessLookupError:
                pass

    for sig in FORWARD:
        signal.signal(sig, forward)
    signal.signal(signal.SIGALRM, grace_over)
    prctl(PR_SET_PDEATHSIG, int(signal.SIGKILL), "dying with ujail")
    narrow_bounding_set()
    spec = importlib.util.spec_from_file_location("hermes_drop", DROP, loader=SourceFileLoader("hermes_drop", DROP))
    hermes_drop = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hermes_drop)
    hermes_drop.become(user)
    # A change of credentials clears the parent-death signal: armed again, as the agent's user.
    prctl(PR_SET_PDEATHSIG, int(signal.SIGKILL), "dying with ujail, after the drop")
    if prctl(PR_SET_DUMPABLE, 0, "making the sandbox's first process non-dumpable") != 0 or \
            prctl(PR_GET_DUMPABLE, 0, "reading back that it is non-dumpable") != 0:
        die("the sandbox's first process is still dumpable, so its keys would be readable; not starting")
    home = os.environ.get("HERMES_HOME", "")
    if not home or not os.access(home, os.W_OK | os.X_OK):
        die(f"the data directory {home!r} is not writable inside the sandbox; not starting")
    if not os.access("/tmp", os.W_OK | os.X_OK):
        die("/tmp is not writable inside the sandbox; not starting")
    if not any(os.access(path, os.R_OK) for path in CA_FILES):
        die("no CA certificates inside the sandbox, so no TLS connection would verify; not starting")
    child = os.fork()
    if child == 0:
        for sig in FORWARD + (signal.SIGALRM,):
            signal.signal(sig, signal.SIG_DFL)
        try:
            os.execvp(command[0], command)
        except OSError as exc:
            sys.stderr.write(f"hermes-jail: cannot run {command[0]}: {exc.strerror}\n")
        os._exit(127)
    state["child"] = child
    for signum in state["pending"]:
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
