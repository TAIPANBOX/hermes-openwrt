#!/bin/sh
# gate-upstream.sh -- the package carries the pinned upstream Hermes, as upstream locks it,
# without the two parts the router package leaves out, and with everything upstream ships
# beside the wheel found where the package put it.
#
# Invariant (CLAUDE.md 17):
#
#   "hermes-agent is built from the upstream commit and archive checksum that
#   package/upstream/upstream.env pins, reports that version, ships every library at the
#   version upstream's uv.lock names at that commit, ships neither nemo-relay nor
#   pillow-heif, falls back to upstream's no-op Relay host without them, finds its bundled
#   skills, optional skills, locales and MCP catalogue under /usr/share/hermes-agent, and
#   ships the platform plugins, Telegram among them."
#
# Why this reads the assembled TREE and not the .apk
#
# gate-package.sh already installs the .apk and proves it installs, runs and removes. What
# this gate asserts is about the contents, and scripts/teeth-upstream.sh has to be able to
# plant a fault in them; a tree copy is one `cp`, a faulted .apk is a second packaging
# run. The tree is laid over / of a real OpenWrt rootfs, so /usr/bin/hermes, its env
# fragment and the paths it names are exactly the ones a router has.
set -eu

CHECKS='check_upstream_pinned check_version_is_upstream check_versions_follow_lock check_excluded_absent check_relay_falls_back check_assets_resolve check_platform_plugins_ship'

if [ "${1:-}" = "--selftest" ]; then
	n=0
	for c in $CHECKS; do echo "$c"; n=$((n + 1)); done
	[ "$n" -gt 0 ] || { echo "measured nothing" >&2; exit 1; }
	exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
case "$ARCH" in
	x86_64) IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:x86-64-$RELEASE} ;;
	*)      IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:$ARCH-$RELEASE} ;;
esac
PLATFORM=${PLATFORM:-linux/$ARCH}
LINE=${LINE:-${RELEASE%%.*}.$(echo "$RELEASE" | cut -d. -f2)}
TREE=${TREE:-$ROOT/build/$LINE/$ARCH/tree}
UPSTREAM_ENV=${UPSTREAM_ENV:-$ROOT/package/upstream/upstream.env}

# A gate whose subject is gone must say so, not pass: a missing tree would otherwise lay
# nothing over the rootfs and every "not present" check would hold trivially.
if [ ! -f "$TREE/usr/bin/hermes" ] || [ ! -d "$TREE/usr/lib/hermes-agent/site-packages" ]; then
	echo "FAIL: measured nothing: no assembled tree at $TREE"
	echo "      build it: RELEASE=$RELEASE ./package/hermes-agent/build-in-container.sh $ARCH"
	exit 1
fi
. "$UPSTREAM_ENV"

# The archive the pin names, for the lock file. fetch.sh verifies its checksum, so the
# lock read below is upstream's at that commit and not whatever a cache holds.
ARCHIVE=$("$ROOT/package/upstream/fetch.sh")

echo "-- gate-upstream: $TREE on $IMAGE ($PLATFORM), pin $HERMES_VERSION $HERMES_COMMIT --"

# ---- 1. built from the pinned commit ----
# Host side: the recorded provenance must equal the pin, field by field.
REC="$TREE/usr/lib/hermes-agent/upstream"
[ -f "$REC" ] || { echo "FAIL [1/7] check_upstream_pinned: the package records no upstream at $REC"; exit 1; }
for kv in "version=$HERMES_VERSION" "tag=$HERMES_TAG" "commit=$HERMES_COMMIT" \
          "archive_sha256=$HERMES_TARBALL_SHA256" "excluded=$HERMES_EXCLUDE"; do
	grep -qxF "$kv" "$REC" || {
		echo "FAIL [1/7] check_upstream_pinned: $REC lacks '$kv'"; sed 's/^/      /' "$REC"; exit 1; }
done
echo "PASS [1/7] check_upstream_pinned"

