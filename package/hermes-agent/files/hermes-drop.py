#!/usr/bin/env python3
"""Run a command as another user, having first given up root for good.

    hermes-drop <user> <command> [argument ...]

Installed as /usr/libexec/hermes-drop. The exec wrapper (hermes-gateway) and the
`hermes` launcher use it so that the gateway, and every process the agent starts, run as
the unprivileged user `hermes` while the wrapper itself, which has to read root-only key
files and apply the memory ceiling, stays root until the very last line.

@decided 2026-10-01: the agent no longer runs as root unless its profile says so.

What it does, in this order, and why the order matters:

  setgroups([])   first, while still root: a process that keeps root's supplementary
                  groups (adm, dialout, whatever the box has) is not unprivileged.
  setresgid       then the group, while setgid is still allowed.
  setresuid       last, real, effective and saved ids together, so that setuid(0) cannot
                  take root back and no saved id is left behind.

then it verifies the drop took, instead of trusting the three calls: the real, effective
and saved ids are the target's, no supplementary group is left, and setuid(0) is refused.
Any doubt stops here with a message and exit status 1. The command is never run with
privileges the caller did not mean it to have, and a drop that half worked is worse than
none, because nobody would see it.

A target of root is a plain exec: the root profile asks for exactly that, and nothing is
lowered. Already being the target user is also a plain exec, so the launcher can use this
unconditionally.

HOME is the data directory when HERMES_HOME names an existing one (the user's home in
the password file is the default data directory, but UCI can put the data elsewhere), else
the home the password file gives. USER and LOGNAME are the target's name. The current
directory is kept unless the new user cannot enter it (an SSH session in /root), in which
case it moves to HOME rather than leave the command in a directory it cannot read.
Everything else in the environment passes through: the wrapper has put the credentials
there on purpose.

Python standard library only, like the rest of what runs on the router.
"""
import os
import pwd
import sys


def die(message: str) -> None:
    sys.stderr.write(f"hermes-drop: {message}\n")
    sys.exit(1)


def drop(user: str) -> pwd.struct_passwd:
    try:
        entry = pwd.getpwnam(user)
    except KeyError:
        die(f"there is no user {user!r}; is hermes-agent installed?")
    if entry.pw_uid == 0:
        die("a drop to uid 0 is not a drop")
    if os.geteuid() != 0:
        # Not root, so nothing can be given up. Being the target already is fine; being
        # anyone else means the caller asked for something this cannot do.
        ids = (os.getuid(), os.geteuid(), os.getgid(), os.getegid())
        if ids == (entry.pw_uid, entry.pw_uid, entry.pw_gid, entry.pw_gid):
            return entry
        die(f"not root, so cannot become {user}")
    try:
        os.setgroups([])
        os.setresgid(entry.pw_gid, entry.pw_gid, entry.pw_gid)
        os.setresuid(entry.pw_uid, entry.pw_uid, entry.pw_uid)
    except OSError as exc:
        die(f"cannot become {user}: {exc.strerror}")
    return entry


def verify(entry: pwd.struct_passwd) -> None:
    if os.getresuid() != (entry.pw_uid,) * 3:
        die("the user ids are not all the target's after the drop")
    if os.getresgid() != (entry.pw_gid,) * 3:
        die("the group ids are not all the target's after the drop")
    if os.getgroups():
        die("a supplementary group was kept through the drop")
    try:
        os.setuid(0)
    except OSError:
        return
    die("root can be taken back after the drop")


def main(argv) -> int:
    if len(argv) < 3:
        sys.stderr.write("usage: hermes-drop <user> <command> [argument ...]\n")
        return 2
    user, command = argv[1], argv[2:]
    if user == "root":
        entry = None
    else:
        entry = drop(user)
        verify(entry)
        home = os.environ.get("HERMES_HOME", "")
        os.environ["HOME"] = home if home and os.path.isdir(home) else entry.pw_dir
        os.environ["USER"] = os.environ["LOGNAME"] = user
        # os.access, not os.getcwd: a directory the new user cannot enter can still be
        # named by a process that was in it before the drop.
        if not os.access(".", os.X_OK) or not os.access(".", os.R_OK):
            try:
                os.chdir(os.environ["HOME"])
            except OSError:
                os.chdir("/")
    try:
        os.execvp(command[0], command)
    except OSError as exc:
        die(f"cannot run {command[0]}: {exc.strerror}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
