#!/bin/sh
# Assemble the file tree for the hermes-agent-telegram OpenWrt package.
#
# What this package is, and why it is separate
#
# The Telegram platform's CODE already ships inside hermes-agent: upstream's wheel
# carries plugins/platforms/telegram/ alongside every other platform. What it does not
# carry is the client library. So this is not a feature package, it is a dependency
# delta, and it installs into the base package's own private site-packages.
#
# Measured 2026-09-08 inside openwrt/rootfs aarch64_generic, on both 25.12.4 (CPython
# 3.13) and 24.10.8 (CPython 3.11): adding python-telegram-bot[webhooks] to the router
# profile adds exactly two distributions, python-telegram-bot and tornado, and changes
# the version of nothing already present. Two, against the base package's 69.
#
# Why the contents are computed rather than listed
#
# Writing "python-telegram-bot and tornado" here would be correct today and silently
# wrong the first time upstream moves its pin. Two packages owning one file is a hard
# error in apk and a corrupted install in opkg, and the file that would collide is never
# the one anybody looks at. So the set is derived on every build by files/delta.py,
# which resolves the base profile and the base profile plus Telegram and subtracts.
#
# Why tornado is kept even though the adapter polls
#
# tornado is python-telegram-bot's webhook server and nothing else. Polling is the right
# default behind NAT and is what the adapter does. But a router is the one machine in
# the house that plausibly HAS a public address, which makes webhook mode more useful
# here than on a laptop, and the wheel is small. Dropping it would save little and
# would turn "switch to webhooks" into an error a user cannot fix from LuCI.
set -eu

usage() {
	echo "usage: build.sh <apk-arch> <staging-dir> [base-tree]" >&2
	echo "  base-tree: the assembled hermes-agent tree, checked for file collisions" >&2
	exit 2
}

ARCH=${1:?$(usage)}
OUT=${2:?$(usage)}
BASE_TREE=${3:-}

HERMES_VERSION=${HERMES_VERSION:-0.19.0}
# Must match what the base package was built with, or the resolution below describes a
# base tree that is not the one on the router.
EXTRAS=${EXTRAS:-cron,mcp}

SRC=$(cd "$(dirname "$0")" && pwd)
SITE="$OUT/usr/lib/hermes-agent/site-packages"

# Same guard as the base package. A tree resolved by a glibc pip is a package that fails
# only on the router, at import time, in front of a user.
python3 "$SRC/files/musl-guard.py" || exit 1

echo "build.sh: hermes-agent-telegram for $ARCH on $(python3 -V 2>&1)"
rm -rf "$OUT"
mkdir -p "$SITE" "$OUT/usr/lib/hermes-agent"

# ---- 1. what must this package carry ----
DELTA="$OUT/usr/lib/hermes-agent/telegram.manifest"
python3 "$SRC/files/delta.py" "$HERMES_VERSION" "$EXTRAS" > "$DELTA"
chmod 0644 "$DELTA"
sed 's/^/build.sh:   ships /' "$DELTA"

# ---- 2. install exactly that, and nothing it would drag behind it ----
# --no-deps because the delta IS the closure: it was computed as one. Letting pip
# resolve again here would pull the entire base tree into this package.
# shellcheck disable=SC2046
python3 -m pip install \
	--quiet --no-cache-dir --disable-pip-version-check --root-user-action=ignore \
	--target "$SITE" \
	--only-binary=:all: \
	--no-deps \
	$(cat "$DELTA")

# ---- 3. the same trimming and precompiling the base package does ----
find "$SITE" -type d \( -name tests -o -name test -o -name docs -o -name examples \) \
	-exec rm -rf {} + 2>/dev/null || true
find "$SITE" -name '*.pyi' -delete 2>/dev/null || true
# Ship the bytecode. Not merely a speed matter: with PYTHONDONTWRITEBYTECODE=1 in the
# init script, a module that arrives without its .pyc is re-parsed on every start, and
# with that variable unset it writes into a directory the package manager does not own,
# which is how `apk del` came to leave 193 MB behind once already.
python3 -m compileall -q -j 0 "$SITE" >/dev/null 2>&1 || true

# ---- 4. refuse to ship a file the base package already owns ----
#
# The check the whole design rests on. apk refuses such an install outright; opkg
# overwrites, leaving the base package's manifest pointing at bytes it did not write, so
# removing the ADD-ON later deletes a file the BASE needs. Neither is visible until
# somebody installs both, which is to say: not here, and not in CI, but on a router.
if [ -z "$BASE_TREE" ] || [ ! -d "$BASE_TREE" ]; then
	# Not a warning. A warning is a line in a log nobody reads, and what it would be
	# warning about is the one failure this package can have.
	echo "build.sh: no base tree at '${BASE_TREE:-<unset>}', so collisions cannot be" >&2
	echo "build.sh: checked, and this package's whole risk is a collision. Refusing." >&2
	exit 1
fi

( cd "$OUT" && find . -type f | sort ) > /tmp/ours.txt
( cd "$BASE_TREE" && find . -type f | sort ) > /tmp/theirs.txt
OURS=$(wc -l < /tmp/ours.txt | tr -d ' ')
THEIRS=$(wc -l < /tmp/theirs.txt | tr -d ' ')

# Both lists are unique by construction, so a line appearing twice in the concatenation
# appears once in each: that is the intersection.
#
# This was `comm -12` until 2026-09-08, when a build printed "no collision (9037 base
# files checked)" on a rootfs whose busybox has no comm at all. comm failed, wrote
# nothing, `grep -q .` found nothing in the nothing, and the check reported a pass
# having measured zero files. sort and uniq are in every busybox. The count assertions
# below exist so that a future missing tool cannot repeat the trick quietly.
[ "$OURS" -gt 0 ]   || { echo "build.sh: the assembled tree has no files at all" >&2; exit 1; }
[ "$THEIRS" -gt 0 ] || { echo "build.sh: the base tree at $BASE_TREE has no files" >&2; exit 1; }

cat /tmp/ours.txt /tmp/theirs.txt | sort | uniq -d > /tmp/both.txt
if [ -s /tmp/both.txt ]; then
	echo "build.sh: hermes-agent already owns these files:" >&2
	head -20 /tmp/both.txt | sed 's/^/build.sh:   /' >&2
	echo "build.sh: $(wc -l < /tmp/both.txt | tr -d ' ') in total. Two OpenWrt packages" >&2
	echo "build.sh: cannot own one file: apk refuses the install, opkg overwrites and" >&2
	echo "build.sh: then removing this package deletes a file the base still needs." >&2
	exit 1
fi
echo "build.sh: no collision: $OURS files against the base package's $THEIRS"

echo "build.sh: tree assembled at $OUT ($(du -sh "$OUT" | cut -f1))"
echo "build.sh: $(find "$SITE" -maxdepth 1 -name '*.dist-info' | wc -l | tr -d ' ') python packages"
