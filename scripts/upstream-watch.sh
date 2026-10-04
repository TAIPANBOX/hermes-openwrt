#!/bin/sh
# upstream-watch.sh -- open one issue when upstream Hermes tags a release newer than the
# one package/upstream/upstream.env pins. Run daily by .github/workflows/upstream-watch.yml.
#
# It only notices. Moving the package is a reviewed change: a new upstream has to be
# built, pass every gate and run on both test routers before the feed carries it.
#
# Needs `gh` with a token that may read this repository's issues and open one
# (GH_TOKEN in the workflow). Fails, rather than passing, when upstream cannot be read:
# a watch that cannot see reports nothing, which is what a quiet week also looks like.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENV=${UPSTREAM_ENV:-$ROOT/package/upstream/upstream.env}
REPO=${GITHUB_REPOSITORY:-TAIPANBOX/hermes-openwrt}
UPSTREAM=NousResearch/hermes-agent

. "$ENV"
[ -n "${HERMES_TAG:-}" ] || { echo "upstream-watch: no HERMES_TAG in $ENV" >&2; exit 1; }

latest=$(gh api "repos/$UPSTREAM/releases/latest" --jq .tag_name) || latest=
if [ -z "$latest" ]; then
	echo "upstream-watch: cannot read upstream's latest release from $UPSTREAM" >&2
	exit 1
fi

# Upstream tags are CalVer (v2026.9.24), so version order is the order to compare by. A tag
# in another form would sort below the pin and silence this check for good, so it fails.
for t in "$latest" "$HERMES_TAG"; do
	echo "$t" | grep -Eq '^v[0-9]{4}(\.[0-9]+)+$' || {
		echo "upstream-watch: cannot compare '$t' with a vYEAR.MONTH.DAY tag; look at it by hand" >&2
		exit 1
	}
done
newest=$(printf '%s\n%s\n' "$HERMES_TAG" "$latest" | sort -V | tail -n 1)
if [ "$latest" = "$HERMES_TAG" ] || [ "$newest" = "$HERMES_TAG" ]; then
	echo "upstream-watch: upstream's latest is $latest; the package pins $HERMES_TAG. Nothing to do."
	exit 0
fi

prefix="Upstream Hermes $latest is out ("
title="${prefix}packaged: $HERMES_TAG)"
# Closed issues count too: a release someone decided to skip is not news again. The match is
# on the release alone, since the pin in an older issue's title may have moved since.
# Every title is read rather than searched for: the search index can lag an issue opened
# minutes ago, and a repository with this few issues reads them all in one call.
titles=$(gh issue list --repo "$REPO" --state all --limit 1000 --json title --jq '.[].title') || {
	echo "upstream-watch: cannot read the issues of $REPO, so cannot tell whether $latest has one" >&2
	exit 1
}
if printf '%s\n' "$titles" | cut -c1-${#prefix} | grep -F -x -q -- "$prefix"; then
	echo "upstream-watch: an issue for $latest already exists. Nothing to do."
	exit 0
fi

body="Upstream tagged [$latest](https://github.com/$UPSTREAM/releases/tag/$latest); this repository packages $HERMES_TAG (Hermes $HERMES_VERSION).

Changes between them: https://github.com/$UPSTREAM/compare/$HERMES_TAG...$latest

Before the feed carries it:

1. Pin it in \`package/upstream/upstream.env\`: version, tag, the commit the tag points at, and the checksum of that commit's archive.
2. Build, and run every gate and its teeth (\`gate-upstream.sh\` first: an excluded dependency upstream no longer resolves stops the build).
3. Run it on both routers, the Flint 2 and the Brume 2, recording each router's state first and restoring it after.
4. Re-measure the README's figures that depend on the agent (memory, flash, response times).
5. Publish the feed from a workstation.

Opened by \`scripts/upstream-watch.sh\`, which runs daily and never opens a second issue for the same release."

gh issue create --repo "$REPO" --title "$title" --body "$body"
echo "upstream-watch: opened an issue for $latest"
