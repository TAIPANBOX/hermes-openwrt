#!/bin/sh
# gate-telegram.sh -- the Telegram add-on must install beside the base package, not into it.
#
# Invariant:
#
#   "hermes-agent-telegram installs alongside hermes-agent on a stock OpenWrt rootfs
#   without either package claiming a file the other owns, the Telegram client library
#   then imports under the router's own interpreter, and the service refuses to start,
#   naming the one thing to fix, whenever Telegram is switched on without the library,
#   without a token, or without anybody allowed to talk to it."
#
# Why this gate installs rather than inspects
#
# The failure this package can have is a file owned by two packages, and it is invisible
# in either archive on its own. apk refuses such an install outright; opkg accepts it and
# leaves the base package's manifest pointing at bytes it did not write, so removing the
# ADD-ON later deletes a file the BASE still needs. Neither is visible until both halves
# are on one machine, which is to say: here, or on somebody's router.
#
# Each scenario in features/telegram.feature names one of the checks below.
set -eu

CHECKS='check_base_lacks_the_library check_refuses_without_library check_no_file_collision check_library_imports check_refuses_without_token check_refuses_without_allowlist check_token_never_readable check_removal_is_clean'

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


# Where to look for the package, and why not the repository root.
#
# An .apk filename carries no architecture, unlike an .ipk, so every architecture builds
# a file of the same name and the last build to finish wins in the repository root. A
# gate reading it therefore tests whichever architecture was built most recently, which
# on 2026-09-08 meant an aarch64 gate trying to install an x86_64 package and reporting
# "error: uninstallable" with no hint of the cause. The per-architecture build directory
# has no such ambiguity, so it is what is read; the root is a fallback that says so.
LINE=${LINE:-${RELEASE%%.*}.$(echo "$RELEASE" | cut -d. -f2)}
BUILD_DIR="$ROOT/build/$LINE/$ARCH"
pick_apk() {
	found=$(ls -t "$BUILD_DIR"/$1 2>/dev/null | head -1)
	if [ -n "$found" ]; then echo "$found"; return 0; fi
	found=$(ls -t "$ROOT"/$1 2>/dev/null | head -1)
	if [ -n "$found" ]; then
		echo "$ROOT holds no per-architecture build for $ARCH; falling back to $(basename "$found")," >&2
		echo "which may have been built for another architecture. Build $ARCH to be sure." >&2
		echo "$found"
	fi
}

# [0-9] rather than *, so this stops at the base package and does not pick up the add-on
# whose name begins the same way.
BASE=${BASE:-$(pick_apk 'hermes-agent-[0-9]*.apk')}
# The add-on's build directory is a sibling of the base package's, not a child.
ADDON=${ADDON:-$(ls -t "$BUILD_DIR-telegram"/hermes-agent-telegram-*.apk 2>/dev/null | head -1)}
[ -n "$ADDON" ] || ADDON=$(ls -t "$ROOT"/hermes-agent-telegram-*.apk 2>/dev/null | head -1)
[ -n "$BASE" ] && [ -f "$BASE" ] || {
	echo "FAIL: no base package. Build it: ./package/hermes-agent/build-in-container.sh $ARCH"; exit 1; }
[ -n "$ADDON" ] && [ -f "$ADDON" ] || {
	echo "FAIL: no add-on. Build it: ./package/hermes-agent-telegram/build-in-container.sh $ARCH"; exit 1; }
echo "PASS: artefacts $(basename "$BASE") and $(basename "$ADDON")"
echo "-- container checks: $IMAGE ($PLATFORM) --"

# -i is load-bearing. Without it docker hands `sh -s` an empty stdin, the script never
# runs, the container exits 0, and this gate reports every check passed having measured
# nothing at all. That happened once already, in this repository.
docker run --rm -i --platform "$PLATFORM" \
	-v "$BASE:/base.apk:ro" -v "$ADDON:/addon.apk:ro" "$IMAGE" /bin/sh -s <<'CONTAINER'
set -eu
fail() { echo "FAIL $1: $2"; exit 1; }

SITE=/usr/lib/hermes-agent/site-packages
# A shaped but fictional token. The init script checks the shape before handing it over,
# so a placeholder like "canary" would be refused for the wrong reason and every check
# after it would pass while proving nothing.
TOKEN='123456789:AAHgateCanaryTokenNotRealAAHgateCanary'

mkdir -p /var/lock /var/run /var/state
apk update -q
apk add --allow-untrusted /base.apk >/tmp/add.log 2>&1 || { cat /tmp/add.log; fail "setup" "the base package would not install"; }

