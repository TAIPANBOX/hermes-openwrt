#!/bin/sh
# test-hw-flow.sh -- hw-flow.sh's log helpers, mark and since, without a router.
#
# A step marks the router's log (`logger -t hw-flow`) and later reads what came after its mark
# (`logread`). logread keeps earlier runs, so reading from the first line of that name took them in:
# on a Flint 2 on 2026-10-23 a second run of `start` counted two "Refused" lines an earlier run's cron
# job had logged, and a clean start said FAIL. Here `on` is a stand-in router whose log is a file.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LOGF=$T/logread
: > "$LOGF"

ROUTER=test@invalid OUT=$T/out HW_FLOW_LIB=1 . "$ROOT/scripts/hw-flow.sh"

cat > "$T/router.sh" <<'EOF'
logger() { shift 2; printf '%s user.notice hw-flow: %s\n' 'Fri Oct 23 13:50:22 2026' "$*" >> "$LOGF"; }
logread() { cat "$LOGF"; }
eval "$1"
EOF
on() { LOGF=$LOGF sh "$T/router.sh" "$*"; }
line() { printf 'Fri Oct 23 13:50:22 2026 daemon.err hermes-gateway[1]: %s\n' "$1" >> "$LOGF"; }

n=0
check() { n=$((n + 1)); echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; exit 1; }

# 1. An earlier run's mark and what followed it, then this run's: only this run's lines are read.
printf 'Fri Oct 23 13:40:00 2026 user.notice hw-flow: start\n' >> "$LOGF"
line 'Refused: a scheduled job cannot change the router (earlier run)'
mark start
line 'gateway up (this run)'
out=$(since start)
case "$out" in *'this run'*) ;; *) fail own_mark_read "the lines after this run's mark were not read: $out" ;; esac
case "$out" in *'earlier run'*) fail own_mark_read "an earlier run's line was read as this run's" ;; esac
check own_mark_read

# 2. The same step marked twice in one run reads from the second mark.
mark telegram
line 'first telegram start'
mark telegram
line 'second telegram start'
out=$(since telegram)
case "$out" in *'second telegram start'*) ;; *) fail latest_mark_read "the second start was not read: $out" ;; esac
case "$out" in *'first telegram start'*) fail latest_mark_read "the first start was read with the second" ;; esac
check latest_mark_read

# 3. Asked before its mark, since says so and reads nothing, rather than an empty read that a
# count of refusals takes for "none".
if out=$(since admin 2>&1); then fail no_mark_refused "since without a mark answered: $out"; fi
case "$out" in *'before its mark'*) ;; *) fail no_mark_refused "no reason given: $out" ;; esac
check no_mark_refused

# 4. `clean` does not count a mount point the owner configured (the USB stick's, at the data
# directory) as something left behind, as long as nothing is left inside it. On a Flint 2 on
# 2026-11-07 the stick's /srv/hermes was counted and `clean` said FAIL for a router that was clean.
mkdir -p "$T/data" "$T/mounted"
printf 'tmpfs %s ext4 rw 0 0\n' "$T/mounted" > "$T/mounts"
left() { sh -c "$(clean_leftovers_script "$1" "$T/mounts")"; }
[ -z "$(left "$T/absent")" ] || fail clean_absent_dir "a directory that is not there was counted"
[ "$(left "$T/data")" = "$T/data" ] || fail clean_plain_dir "a plain directory left behind was not counted: $(left "$T/data")"
[ -z "$(left "$T/mounted")" ] || fail clean_empty_mount_point "an empty mount point was counted as left behind"
: > "$T/mounted/state.db"
case "$(left "$T/mounted")" in *"not empty"*) ;; *) fail clean_full_mount_point "data left inside a mount point was not counted" ;; esac
check clean_ignores_the_owners_mount_point

# 5. admin opens the change window through the owner's client. Since 0.21.5-r16 the agent's own
# client is refused its unlock, so a step that unlocks with the agent's token never had a window:
# the change was refused and `admin-rollback` passed because the value had never changed.
STEP=$T/step_admin.sh
sed -n '/^step_admin()/,/^}/p' "$ROOT/scripts/hw-flow.sh" > "$STEP"
[ -s "$STEP" ] || fail admin_step_found "measured nothing: step_admin not found in hw-flow.sh"
admin_as_owner() { # a step file: its unlock and wrong-PIN tries go through probe_owner, and nothing locks as the agent
	[ "$(grep -B1 'pass admin-unlock' "$1" | head -n 1 | grep -c 'probe_owner mfa_unlock')" = 1 ] &&
	[ "$(grep -B1 'pass admin-wrong-pin' "$1" | head -n 1 | grep -c 'probe_owner mfa_unlock')" = 1 ] &&
	[ "$(grep -c 'probe mfa_lock' "$1")" = 0 ]
}
admin_as_owner "$STEP" || fail admin_unlocks_as_owner "the admin step unlocks, or locks, with the agent's token"
sed 's/probe_owner/probe/g' "$STEP" > "$T/step_admin_agent.sh"
if admin_as_owner "$T/step_admin_agent.sh"; then fail admin_agent_token_caught "an admin step using the agent's token was accepted"; fi
check admin_unlocks_as_owner

# 6. admin-rollback passes only for a change that was applied and then reverted by itself.
verdict() { : > "$LOG"; check_rollback "$1" "$2" "$3"; cat "$LOG"; }
case "$(verdict old old old)" in FAIL\ admin-rollback*) ;; *) fail rollback_never_applied "a change that never happened passed as a rollback" ;; esac
case "$(verdict old hw-flow hw-flow)" in FAIL\ admin-rollback*) ;; *) fail rollback_not_undone "a change still in place after the deadline passed" ;; esac
case "$(verdict old hw-flow old)" in PASS\ admin-rollback*) ;; *) fail rollback_fires "a change applied and reverted was not accepted" ;; esac
case "$(verdict unset hw-flow unset)" in PASS\ admin-rollback*) ;; *) fail rollback_fires_unset "an option that was unset, applied and unset again, was not accepted" ;; esac
check rollback_must_really_fire

[ "$n" -gt 0 ] || { echo "FAIL: measured nothing: no case ran"; exit 1; }
echo "test-hw-flow: $n checks passed"
