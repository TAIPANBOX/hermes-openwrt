#!/bin/sh
# teeth-upstream-watch.sh -- gate-upstream-watch.sh has to fail on a watcher that opens a
# second issue for the same release, one that passes when it cannot read upstream, and
# one that takes any different tag for a newer one; and pass the watcher as it is.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE=$HERE/gate-upstream-watch.sh
REAL=$HERE/upstream-watch.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

# $1 the fault, $2 the check that has to go red, $3 the text to replace, $4 its replacement
plant() {
	python3 - "$REAL" "$T/watch.sh" "$3" "$4" <<'PY' || { echo "TEETH FAILED: $1 (the text to plant over is gone)"; fail=1; return; }
import sys
src, dst, old, new = sys.argv[1:]
s = open(src).read()
if old not in s:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new, 1))
PY
	out=$(WATCH="$T/watch.sh" "$GATE" 2>&1)
	if printf '%s\n' "$out" | grep -q "^FAIL: $2"; then
		echo "teeth ok: $1 -> $2"
	else
		echo "TEETH FAILED: $1 did not turn $2 red"; printf '%s\n' "$out" | sed 's/^/  /'; fail=1
	fi
}

plant "a second issue for the same release" check_no_second_issue \
	'grep -F -x -q -- "$title"; then' 'false; then'
plant "an unreadable upstream passes" check_refuses_when_upstream_unreadable \
	"from \$UPSTREAM\" >&2
	exit 1" "from \$UPSTREAM\" >&2
	exit 0"
plant "issues that cannot be read count as none" check_refuses_when_issues_unreadable \
	"--json title --jq '.[].title') || {" "--json title --jq '.[].title') || true; false && {"
plant "any different tag is news" check_quiet_when_pinned_is_ahead \
	'|| [ "$newest" = "$HERMES_TAG" ]' ''

out=$("$GATE" 2>&1) || { echo "TEETH FAILED: the watcher as it is does not pass"; printf '%s\n' "$out" | sed 's/^/  /'; fail=1; }
[ "$fail" = 0 ] && echo "teeth ok: the watcher as it is passes"
WATCH="$T/absent.sh" "$GATE" 2>&1 | grep -q 'measured nothing' \
	&& echo "teeth ok: no watcher is 'measured nothing'" \
	|| { echo "TEETH FAILED: a missing watcher was not refused"; fail=1; }
exit "$fail"
