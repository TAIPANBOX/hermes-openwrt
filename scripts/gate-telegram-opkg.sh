#!/bin/sh
# gate-telegram-opkg.sh -- the same add-on, on the line where the danger is different.
#
# Invariant:
#
#   "hermes-agent-telegram installs beside hermes-agent on OpenWrt 24.10 without either
#   package claiming a file the other owns, the library imports on the CPython 3.11 that
#   release ships, the service still refuses to run a bot nobody is allowed to talk to,
#   and removing the add-on leaves the base package whole and no empty directories."
#
# Why this exists separately from gate-telegram.sh
#
# On 25.12 apk REFUSES an install where two packages claim one file, so the gate there is
# largely asking apk to tell us. opkg does not refuse. It overwrites, updates its own
# manifest, and leaves the first package's list describing bytes it did not write; the
# damage then appears when the SECOND package is removed and takes a file the FIRST still
# needs. So on this line the check has to compare the two file lists itself, and a green
# from opkg proves nothing on its own.
#
# The other difference is Python: 3.11 here against 3.13 on 25.12, which is a different
# wheel set and a different bytecode. tornado ships a stable-ABI wheel that serves both,
# and that is a claim worth failing here rather than on a router.
#
# The checks are a subset of gate-telegram.sh's and carry the same names on purpose:
# features/telegram.feature describes behaviour, not a release, and
# scripts/gate-scenarios-bound.sh takes the union of both gates.
set -eu

CHECKS='check_refuses_without_library check_no_file_collision check_library_imports check_refuses_without_allowlist check_removal_is_clean'

if [ "${1:-}" = "--selftest" ]; then
	n=0; for c in $CHECKS; do echo "$c"; n=$((n + 1)); done
	[ "$n" -gt 0 ] || { echo "measured nothing" >&2; exit 1; }
	exit 0
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-24.10.8}
case "$ARCH" in
	x86_64) IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:x86-64-$RELEASE} ;;
	*)      IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:$ARCH-$RELEASE} ;;
esac
PLATFORM=${PLATFORM:-linux/$ARCH}

# An .ipk filename carries its architecture, unlike an .apk, so these globs are already
# specific. -t still, so a stale build never wins over a fresh one.
BASE=${BASE:-$(ls -t "$ROOT"/hermes-agent_*_"$ARCH".ipk 2>/dev/null | head -1)}
ADDON=${ADDON:-$(ls -t "$ROOT"/hermes-agent-telegram_*_"$ARCH".ipk 2>/dev/null | head -1)}
[ -n "$BASE" ] && [ -f "$BASE" ] || {
	echo "FAIL: no base .ipk for $ARCH. Build it: RELEASE=$RELEASE ./package/hermes-agent/build-in-container.sh $ARCH"; exit 1; }
[ -n "$ADDON" ] && [ -f "$ADDON" ] || {
	echo "FAIL: no add-on .ipk for $ARCH. Build it: RELEASE=$RELEASE ./package/hermes-agent-telegram/build-in-container.sh $ARCH"; exit 1; }
echo "PASS: artefacts $(basename "$BASE") and $(basename "$ADDON")"
echo "-- container checks: $IMAGE ($PLATFORM) --"

# -i is load-bearing: without it docker hands `sh -s` an empty stdin and this gate
# reports every check passed having run nothing.
docker run --rm -i --platform "$PLATFORM" \
	-v "$BASE:/base.ipk:ro" -v "$ADDON:/addon.ipk:ro" "$IMAGE" /bin/sh -s <<'CONTAINER'
set -eu
fail() { echo "FAIL $1: $2"; exit 1; }

SITE=/usr/lib/hermes-agent/site-packages
TOKEN='123456789:AAHgateCanaryTokenNotRealAAHgateCanary'

# opkg refuses to do anything without these and says so in terms of a lock file, which
# reads like a permissions problem rather than a missing directory.
mkdir -p /var/lock /var/run /var/state
opkg update >/dev/null 2>&1
opkg install /base.ipk >/tmp/i.log 2>&1 || { tail -20 /tmp/i.log; fail setup "the base package would not install"; }

# ---- 1. switching Telegram on without the library names the package ----
uci set hermes.main.enabled=1; uci commit hermes
mkdir -p /etc/hermes-agent && chmod 0700 /etc/hermes-agent
printf '%s' 'sk-gate-not-a-real-key' > /etc/hermes-agent/provider.key
chmod 600 /etc/hermes-agent/provider.key
uci set hermes.telegram.enabled=1; uci commit hermes

msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q 'client library is not installed' \
	|| { echo "$msg"; fail "[1/5] check_refuses_without_library" "did not refuse"; }
echo "$msg" | grep -q 'opkg install hermes-agent-telegram' \
	|| { echo "$msg"; fail "[1/5] check_refuses_without_library" "did not name the opkg command for this release"; }
