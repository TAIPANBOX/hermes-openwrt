#!/bin/sh
# teeth-upstream-watch.sh -- gate-upstream-watch.sh has to fail on a watcher that opens a
# second issue for the same release (closed ones and an older pin in the title included),
# one that reads the release or the issues without the arguments GitHub needs, one that
# passes when it cannot read upstream or the issues, one that takes any different tag for
# a newer one or goes quiet on a tag it cannot order; and pass the watcher as it is.
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
	'grep -F -x -q -- "$prefix"; then' 'false; then'
plant "closed issues not listed" check_no_second_issue \
	'--state all --limit' '--limit'
plant "an older issue matched on its whole title, pin included" check_no_second_issue \
	'cut -c1-${#prefix} | grep -F -x -q -- "$prefix"' 'grep -F -x -q -- "$title"'
plant "the release read without --jq" check_quiet_when_pinned_is_latest \
	'--jq .tag_name' ''
plant "the issue opened without --repo" check_issue_when_upstream_is_newer \
	'gh issue create --repo "$REPO"' 'gh issue create'
plant "a tag it cannot order goes quiet" check_refuses_unrecognised_tag \
	"look at it by hand\" >&2
		exit 1" "look at it by hand\" >&2
		exit 0"
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