# ---- 1. the base alone cannot talk to Telegram ----
# The positive control is the point of this check. "import telegram fails" is also what a
# broken interpreter, a wrong PYTHONPATH or an empty site-packages looks like, and each of
# those would let every later check pass for the wrong reason.
PYTHONPATH=$SITE python3 -c 'import httpx' 2>/dev/null \
	|| fail "[1/8] check_base_lacks_the_library" "the base site-packages does not even import httpx, so this check would prove nothing"
if PYTHONPATH=$SITE python3 -c 'import telegram' 2>/dev/null; then
	fail "[1/8] check_base_lacks_the_library" "the base package already carries the telegram library, so the add-on has no reason to exist"
fi
[ -f "$SITE/plugins/platforms/telegram/adapter.py" ] \
	|| fail "[1/8] check_base_lacks_the_library" "the adapter is missing too, so this is not an add-on but a port"
echo "PASS [1/8] check_base_lacks_the_library"

# ---- 2. switching Telegram on without the library names the package ----
# The main section has to be valid first, or the service refuses for a different reason
# and this check passes on the wrong refusal.
uci set hermes.main.enabled=1
uci commit hermes
mkdir -p /etc/hermes-agent && chmod 0700 /etc/hermes-agent
printf '%s' 'sk-gate-not-a-real-key' > /etc/hermes-agent/provider.key
chmod 600 /etc/hermes-agent/provider.key
uci set hermes.telegram.enabled=1
uci commit hermes

msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q 'client library is not installed' \
	|| { echo "$msg"; fail "[2/8] check_refuses_without_library" "did not refuse"; }
echo "$msg" | grep -q 'hermes-agent-telegram' \
	|| { echo "$msg"; fail "[2/8] check_refuses_without_library" "refused without naming the package to install"; }
pgrep -f 'hermes_cli/main.py gateway' >/dev/null 2>&1 \
	&& fail "[2/8] check_refuses_without_library" "it started anyway"
echo "PASS [2/8] check_refuses_without_library"

# ---- 3. the two packages share no file ----
apk add --allow-untrusted /addon.apk >/tmp/addon.log 2>&1 || { cat /tmp/addon.log; fail "[3/8] check_no_file_collision" "apk refused the add-on beside the base"; }
apk info -e hermes-agent-telegram >/dev/null 2>&1 || fail "[3/8] check_no_file_collision" "not registered after install"

# `apk info -L` opens with "<pkg>-<version> contains:" and that header begins with a
# lowercase letter too, so a `grep '^[a-z]'` filter keeps it. It cost this check its
# first run: the header was compared against the filesystem as though it were a path.
apk_files() { apk info -L "$1" 2>/dev/null | grep -v 'contains:$' | grep -v '^$' | sort; }
apk_files hermes-agent          > /tmp/base.files
apk_files hermes-agent-telegram > /tmp/addon.files
nb=$(wc -l < /tmp/base.files); na=$(wc -l < /tmp/addon.files)
# Without these two lines an apk that changed its output format would make the
# intersection below empty and this check green, having compared nothing with nothing.
[ "$nb" -gt 100 ] || fail "[3/8] check_no_file_collision" "apk listed only $nb files for the base package; the listing is not being read"
[ "$na" -gt 10 ]  || fail "[3/8] check_no_file_collision" "apk listed only $na files for the add-on; the listing is not being read"
# busybox has no comm. Both lists are unique, so a duplicate in the concatenation is a
# file both packages claim.
cat /tmp/base.files /tmp/addon.files | sort | uniq -d > /tmp/shared
if [ -s /tmp/shared ]; then
	head -10 /tmp/shared
	fail "[3/8] check_no_file_collision" "$(wc -l < /tmp/shared) files are owned by both packages"
fi
echo "PASS [3/8] check_no_file_collision ($na add-on files against $nb base files)"

# ---- 4. the library imports on the router's own interpreter ----
# The bet this package rests on: one pure-python wheel and one compiled musllinux wheel,
# neither built here. If tornado were assembled for the wrong libc it fails here, not on
# somebody's device.
v=$(PYTHONPATH=$SITE python3 -c 'import telegram, telegram.ext, tornado; print(telegram.__version__)' 2>&1) \
	|| { echo "$v"; fail "[4/8] check_library_imports" "the library does not import"; }
[ "$v" = "22.6" ] || fail "[4/8] check_library_imports" "expected 22.6, got '$v'"
grep -q 'python-telegram-bot==22.6' /usr/lib/hermes-agent/telegram.manifest \
	|| fail "[4/8] check_library_imports" "the shipped manifest does not describe what installed"
echo "PASS [4/8] check_library_imports (python-telegram-bot $v)"

# ---- 5. no token, and it says where to write one ----
rm -f /etc/hermes-agent/telegram.token
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q 'no token in' \
	|| { echo "$msg"; fail "[5/8] check_refuses_without_token" "did not refuse"; }