echo "PASS [1/5] check_refuses_without_library"

# ---- 2. the two packages share no file ----
# opkg will not refuse, so this compares the lists rather than trusting the exit code.
opkg install /addon.ipk >/tmp/a.log 2>&1 || { tail -20 /tmp/a.log; fail "[2/5] check_no_file_collision" "opkg install failed"; }
opkg list-installed 2>/dev/null | grep -q '^hermes-agent-telegram ' || fail "[2/5] check_no_file_collision" "not registered"

# `opkg files` opens with a sentence, not a path. Keeping only lines that begin with a
# slash drops it without depending on its wording.
opkg files hermes-agent          2>/dev/null | grep '^/' | sort > /tmp/base.files
opkg files hermes-agent-telegram 2>/dev/null | grep '^/' | sort > /tmp/addon.files
nb=$(wc -l < /tmp/base.files); na=$(wc -l < /tmp/addon.files)
[ "$nb" -gt 100 ] || fail "[2/5] check_no_file_collision" "opkg listed only $nb files for the base package; the listing is not being read"
[ "$na" -gt 10 ]  || fail "[2/5] check_no_file_collision" "opkg listed only $na files for the add-on; the listing is not being read"
cat /tmp/base.files /tmp/addon.files | sort | uniq -d > /tmp/shared
if [ -s /tmp/shared ]; then
	head -10 /tmp/shared
	fail "[2/5] check_no_file_collision" "$(wc -l < /tmp/shared) files are claimed by both packages, and opkg did not say so"
fi
echo "PASS [2/5] check_no_file_collision ($na add-on files against $nb base files)"

# ---- 3. the library imports on the 3.11 this release ships ----
pyv=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
[ "$pyv" = "3.11" ] || fail "[3/5] check_library_imports" "this image runs Python $pyv, so it is not the 24.10 line this gate is for"
v=$(PYTHONPATH=$SITE python3 -c 'import telegram, telegram.ext, tornado; print(telegram.__version__)' 2>&1) \
	|| { echo "$v"; fail "[3/5] check_library_imports" "the library does not import on Python $pyv"; }
[ "$v" = "22.6" ] || fail "[3/5] check_library_imports" "expected 22.6, got '$v'"
echo "PASS [3/5] check_library_imports (python-telegram-bot $v on Python $pyv)"

# ---- 4. a token with nobody allowed is still refused here ----
printf '%s' "$TOKEN" > /etc/hermes-agent/telegram.token
chmod 600 /etc/hermes-agent/telegram.token
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q 'no user is allowed' \
	|| { echo "$msg"; fail "[4/5] check_refuses_without_allowlist" "a bot with a token and an empty allowlist was allowed to start"; }
uci add_list hermes.telegram.allow_user_id=987654321; uci commit hermes
msg=$(/etc/init.d/hermes-agent start 2>&1 || true)
echo "$msg" | grep -q 'no user is allowed' \
	&& { echo "$msg"; fail "[4/5] check_refuses_without_allowlist" "still refuses after a user was allowed"; }
uci show hermes 2>/dev/null | grep -q 'AAHgateCanaryToken' \
	&& fail "[4/5] check_refuses_without_allowlist" "the token reached UCI"
echo "PASS [4/5] check_refuses_without_allowlist"

# ---- 5. removal leaves the base whole, and no empty directories ----
# opkg removes the files it owns and leaves the directory tree standing: on the base
# package that was 9033 files gone and 985 empty directories left. The add-on ships a
# postrm generated from its own tree for exactly this.
opkg remove hermes-agent-telegram >/tmp/r.log 2>&1 || { tail -10 /tmp/r.log; fail "[5/5] check_removal_is_clean" "opkg remove failed"; }
[ -d "$SITE/telegram" ] && fail "[5/5] check_removal_is_clean" "the telegram directory was left standing"
[ -d "$SITE/tornado" ] && fail "[5/5] check_removal_is_clean" "the tornado directory was left standing"
[ -f /usr/lib/hermes-agent/telegram.manifest ] && fail "[5/5] check_removal_is_clean" "the manifest was left behind, so the service would still believe the library is installed"
# The half opkg gets wrong: the base package's files must all still be there.
missing=0
while read -r f; do
	[ -e "$f" ] || { echo "  gone: $f"; missing=$((missing + 1)); }
done < /tmp/base.files
[ "$missing" -eq 0 ] || fail "[5/5] check_removal_is_clean" "removing the add-on took $missing files belonging to hermes-agent"
/usr/bin/hermes --version >/dev/null 2>&1 || fail "[5/5] check_removal_is_clean" "the base package no longer runs"
echo "PASS [5/5] check_removal_is_clean ($(wc -l < /tmp/base.files) base files still present)"
CONTAINER

echo "gate-telegram-opkg: all 5 checks passed"
