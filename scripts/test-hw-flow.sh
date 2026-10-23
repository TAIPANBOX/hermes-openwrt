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

[ "$n" -gt 0 ] || { echo "FAIL: measured nothing: no case ran"; exit 1; }
echo "test-hw-flow: $n checks passed"
