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
#   1. builds both release lines for every architecture (slow: aarch64 is emulated)
#   2. signs the 25.12 packages and index with the EC key, the 24.10 index with usign
#   3. runs both feed gates against the result
#   4. commits the feed to the gh-pages branch and pushes it
#
# GitHub Pages serves that branch. The workflow no longer deploys, and the two signing
# secrets have been deleted from the repository.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

EC_KEY=${EC_KEY:-$ROOT/keys/hermes-openwrt.private.pem}
USIGN_KEY=${USIGN_KEY:-$ROOT/keys/hermes-openwrt.usign.sec}
SKIP_BUILD=${SKIP_BUILD:-0}

for k in "$EC_KEY" "$USIGN_KEY"; do
	[ -f "$k" ] || { echo "publish-feed.sh: missing signing key $k" >&2
		echo "  generate them once with: ./scripts/feed-keygen.sh" >&2; exit 1; }
done

if [ "$SKIP_BUILD" != 1 ]; then
	echo "==> building 25.12"
	EXTRA_ARCHES=aarch64_cortex-a53 ./package/hermes-agent/build-in-container.sh aarch64_generic
	./package/hermes-agent/build-in-container.sh x86_64
	./package/luci-app-hermes/build.sh
	echo "==> building 24.10"
	RELEASE=24.10.8 EXTRA_ARCHES=aarch64_cortex-a53 ./package/hermes-agent/build-in-container.sh aarch64_generic
	RELEASE=24.10.8 ./package/hermes-agent/build-in-container.sh x86_64
	FORMAT=ipk ./package/luci-app-hermes/build.sh
fi

echo "==> signing"
SIGN_KEY="$EC_KEY" ./scripts/build-feed.sh
SIGN_KEY="$USIGN_KEY" ./scripts/build-feed-opkg.sh

echo "==> gating what is about to be published"
# Both, and before the push rather than after. A feed is the one artefact where "we will
# notice if it is broken" is wrong: the router that notices is someone else's.
ARCH=x86_64 ./scripts/gate-feed.sh
ARCH=x86_64 ./scripts/gate-feed-opkg.sh

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
git -C "$WT" commit -q -m "feed: $(date -u +%Y-%m-%dT%H:%MZ), signed on a workstation"
# Force, because the branch is replaced rather than extended. This is the one place a
# force push is the correct operation and not a way out of a mistake.
git -C "$WT" push -qf origin HEAD:gh-pages
echo "==> published: https://taipanbox.github.io/hermes-openwrt/"
