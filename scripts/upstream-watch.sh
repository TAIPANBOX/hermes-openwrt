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

# Upstream's latest release: its tag on the first line, its name on the second.
rel=$(gh api "repos/$UPSTREAM/releases/latest" --jq '.tag_name, (.name // "")') || rel=
latest=$(printf '%s\n' "$rel" | sed -n 1p)
name=$(printf '%s\n' "$rel" | sed -n 2p)
if [ -z "$latest" ]; then
	echo "upstream-watch: cannot read upstream's latest release from $UPSTREAM" >&2
	exit 1
fi

# Releases are compared by the Hermes version they carry, not by their tags. Upstream tagged
# vYEAR.MONTH.DAY up to 0.21.5 (v2026.9.24) and vX.Y.Z from 0.21.6, and by tag order every
# date sorts above every version, which would silence this check for good. So:
#   a vX.Y.Z tag (X under four digits, so never a year) is version X.Y.Z;
#   a vYEAR.MONTH.DAY tag is the version its release name gives, "Hermes Agent v0.21.5
#   (v2026.9.24)", the form every date-tagged release upstream published carries;
#   the pin is HERMES_VERSION, which gate-upstream.sh checks against the built
#   `hermes --version`, so it is the version the package actually carries.
# Anything it cannot read that way fails: a guess that sorts low goes quiet for good.
refuse() { echo "upstream-watch: cannot compare $1; look at it by hand" >&2; exit 1; }
SEMVER_TAG='^v[0-9]{1,3}\.[0-9]+\.[0-9]+$'
DATE_TAG='^v[0-9]{4}(\.[0-9]+)+$'
named=$(printf '%s\n' "$name" | sed -nE 's/^Hermes Agent v([0-9]+\.[0-9]+\.[0-9]+)( .*)?$/\1/p')
if printf '%s\n' "$latest" | grep -Eq "$SEMVER_TAG"; then
	version=${latest#v}
	if [ -n "$named" ] && [ "$named" != "$version" ]; then
		refuse "'$latest': its release is named '$name', another version"
	fi
elif printf '%s\n' "$latest" | grep -Eq "$DATE_TAG"; then
	[ -n "$named" ] || refuse "'$latest': a date tag whose release name '$name' gives no Hermes version"
	version=$named
else
	refuse "'$latest', a tag neither vX.Y.Z nor vYEAR.MONTH.DAY"
fi
printf '%s\n' "${HERMES_VERSION:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
	|| refuse "the pinned HERMES_VERSION '${HERMES_VERSION:-}', which is not X.Y.Z"
if printf '%s\n' "$HERMES_TAG" | grep -Eq "$SEMVER_TAG" && [ "$HERMES_TAG" != "v$HERMES_VERSION" ]; then
	refuse "the pin: tag $HERMES_TAG is not version $HERMES_VERSION"
fi

# newer A B: version A is later than B, field by field as numbers (0.21.10 after 0.21.6).
newer() {
	awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, ".")
		for (i = 1; i <= 3; i++) if (x[i] + 0 != y[i] + 0) exit !(x[i] + 0 > y[i] + 0)
		exit 1 }'
}
if ! newer "$version" "$HERMES_VERSION"; then
	echo "upstream-watch: upstream's latest is $latest (Hermes $version); the package pins $HERMES_TAG (Hermes $HERMES_VERSION). Nothing to do."
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

body="Upstream released [${name:-$latest}](https://github.com/$UPSTREAM/releases/tag/$latest), tag $latest, Hermes $version; this repository packages Hermes $HERMES_VERSION, tag $HERMES_TAG.

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