# -i is load-bearing: without it `sh -s` reads an empty stdin, nothing runs, and the
# container exits 0 having checked nothing.
docker run --rm -i --platform "$PLATFORM" \
	-v "$TREE:/tree:ro" -v "$ARCHIVE:/archive.tar.gz:ro" \
	-e HERMES_VERSION="$HERMES_VERSION" -e HERMES_EXCLUDE="$HERMES_EXCLUDE" \
	"$IMAGE" /bin/sh -s <<'CONTAINER'
set -eu
fail() { echo "FAIL $1: $2"; exit 1; }
mkdir -p /var/lock /var/run /var/state
apk update -q >/dev/null 2>&1
apk add -q python3 bash >/dev/null 2>&1
cp -a /tree/. /
SITE=/usr/lib/hermes-agent/site-packages
export HERMES_HOME=/tmp/hermes-home
mkdir -p "$HERMES_HOME"
# Everything below runs through the launcher's own environment, so a variable the
# launcher forgets is a variable this gate misses too.
hpy() { ( . /usr/lib/hermes-agent/hermes-env; PYTHONPATH=$SITE PYTHONDONTWRITEBYTECODE=1 HERMES_DISABLE_LAZY_INSTALLS=1 python3 -c "$1" ); }

# ---- 2. the version is the pinned one ----
out=$(/usr/bin/hermes --version 2>&1) || { echo "$out"; fail "[2/7] check_version_is_upstream" "hermes --version exited non-zero"; }
echo "$out" | grep -q "v$HERMES_VERSION" || { echo "$out"; fail "[2/7] check_version_is_upstream" "hermes --version does not report v$HERMES_VERSION"; }
ls -d "$SITE/hermes_agent-$HERMES_VERSION.dist-info" >/dev/null 2>&1 || fail "[2/7] check_version_is_upstream" "no hermes_agent-$HERMES_VERSION.dist-info"
[ "$(ls -d "$SITE"/hermes_agent-*.dist-info | wc -l)" -eq 1 ] || fail "[2/7] check_version_is_upstream" "more than one hermes_agent dist-info"
echo "PASS [2/7] check_version_is_upstream"

