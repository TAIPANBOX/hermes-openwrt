#!/bin/sh
# gate-upstream-watch.sh -- scripts/upstream-watch.sh, the daily check for a newer upstream
# Hermes, run against a stand-in `gh` that answers as GitHub would and records what the
# watcher asked of it. No network, no token.
#
#   gate-upstream-watch.sh             the watcher in scripts/
#   WATCH=/path gate-upstream-watch.sh another copy of it (teeth-upstream-watch.sh uses it)
#   gate-upstream-watch.sh --selftest  the checks it runs, for gate-scenarios-bound.sh
set -u
CHECKS='check_quiet_when_pinned_is_latest check_issue_when_upstream_is_newer check_no_second_issue check_quiet_when_pinned_is_ahead check_refuses_when_upstream_unreadable check_refuses_when_issues_unreadable check_refuses_unrecognised_tag check_issue_when_semver_after_date_pin check_quiet_when_same_version_new_scheme check_mixed_schemes_order_by_version'
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
# The stand-in answers as GitHub would, arguments included, so a watcher that drops one
# gets what the real `gh` would give it. FAKE_LATEST is upstream's latest tag ('' reads as
# empty, FAIL makes the call fail) and FAKE_NAME its release name; asked with the watcher's
# --jq they come back one per line, `--jq .tag_name` gives the tag alone, without any --jq
# the release comes back as JSON, as it does from GitHub, and any other --jq fails. FAKE_LIST=FAIL makes listing the issues fail; $T/titles
# holds the issues that exist, one "open|closed<TAB>title" per line, and without
# `--state all` only the open ones are listed. Without `--repo` the call fails. Every
# call is appended to $T/calls; an issue create writes its title to $T/title and its
# body to $T/body.
cat > "$T/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "$GATE_T/calls"
has() { case " $ARGS " in *" $1 "*) return 0 ;; esac; return 1; }
ARGS="$*"
case "$1 $2" in
	"api repos/"*)
		[ "$FAKE_LATEST" = FAIL ] && { echo "HTTP 502" >&2; exit 1; }
		if has '--jq .tag_name, (.name // "")'; then printf '%s\n%s\n' "$FAKE_LATEST" "$FAKE_NAME"
		elif has "--jq .tag_name"; then printf '%s\n' "$FAKE_LATEST"
		elif has "--jq"; then echo "stand-in gh: unexpected --jq: $*" >&2; exit 1
		else printf '{"tag_name":"%s","name":"%s","assets":[{"download_count":%s}]}\n' "$FAKE_LATEST" "$FAKE_NAME" "$$"; fi ;;
	"issue list")
		has "--repo $EXPECT_REPO" || { echo "stand-in gh: no --repo $EXPECT_REPO" >&2; exit 1; }
		[ "${FAKE_LIST:-}" = FAIL ] && { echo "HTTP 502" >&2; exit 1; }
		[ -f "$GATE_T/titles" ] || exit 0
		if has "--state all"; then cut -f2 "$GATE_T/titles"; else grep '^open	' "$GATE_T/titles" | cut -f2; fi ;;
	"issue create")
		has "--repo $EXPECT_REPO" || { echo "stand-in gh: no --repo $EXPECT_REPO" >&2; exit 1; }
		while [ $# -gt 0 ]; do
			case "$1" in
				--body) printf '%s\n' "$2" > "$GATE_T/body"; shift ;;
				--title) printf '%s\n' "$2" > "$GATE_T/title"; shift ;;
			esac
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

# A pin other than the default one, for the cases that need it: $1 version, $2 tag.
pin() { printf 'HERMES_VERSION=%s\nHERMES_TAG=%s\n' "$1" "$2" > "$T/pin.env"; PIN="$T/pin.env"; }
unpin() { PIN="$T/upstream.env"; }
unpin

# Upstream's release names, as upstream writes them: a date tag's release names the version
# it carries ("Hermes Agent v0.21.5 (v2026.9.24)"), a vX.Y.Z tag's release names just that.
named() { case $1 in v[0-9][0-9][0-9][0-9].*) echo "Hermes Agent v$2 ($1)" ;; *) echo "Hermes Agent $1" ;; esac; }

