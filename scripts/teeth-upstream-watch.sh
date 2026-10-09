#!/bin/sh
# teeth-upstream-watch.sh -- gate-upstream-watch.sh has to fail on a watcher that opens a
# second issue for the same release (closed ones and an older pin in the title included),
# one that reads the release or the issues without the arguments GitHub needs, one that
# passes when it cannot read upstream or the issues, one that takes any different tag for
# a newer one or goes quiet on a tag it cannot order; one that orders releases by their tags
# rather than by the Hermes version they carry (vX.Y.Z and vYEAR.MONTH.DAY alike), compares
# versions as text, takes a year for a version, or lets a release name or a pin it cannot
# read pass quietly; and pass the watcher as it is.
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
	"--jq '.tag_name, (.name // \"\")'" ''
plant "the release name not read, so a date tag has no version" check_quiet_when_pinned_is_latest \
	"--jq '.tag_name, (.name // \"\")'" '--jq .tag_name'
plant "the issue opened without --repo" check_issue_when_upstream_is_newer \
	'gh issue create --repo "$REPO"' 'gh issue create'
plant "a tag it cannot order goes quiet" check_refuses_unrecognised_tag \
	'look at it by hand" >&2; exit 1; }' 'look at it by hand" >&2; exit 0; }'
plant "an unreadable upstream passes" check_refuses_when_upstream_unreadable \
	"from \$UPSTREAM\" >&2
	exit 1" "from \$UPSTREAM\" >&2
	exit 0"
plant "issues that cannot be read count as none" check_refuses_when_issues_unreadable \
	"--json title --jq '.[].title') || {" "--json title --jq '.[].title') || true; false && {"
plant "any different version is news" check_quiet_when_pinned_is_ahead \
	'if ! newer "$version" "$HERMES_VERSION"; then' 'if [ "$version" = "$HERMES_VERSION" ]; then'
plant "any different version is news, across schemes" check_mixed_schemes_order_by_version \
	'if ! newer "$version" "$HERMES_VERSION"; then' 'if [ "$version" = "$HERMES_VERSION" ]; then'
plant "releases ordered by their tags (the 2026-10-08 defect, quiet instead of red)" check_issue_when_semver_after_date_pin \
	'if ! newer "$version" "$HERMES_VERSION"; then' 'if [ "$(printf "%s\n%s\n" "$HERMES_TAG" "$latest" | sort -V | tail -n 1)" = "$HERMES_TAG" ]; then'
plant "a vX.Y.Z tag not recognised" check_issue_when_semver_after_date_pin \
	"SEMVER_TAG='^v[0-9]{1,3}" "SEMVER_TAG='^never"
plant "a year read as a vX.Y.Z tag" check_mixed_schemes_order_by_version \
	"SEMVER_TAG='^v[0-9]{1,3}" "SEMVER_TAG='^v[0-9]+"
plant "the same version under another tag is news" check_quiet_when_same_version_new_scheme \
	"		exit 1 }'" "		exit 0 }'"
plant "versions compared as text, so 0.21.10 is before 0.21.6" check_mixed_schemes_order_by_version \
	'if (x[i] + 0 != y[i] + 0) exit !(x[i] + 0 > y[i] + 0)' 'if (x[i] "" != y[i] "") exit !(x[i] "" > y[i] "")'
plant "a date tag whose name gives no version passes" check_refuses_unrecognised_tag \
	'[ -n "$named" ] || refuse' '[ -n "$named" ] || true ||'
plant "a vX.Y.Z tag whose name gives another version passes" check_refuses_unrecognised_tag \
	'[ "$named" != "$version" ]; then' 'false; then'
plant "a pinned version that is not X.Y.Z passes" check_refuses_unrecognised_tag \
	'|| refuse "the pinned HERMES_VERSION' '|| true "the pinned HERMES_VERSION'
plant "a pinned vX.Y.Z tag that is not the pinned version passes" check_refuses_unrecognised_tag \
	'[ "$HERMES_TAG" != "v$HERMES_VERSION" ]; then' 'false; then'

out=$("$GATE" 2>&1) || { echo "TEETH FAILED: the watcher as it is does not pass"; printf '%s\n' "$out" | sed 's/^/  /'; fail=1; }
[ "$fail" = 0 ] && echo "teeth ok: the watcher as it is passes"
WATCH="$T/absent.sh" "$GATE" 2>&1 | grep -q 'measured nothing' \
	&& echo "teeth ok: no watcher is 'measured nothing'" \
	|| { echo "TEETH FAILED: a missing watcher was not refused"; fail=1; }
exit "$fail"