# ---- 3. every library at uv.lock's version ----
mkdir -p /tmp/src && tar xzf /archive.tar.gz -C /tmp/src
LOCK=$(ls /tmp/src/*/uv.lock)
python3 - "$SITE" "$LOCK" <<'PY' || fail "[3/7] check_versions_follow_lock" "see above"
import re, sys, tomllib
from pathlib import Path
site, lock = Path(sys.argv[1]), sys.argv[2]
canon = lambda n: re.sub(r"[-_.]+", "-", n).lower()
locked = {}
for p in tomllib.load(open(lock, "rb"))["package"]:
    locked.setdefault(canon(p["name"]), set()).add(p["version"])
shipped, bad = 0, []
for di in site.glob("*.dist-info"):
    meta = (di / "METADATA").read_text(errors="replace")
    name = canon(re.search(r"^Name: (.+)$", meta, re.M).group(1).strip())
    ver = re.search(r"^Version: (.+)$", meta, re.M).group(1).strip()
    if name == "hermes-agent":
        continue
    shipped += 1
    if ver not in locked.get(name, set()):
        bad.append(f"{name} {ver} (lock: {', '.join(sorted(locked.get(name, []))) or 'absent'})")
if shipped == 0:
    print("measured nothing: no dist-info in the tree"); sys.exit(1)
for b in bad:
    print(f"      not the locked version: {b}")
if bad:
    sys.exit(1)
print(f"      {shipped} libraries, each at its uv.lock version")
PY
echo "PASS [3/7] check_versions_follow_lock"

# ---- 4. nemo-relay and pillow-heif are not there ----
for name in $HERMES_EXCLUDE; do
	mod=$(echo "$name" | tr '-' '_')
	ls -d "$SITE/$mod" "$SITE/$mod"-*.dist-info "$SITE/$mod.libs" 2>/dev/null | grep -q . \
		&& fail "[4/7] check_excluded_absent" "$name is in the package"
done
# And nothing still declares a dependency the package does not satisfy, apart from the
# two left out: an exclusion that dragged a third package's requirement down with it
# would show here, not at import time on a router.
python3 - "$SITE" "$HERMES_EXCLUDE" <<'PY' || fail "[4/7] check_excluded_absent" "see above"
import re, sys
from pathlib import Path
site, excluded = Path(sys.argv[1]), set(sys.argv[2].split())
canon = lambda n: re.sub(r"[-_.]+", "-", n).lower()
have = set()
for di in site.glob("*.dist-info"):
    m = re.search(r"^Name: (.+)$", (di / "METADATA").read_text(errors="replace"), re.M)
    have.add(canon(m.group(1).strip()))
if not have:
    print("measured nothing"); sys.exit(1)
hermes = next(site.glob("hermes_agent-*.dist-info"))
declared = set()
for line in (hermes / "METADATA").read_text().splitlines():
    if line.startswith("Requires-Dist:") and "extra ==" not in line:
        declared.add(canon(re.split(r"[\s\[<>=!~;(]", line.split(":", 1)[1].strip())[0]))
gone = {canon(e) for e in excluded}
missing_core = sorted(d for d in declared - have - gone
                      if d not in {"tzdata", "pywinpty", "pywin32", "concurrent-log-handler"})
if missing_core:
    print("      core dependencies missing beyond the two left out:", " ".join(missing_core)); sys.exit(1)
if not gone <= declared:
    print("      the left-out names are not upstream core dependencies any more:", " ".join(sorted(gone - declared))); sys.exit(1)
PY
echo "PASS [4/7] check_excluded_absent"

# ---- 5. the Relay host falls back to upstream's no-op ----
out=$(hpy 'from agent.relay_runtime import HOST_REGISTRY, NoopRelayRuntime
h = HOST_REGISTRY.for_profile()
print(type(h).__name__)
assert isinstance(h, NoopRelayRuntime), type(h)' 2>&1) || { echo "$out" | tail -5; fail "[5/7] check_relay_falls_back" "the Relay host did not fall back"; }
echo "$out" | tail -1 | grep -qx NoopRelayRuntime || { echo "$out"; fail "[5/7] check_relay_falls_back" "unexpected host"; }
echo "PASS [5/7] check_relay_falls_back"

# ---- 6. skills, optional skills, locales, MCP catalogue ----
out=$(hpy 'from pathlib import Path
from hermes_constants import get_bundled_skills_dir, get_optional_skills_dir, get_optional_mcps_dir
from agent import i18n
share = Path("/usr/share/hermes-agent")
for name, path in (("skills", get_bundled_skills_dir()), ("optional-skills", get_optional_skills_dir()),
                   ("optional-mcps", get_optional_mcps_dir()), ("locales", i18n._locales_dir())):
    assert Path(path) == share / name, f"{name} resolves to {path}, not {share / name}"
    assert any(Path(path).iterdir()), f"{name} at {path} is empty"
    print(name, path)
import yaml
en = yaml.safe_load(open(share / "locales" / "en.yaml"))
def first_leaf(d, pre=""):
    for k, v in d.items():
        if isinstance(v, dict):
            r = first_leaf(v, pre + k + ".")
            if r: return r
        elif isinstance(v, str) and "{" not in v:
            return pre + k, v
key, text = first_leaf(en)
got = i18n.t(key, lang="en")
assert got == text and got != key, f"t({key!r}) gave {got!r}, the catalogue says {text!r}"
print("t", key, "->", got)' 2>&1) || { echo "$out" | tail -5; fail "[6/7] check_assets_resolve" "see above"; }
echo "$out" | sed 's/^/      /'
echo "PASS [6/7] check_assets_resolve"

# ---- 7. the platform plugins ship, Telegram among them ----
out=$(hpy 'from hermes_cli.plugins import get_bundled_plugins_dir
from pathlib import Path
d = Path(get_bundled_plugins_dir())
manifests = sorted(d.glob("platforms/*/plugin.y*ml"))
names = [m.parent.name for m in manifests]
print(len(manifests), "platform plugins in", d)
assert "telegram" in names, names' 2>&1) || { echo "$out" | tail -5; fail "[7/7] check_platform_plugins_ship" "see above"; }
echo "      $out"
echo "PASS [7/7] check_platform_plugins_ship"
echo "gate-upstream: all 7 checks passed"
CONTAINER