fail=0
# $1 check, $2 upstream's latest tag, $3 titles that exist (may be empty), $4 the release's
# name (default: the name upstream would give $2, which needs $5, the version a date tag carries)
run() {
	rm -f "$T/calls" "$T/body" "$T/title" "$T/titles"
	[ -n "$3" ] && printf '%s\n' "$3" > "$T/titles"
	if [ $# -ge 4 ]; then rname=$4; else rname=$(named "$2" "${5:-}"); fi
	OUT=$(GATE_T="$T" EXPECT_REPO=TAIPANBOX/hermes-openwrt FAKE_LATEST="$2" FAKE_NAME="$rname" PATH="$T/bin:$PATH" UPSTREAM_ENV="$PIN" \
		GITHUB_REPOSITORY=TAIPANBOX/hermes-openwrt sh "$WATCH" 2>&1)
	RC=$?
}
created() { n=0; [ -f "$T/calls" ] && n=$(grep -c '^issue create' "$T/calls"); echo "$n"; }
# A watcher that never asked upstream is quiet for the wrong reason.
asked() { [ -f "$T/calls" ] && grep -q '^api repos/NousResearch/hermes-agent/releases/latest' "$T/calls"; }
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1: $2"; printf '%s\n' "$OUT" | sed 's/^/  /'; fail=1; }

run check_quiet_when_pinned_is_latest v2026.9.24 "" "Hermes Agent v0.21.5 (v2026.9.24)"
if [ "$RC" -eq 0 ] && asked && [ "$(created)" = 0 ]; then pass check_quiet_when_pinned_is_latest
else bad check_quiet_when_pinned_is_latest "exit $RC, $(created) issue(s) created"; fi

run check_issue_when_upstream_is_newer v2026.10.3 "" "Hermes Agent v0.21.6 (v2026.10.3)"
if [ "$RC" -eq 0 ] && [ "$(created)" = 1 ] \
	&& grep -q 'v2026.10.3' "$T/title" 2>/dev/null \
	&& grep -q 'v2026.9.24' "$T/title" 2>/dev/null \
	&& grep -q 'both routers' "$T/body" 2>/dev/null; then
	pass check_issue_when_upstream_is_newer
else bad check_issue_when_upstream_is_newer "exit $RC, $(created) issue(s) created, or the title or body is wrong"; fi

TAB=$(printf '\t')
ok=1
# open, closed, and closed with the pin moved on since (the title names the old pin)
for existing in "open${TAB}Upstream Hermes v2026.10.3 is out (packaged: v2026.9.24)" \
                "closed${TAB}Upstream Hermes v2026.10.3 is out (packaged: v2026.9.24)" \
                "closed${TAB}Upstream Hermes v2026.10.3 is out (packaged: v2026.9.21)"; do
	run check_no_second_issue v2026.10.3 "$existing" "Hermes Agent v0.21.6 (v2026.10.3)"
	{ [ "$RC" -eq 0 ] && asked && [ "$(created)" = 0 ]; } || { ok=0; echo "  with [$existing]: exit $RC, $(created) created"; }
done
if [ "$ok" = 1 ]; then pass check_no_second_issue
else bad check_no_second_issue "a release that already has an issue got another"; fi

run check_quiet_when_pinned_is_ahead v2026.9.21 "" "Hermes Agent v0.21.4 (v2026.9.21)"
if [ "$RC" -eq 0 ] && asked && [ "$(created)" = 0 ]; then pass check_quiet_when_pinned_is_ahead
else bad check_quiet_when_pinned_is_ahead "exit $RC, $(created) issue(s) created for an older release"; fi

ok=1
for latest in FAIL ""; do
	run check_refuses_when_upstream_unreadable "$latest" "" ""
	{ [ "$RC" -ne 0 ] && [ "$(created)" = 0 ] && printf '%s\n' "$OUT" | grep -q 'cannot read upstream'; } || ok=0
done
if [ "$ok" = 1 ]; then pass check_refuses_when_upstream_unreadable
else bad check_refuses_when_upstream_unreadable "a failed or empty read did not fail with 'cannot read upstream', or created an issue"; fi

FAKE_LIST=FAIL; export FAKE_LIST
run check_refuses_when_issues_unreadable v2026.10.3 "" "Hermes Agent v0.21.6 (v2026.10.3)"
unset FAKE_LIST
if [ "$RC" -ne 0 ] && [ "$(created)" = 0 ] && printf '%s\n' "$OUT" | grep -q 'cannot read the issues'; then
	pass check_refuses_when_issues_unreadable
else bad check_refuses_when_issues_unreadable "exit $RC, $(created) issue(s) created without knowing which exist"; fi

# Each refusal is one case: upstream's tag and its release name, and the pin when it is the
# pin that cannot be ordered. Every one has to fail, say so, and open nothing.
ok=1
for c in "nightly|Hermes Agent nightly|" \
         "v0.22.0-rc1|Hermes Agent v0.22.0-rc1|" \
         "v2026.10.3|Hermes Agent October build|" \
         "v2026.10.3||" \
         "v0.21.6|Hermes Agent v0.21.7|" \
         "v0.21.6|Hermes Agent v0.21.6|0.21 v2026.9.24" \
         "v0.21.6|Hermes Agent v0.21.6|0.21.5 v0.21.4"; do
	tag=${c%%|*}; rest=${c#*|}; rname=${rest%%|*}; p=${rest#*|}
	if [ -n "$p" ]; then pin ${p% *} ${p#* }; else unpin; fi
	run check_refuses_unrecognised_tag "$tag" "" "$rname"
	{ [ "$RC" -ne 0 ] && [ "$(created)" = 0 ] && printf '%s\n' "$OUT" | grep -q 'cannot compare'; } \
		|| { ok=0; echo "  tag $tag named [$rname], pin [${p:-default}]: exit $RC, $(created) created"; }
done
unpin
if [ "$ok" = 1 ]; then pass check_refuses_unrecognised_tag
else bad check_refuses_unrecognised_tag "a tag or a version it cannot order did not fail with 'cannot compare', or created an issue"; fi

# The defect of 2026-10-08: upstream moved from date tags to vX.Y.Z tags with 0.21.6.
run check_issue_when_semver_after_date_pin v0.21.6 ""
if [ "$RC" -eq 0 ] && [ "$(created)" = 1 ] \
	&& grep -q 'v0.21.6' "$T/title" 2>/dev/null \
	&& grep -q 'v2026.9.24' "$T/title" 2>/dev/null \
	&& grep -q 'both routers' "$T/body" 2>/dev/null; then
	pass check_issue_when_semver_after_date_pin
else bad check_issue_when_semver_after_date_pin "exit $RC, $(created) issue(s) created for v0.21.6 over a pin of 0.21.5 at v2026.9.24"; fi

run check_quiet_when_same_version_new_scheme v0.21.5 ""
if [ "$RC" -eq 0 ] && asked && [ "$(created)" = 0 ]; then pass check_quiet_when_same_version_new_scheme
else bad check_quiet_when_same_version_new_scheme "exit $RC, $(created) issue(s) created for the pinned version under another tag"; fi

# pin version, pin tag, upstream tag, the version upstream's release carries, issues expected
ok=1
for c in "0.21.6 v0.21.6 v2026.9.24 0.21.5 0" \
         "0.21.6 v0.21.6 v2026.11.2 0.22.0 1" \
         "0.21.6 v0.21.6 v0.21.10 - 1" \
         "0.21.6 v0.21.6 v0.21.5 - 0" \
         "0.21.5 v2026.9.24 v2026.10.3 0.21.5 0" \
         "0.21.5 v2026.9.24 v2026.9.21 0.21.4 0" \
         "0.21.5 v2026.9.24 v1.0.0 - 1" \
         "0.21.5 v2026.9.24 v0.9.30 - 0"; do
	set -- $c
	pin "$1" "$2"
	run check_mixed_schemes_order_by_version "$3" "" "$(named "$3" "$4")"
	{ [ "$RC" -eq 0 ] && asked && [ "$(created)" = "$5" ]; } \
		|| { ok=0; echo "  pin $1 at $2, upstream $3 ($4): exit $RC, $(created) created, $5 expected"; }
done
unpin
if [ "$ok" = 1 ]; then pass check_mixed_schemes_order_by_version
else bad check_mixed_schemes_order_by_version "a release was ordered by its tag rather than by the version it carries"; fi

exit "$fail"
