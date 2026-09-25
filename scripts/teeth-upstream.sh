#!/bin/sh
# teeth-upstream.sh -- every gate-upstream check fails on its own fault, and only then.
#
# Each fault is planted in a fresh copy of the assembled tree and stands for a real way
# the package could go wrong:
#
#   1 the recorded commit is not the pinned one        a build from another commit
#   2 the agent's metadata says 0.21.4                 a stale or mixed tree
#   3 one library is not at its uv.lock version        resolution floated past the lock
#   4 nemo-relay is back in the package                the exclusion stopped working
#   5 the Relay fallback raises instead                upstream dropped its no-op host
#   6 the env fragment forgets the locales             raw i18n keys on the router
#   7 the Telegram plugin manifest is missing          a wheel built without package data
#
# Then the untouched copy must pass all seven, and a missing tree must be reported as
# "measured nothing", not as a pass.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
LINE=${RELEASE%%.*}.$(echo "$RELEASE" | cut -d. -f2)
SRC_TREE="$ROOT/build/$LINE/$ARCH/tree"
[ -d "$SRC_TREE/usr/lib/hermes-agent/site-packages" ] || {
	echo "teeth-upstream: no assembled tree at $SRC_TREE; build it first" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/teeth-upstream.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SITE=usr/lib/hermes-agent/site-packages

fresh() { rm -rf "$WORK/tree"; cp -R "$SRC_TREE" "$WORK/tree"; }
run_gate() { TREE="$WORK/tree" ARCH="$ARCH" RELEASE="$RELEASE" "$ROOT/scripts/gate-upstream.sh" >"$WORK/out" 2>&1; }

# expect_red <check> <description>: the gate must fail, and fail on <check>.
expect_red() {
	if run_gate; then
		cat "$WORK/out"; echo "teeth-upstream: $2 did not make the gate fail" >&2; exit 1
	fi
	if ! grep -q "^FAIL \[[0-9]/7\] $1" "$WORK/out"; then
		cat "$WORK/out"; echo "teeth-upstream: $2 failed the gate, but not on $1" >&2; exit 1
	fi
	echo "teeth ok: $2 -> $1"
}

n=0
fresh; sed -i.bak 's/^commit=.*/commit=0000000000000000000000000000000000000000/' "$WORK/tree/usr/lib/hermes-agent/upstream"
expect_red check_upstream_pinned "recorded commit changed"; n=$((n + 1))

fresh; d=$(ls -d "$WORK/tree/$SITE"/hermes_agent-*.dist-info)
mv "$d" "$WORK/tree/$SITE/hermes_agent-0.21.4.dist-info"
expect_red check_version_is_upstream "agent metadata says 0.21.4"; n=$((n + 1))

fresh; meta=$(ls "$WORK/tree/$SITE"/pyyaml-*.dist-info/METADATA)
sed -i.bak 's/^Version: .*/Version: 5.4.1/' "$meta"
expect_red check_versions_follow_lock "pyyaml not at its locked version"; n=$((n + 1))

fresh; mkdir -p "$WORK/tree/$SITE/nemo_relay" "$WORK/tree/$SITE/nemo_relay-0.8.3.dist-info"
printf 'Metadata-Version: 2.1\nName: nemo-relay\nVersion: 0.8.3\n' > "$WORK/tree/$SITE/nemo_relay-0.8.3.dist-info/METADATA"
expect_red check_excluded_absent "nemo-relay back in the package"; n=$((n + 1))

fresh; f="$WORK/tree/$SITE/agent/relay_runtime.py"
grep -q 'host = NoopRelayRuntime(profile_key=key, reason=str(exc))' "$f" || {
	echo "teeth-upstream: the fallback line moved in relay_runtime.py; retarget fault 5" >&2; exit 1; }
sed -i.bak 's/host = NoopRelayRuntime(profile_key=key, reason=str(exc))/raise/' "$f"
rm -f "$WORK/tree/$SITE/agent/__pycache__"/relay_runtime.*.pyc
expect_red check_relay_falls_back "the Relay fallback raises"; n=$((n + 1))

fresh; grep -q HERMES_BUNDLED_LOCALES "$WORK/tree/usr/lib/hermes-agent/hermes-env" || {
	echo "teeth-upstream: hermes-env no longer names HERMES_BUNDLED_LOCALES; retarget fault 6" >&2; exit 1; }
sed -i.bak '/HERMES_BUNDLED_LOCALES/d' "$WORK/tree/usr/lib/hermes-agent/hermes-env"
expect_red check_assets_resolve "env fragment forgets the locales"; n=$((n + 1))

fresh; rm -f "$WORK/tree/$SITE/plugins/platforms/telegram"/plugin.y*ml
expect_red check_platform_plugins_ship "Telegram plugin manifest missing"; n=$((n + 1))

# The untouched tree passes: faults that fail a gate which fails anyway prove nothing.
fresh
run_gate || { cat "$WORK/out"; echo "teeth-upstream: the untouched tree fails the gate" >&2; exit 1; }
grep -q '^gate-upstream: all 7 checks passed' "$WORK/out" || { cat "$WORK/out"; exit 1; }
echo "teeth ok: the untouched tree passes"

# And a missing subject is "measured nothing", never a pass.
if TREE="$WORK/none" ARCH="$ARCH" RELEASE="$RELEASE" "$ROOT/scripts/gate-upstream.sh" >"$WORK/out" 2>&1; then
	cat "$WORK/out"; echo "teeth-upstream: a missing tree passed the gate" >&2; exit 1
fi
grep -q 'measured nothing' "$WORK/out" || { cat "$WORK/out"; exit 1; }
echo "teeth ok: a missing tree is measured nothing"

echo "teeth-upstream: $n faults on 7 checks"