echo "$msg" | grep -q '/etc/hermes-agent/telegram.token' \
	|| { echo "$msg"; fail "[5/8] check_refuses_without_token" "refused without naming the file to write"; }
echo "PASS [5/8] check_refuses_without_token"

# ---- 6. a token with nobody allowed is refused, not left open ----
printf '%s' "$TOKEN" > /etc/hermes-agent/telegram.token
chmod 600 /etc/hermes-agent/telegram.token
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q 'no user is allowed' \
	|| { echo "$msg"; fail "[6/8] check_refuses_without_allowlist" "a bot with a token and an empty allowlist was allowed to start"; }
echo "$msg" | grep -q 'allow_user_id' \
	|| { echo "$msg"; fail "[6/8] check_refuses_without_allowlist" "refused without saying how to allow a user"; }

# The converse, so this is a check about the allowlist and not about refusing always.
uci add_list hermes.telegram.allow_user_id=987654321
uci commit hermes
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q 'no user is allowed' \
	&& { echo "$msg"; fail "[6/8] check_refuses_without_allowlist" "still refuses after a user was allowed"; }
echo "PASS [6/8] check_refuses_without_allowlist"

# ---- 7. the token reaches the process without passing anything readable ----
# ls -l and awk, not stat: OpenWrt's busybox has no stat applet, and the first version
# of this line failed with "stat: not found" rather than passing on nothing, only because
# the comparison it fed was against a non-empty string. gate-luci.sh already reads the
# mode this way.
tokmode=$(ls -l /etc/hermes-agent/telegram.token | awk '{print $1, $3}')
[ "$tokmode" = "-rw------- root" ] \
	|| fail "[7/8] check_token_never_readable" "the token file is [$tokmode], want [-rw------- root]"
uci show hermes 2>/dev/null | grep -q "$TOKEN" \
	&& fail "[7/8] check_token_never_readable" "the token is in UCI"
# The token's secret half alone, in case only part of it were to leak.
uci show hermes 2>/dev/null | grep -q 'AAHgateCanaryToken' \
	&& fail "[7/8] check_token_never_readable" "part of the token is in UCI"
grep -rq "$TOKEN" /etc/config/ 2>/dev/null \
	&& fail "[7/8] check_token_never_readable" "the token is in a config file"

env HERMES_HOME=/tmp/h TELEGRAM_BOT_TOKEN="$TOKEN" TELEGRAM_ALLOWED_USERS=987654321 \
	OPENAI_API_KEY=sk-not-real OPENAI_BASE_URL=https://example.invalid/v1 \
	HERMES_DISABLE_LAZY_INSTALLS=1 /usr/bin/hermes gateway run >/tmp/gw.log 2>&1 &
GW=$!
sleep 6
if kill -0 "$GW" 2>/dev/null; then
	# /proc rather than ps|grep: a grep for the token matches its own command line and
	# reports a leak that is not there.
	if tr '\0' '\n' < "/proc/$GW/cmdline" | grep -q "$TOKEN"; then
		kill "$GW" 2>/dev/null
		fail "[7/8] check_token_never_readable" "the token is in the process command line"
	fi
	kill "$GW" 2>/dev/null || true
else
	sed 's/\x1b\[[0-9;]*m//g' /tmp/gw.log | tail -5
	fail "[7/8] check_token_never_readable" "the gateway exited, so no command line was inspected"
fi
echo "PASS [7/8] check_token_never_readable"

# ---- 8. removing the add-on leaves a working base ----
apk del hermes-agent-telegram >/dev/null 2>&1 || fail "[8/8] check_removal_is_clean" "apk del failed"
[ -d "$SITE/telegram" ] && fail "[8/8] check_removal_is_clean" "the telegram package directory was left behind"
[ -d "$SITE/tornado" ] && fail "[8/8] check_removal_is_clean" "the tornado package directory was left behind"
[ -f /usr/lib/hermes-agent/telegram.manifest ] && fail "[8/8] check_removal_is_clean" "the manifest was left behind, so the service would still believe the library is installed"
# The half that matters: the base package must be untouched by the add-on's removal.
while read -r f; do
	[ -e "/$f" ] || fail "[8/8] check_removal_is_clean" "removing the add-on took /$f, which belongs to hermes-agent"
done < /tmp/base.files
/usr/bin/hermes --version >/dev/null 2>&1 || fail "[8/8] check_removal_is_clean" "the base package no longer runs"
echo "PASS [8/8] check_removal_is_clean ($(wc -l < /tmp/base.files) base files still present)"
CONTAINER

echo "gate-telegram: all 8 checks passed"
