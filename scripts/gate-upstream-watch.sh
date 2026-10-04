#!/bin/sh
# gate-upstream-watch.sh -- scripts/upstream-watch.sh, the daily check for a newer upstream
# Hermes, run against a stand-in `gh` that answers as GitHub would and records what the
# watcher asked of it. No network, no token.
#
#   gate-upstream-watch.sh             the watcher in scripts/
#   WATCH=/path gate-upstream-watch.sh another copy of it (teeth-upstream-watch.sh uses it)
#   gate-upstream-watch.sh --selftest  the checks it runs, for gate-scenarios-bound.sh
set -u
CHECKS='check_quiet_when_pinned_is_latest check_issue_when_upstream_is_newer check_no_second_issue check_quiet_when_pinned_is_ahead check_refuses_when_upstream_unreadable check_refuses_when_issues_unreadable'
if [ "${1:-}" = "--selftest" ]; then
	for c in $CHECKS; do echo "$c"; done
	exit 0
fi

HERE=$(cd "$(dirname "$0")" && pwd)
WATCH=${WATCH:-$HERE/upstream-watch.sh}
[ -f "$WATCH" ] || { echo "FAIL: measured nothing: no watcher at $WATCH"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# The stand-in. FAKE_LATEST is upstream's latest tag ('' reads as empty, FAIL makes the
# call fail), FAKE_LIST=FAIL makes listing the issues fail, and $T/titles holds the titles
# of issues that exist, one per line. Every call is appended to $T/calls, and an issue
# create also writes its body to $T/body.
cat > "$T/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "$GATE_T/calls"
case "$1 $2" in
	"api repos/"*)
		[ "$FAKE_LATEST" = FAIL ] && { echo "HTTP 502" >&2; exit 1; }
		printf '%s\n' "$FAKE_LATEST" ;;
	"issue list")
		[ "${FAKE_LIST:-}" = FAIL ] && { echo "HTTP 502" >&2; exit 1; }
		[ -f "$GATE_T/titles" ] && cat "$GATE_T/titles"; exit 0 ;;
	"issue create")
		while [ $# -gt 0 ]; do
			case "$1" in --body) printf '%s\n' "$2" > "$GATE_T/body"; shift ;; esac
			shift
		done
		echo "https://github.com/x/y/issues/1" ;;
	*) echo "stand-in gh: unexpected call: $*" >&2; exit 2 ;;
esac
GH
chmod 0755 "$T/bin/gh"

# The pin the watcher reads, so a case does not depend on what upstream.env says today.
cat > "$T/upstream.env" <<'ENV'
HERMES_VERSION=0.21.5
HERMES_TAG=v2026.9.24
ENV

fail=0
# $1 check, $2 upstream's latest, $3 titles that exist (may be empty)
run() {
	rm -f "$T/calls" "$T/body" "$T/titles"
	[ -n "$3" ] && printf '%s\n' "$3" > "$T/titles"
	OUT=$(GATE_T="$T" FAKE_LATEST="$2" PATH="$T/bin:$PATH" UPSTREAM_ENV="$T/upstream.env" \
		GITHUB_REPOSITORY=TAIPANBOX/hermes-openwrt sh "$WATCH" 2>&1)
	RC=$?
}
created() { n=0; [ -f "$T/calls" ] && n=$(grep -c '^issue create' "$T/calls"); echo "$n"; }
# A watcher that never asked upstream is quiet for the wrong reason.
asked() { [ -f "$T/calls" ] && grep -q '^api repos/NousResearch/hermes-agent/releases/latest' "$T/calls"; }
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1: $2"; printf '%s\n' "$OUT" | sed 's/^/  /'; fail=1; }

run check_quiet_when_pinned_is_latest v2026.9.24 ""
if [ "$RC" -eq 0 ] && asked && [ "$(created)" = 0 ]; then pass check_quiet_when_pinned_is_latest
else bad check_quiet_when_pinned_is_latest "exit $RC, $(created) issue(s) created"; fi

run check_issue_when_upstream_is_newer v2026.10.3 ""
if [ "$RC" -eq 0 ] && [ "$(created)" = 1 ] \
	&& grep '^issue create' "$T/calls" | grep -q 'v2026.10.3' \
	&& grep '^issue create' "$T/calls" | grep -q 'v2026.9.24' \
	&& grep -q 'both routers' "$T/body" 2>/dev/null; then
	pass check_issue_when_upstream_is_newer
else bad check_issue_when_upstream_is_newer "exit $RC, $(created) issue(s) created, or the title or body is wrong"; fi

run check_no_second_issue v2026.10.3 "Upstream Hermes v2026.10.3 is out (packaged: v2026.9.24)"
if [ "$RC" -eq 0 ] && asked && [ "$(created)" = 0 ]; then pass check_no_second_issue
else bad check_no_second_issue "exit $RC, $(created) issue(s) created for a release that already has one"; fi

run check_quiet_when_pinned_is_ahead v2026.9.21 ""
if [ "$RC" -eq 0 ] && asked && [ "$(created)" = 0 ]; then pass check_quiet_when_pinned_is_ahead
else bad check_quiet_when_pinned_is_ahead "exit $RC, $(created) issue(s) created for an older release"; fi

ok=1
for latest in FAIL ""; do
	run check_refuses_when_upstream_unreadable "$latest" ""
	{ [ "$RC" -ne 0 ] && [ "$(created)" = 0 ] && printf '%s\n' "$OUT" | grep -q 'cannot read upstream'; } || ok=0
done
if [ "$ok" = 1 ]; then pass check_refuses_when_upstream_unreadable
else bad check_refuses_when_upstream_unreadable "a failed or empty read did not fail with 'cannot read upstream', or created an issue"; fi

FAKE_LIST=FAIL; export FAKE_LIST
run check_refuses_when_issues_unreadable v2026.10.3 ""
unset FAKE_LIST
if [ "$RC" -ne 0 ] && [ "$(created)" = 0 ] && printf '%s\n' "$OUT" | grep -q 'cannot read the issues'; then
	pass check_refuses_when_issues_unreadable
else bad check_refuses_when_issues_unreadable "exit $RC, $(created) issue(s) created without knowing which exist"; fi

exit "$fail"
