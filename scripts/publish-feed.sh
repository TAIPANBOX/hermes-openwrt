#!/bin/sh
# publish-feed.sh -- build, sign and publish the feed from this machine.
#
# Signing does not happen in CI, on purpose.
#
# A signing key held as a repository secret is readable by anyone who can push a
# workflow to the default branch: GitHub masks secrets in logs, and masking is trivial to
# defeat on purpose. That is an acceptable trade for many projects and it is not one for
# this key, because there is no revocation. A router that has trusted the public half
# keeps trusting anything signed with the private half until a person logs in and deletes
# the file. Nothing published later can undo it.
#
# So CI builds every architecture and runs every gate, which is what CI is good at, and
# the signature is applied here, by a person, on a machine where the key lives and does
# not travel. Publishing then costs one command and a push.
#
# What this does
#
#   1. builds 25.12 for every architecture it serves (native on an arm64 workstation)
#   2. signs the packages and the index with the EC key
#   3. runs the feed gate against the result
#   4. commits the feed to the gh-pages branch and pushes it
#
# GitHub Pages serves that branch. The workflow no longer deploys, and the two signing
# secrets have been deleted from the repository.
#
# On macOS, run this from a checkout outside the home folder, for example a clone under
# /private/tmp, with EC_KEY pointing at the key there. Finder writes
# .DS_Store into directories while this script is building them, and this script refuses
# to publish a feed with one in it rather than fail on the router with a bare "file
# integrity error" the way an unswept .DS_Store already once did in a package build.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Refuse before anything else, including the key check below: signing and publishing a
# tree that is not exactly what main's own history holds ships something nobody could
# reproduce from the source, and a signature does not carry a commit identifier with it.
git fetch -q origin main
DIRTY=$(git status --porcelain)
[ -z "$DIRTY" ] || {
	echo "publish-feed.sh: the working tree is not clean; commit or stash first:" >&2
	echo "$DIRTY" >&2
	exit 1
}
PUBLISH_SHA=$(git rev-parse HEAD)
MAIN_SHA=$(git rev-parse origin/main)
[ "$PUBLISH_SHA" = "$MAIN_SHA" ] || {
	echo "publish-feed.sh: HEAD ($PUBLISH_SHA) is not origin/main ($MAIN_SHA)." >&2
	echo "publish-feed.sh: refusing to publish a commit that is not on main." >&2
	exit 1
}
PUBLISH_SHORT=$(git rev-parse --short "$PUBLISH_SHA")
echo "==> publishing commit $PUBLISH_SHA"

EC_KEY=${EC_KEY:-$ROOT/keys/hermes-openwrt.private.pem}
SKIP_BUILD=${SKIP_BUILD:-0}

for k in "$EC_KEY"; do
	[ -f "$k" ] || { echo "publish-feed.sh: missing signing key $k" >&2
		echo "  generate them once with: ./scripts/feed-keygen.sh" >&2; exit 1; }
done

if [ "$SKIP_BUILD" != 1 ]; then
	# The add-on is built after the base package for the same architecture, never
	# before: its build refuses without the base tree, because the one failure it can
	# have is a file the base already owns and that cannot be checked against a tree
	# that is not there.
	echo "==> building 25.12"
	EXTRA_ARCHES=aarch64_cortex-a53 ./package/hermes-agent/build-in-container.sh aarch64_generic
	EXTRA_ARCHES=aarch64_cortex-a53 ./package/hermes-agent-telegram/build-in-container.sh aarch64_generic
	./package/luci-app-hermes/build.sh
fi

echo "==> signing"
SIGN_KEY="$EC_KEY" ./scripts/build-feed.sh

echo "==> gating what is about to be published"
# Before the push rather than after. A feed is the one artefact where "we will notice if
# it is broken" is wrong: the router that notices is someone else's.
ARCH=aarch64_generic ./scripts/gate-feed.sh

# Finder again: a .DS_Store that crept into feed-out/ while it was being built would
# otherwise ship inside the published feed itself.
if find "$ROOT/feed-out" -name .DS_Store -print -quit | grep -q .; then
	echo "publish-feed.sh: .DS_Store found under feed-out/; refusing to publish:" >&2
	find "$ROOT/feed-out" -name .DS_Store >&2
	exit 1
fi

echo "==> publishing to gh-pages"
# A worktree rather than a branch switch, so an unfinished change in the working tree
# cannot end up in a published feed and the working tree is not disturbed by publishing.
WT=$(mktemp -d)
cleanup() {
	git worktree remove --force "$WT" >/dev/null 2>&1 || true
	rm -rf "$WT"
	# The scratch branch exists only inside the worktree; leaving it behind would make
	# the next run fail on a name that is already taken.
	git branch -qD _feed_publish >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A fresh orphan commit every time, force-pushed, so the branch is always exactly one
# commit deep.
#
# The alternative, committing on top of the previous feed, keeps every version of every
# package in the repository forever. This feed is about 170 MB and the individual
# packages are 56 MB each, which is over GitHub's recommended file size on its own; a
# dozen publishes would leave a repository nobody can clone. Nothing here needs history:
# what a router installs is whatever the feed currently serves, and the source that
# produced it is on main with its own history.
git worktree add -q --detach "$WT"
# A detached orphan rather than a named one: the branch name is only needed at push
# time, and checking out a name that already exists locally fails. The push below names
# the destination explicitly instead.
git -C "$WT" checkout -q --orphan _feed_publish
git -C "$WT" rm -rq --cached . 2>/dev/null || true
find "$WT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +

cp -R "$ROOT/feed-out/." "$WT/"
# Pages runs Jekyll otherwise, which ignores files whose names start with an underscore
# and can mangle what it takes for a template. A feed is bytes, not a site to build.
touch "$WT/.nojekyll"

git -C "$WT" add -A
git -C "$WT" commit -q -m "feed: $(date -u +%Y-%m-%dT%H:%MZ) from $PUBLISH_SHORT, signed on a workstation"
# Force, because the branch is replaced rather than extended. This is the one place a
# force push is the correct operation and not a way out of a mistake.
git -C "$WT" push -qf origin HEAD:gh-pages
echo "==> published: https://taipanbox.github.io/hermes-openwrt/"
