#!/bin/sh
# gate-luci.sh -- the LuCI app installs, registers with ubus, and never hands a key back.
#
# Invariant:
#
#   "luci-app-hermes installs on a stock OpenWrt 25.12, its rpcd backend appears on ubus
#   and answers, a key written through it lands 0600, and no method ever returns a key."
#
# The last clause is the one worth a gate. A settings page that stores keys is ordinary;
# a settings page that cannot be made to give one back is a design, and a design that is
# not enforced by a test decays into an intention. So the check below writes a known
# canary through the RPC and then asserts that no method mentions it.
#
# What this does NOT check is the rendered page. LuCI in a bare rootfs container needs a
# session, a theme and a ubus session object before it will render anything at all, and
# standing that up would test the container far more than it tests this app. What is
# checked instead is everything the browser depends on: the files land where luci-base
# looks, the JS parses, the menu and ACL are valid JSON, the ubus object exists, and the
# calls the pages make return what the pages expect.
set -eu

CHECKS='check_installs check_files_land check_json_valid check_js_parses check_ubus_object check_status_answers check_secret_written_0600 check_secret_never_returned check_clean_removal'

if [ "${1:-}" = "--selftest" ]; then
	n=0; for c in $CHECKS; do echo "$c"; n=$((n + 1)); done
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

AGENT=${AGENT:-$(ls "$ROOT"/hermes-agent-*.apk 2>/dev/null | head -1)}
LUCI=${LUCI:-$(ls "$ROOT"/luci-app-hermes-*.apk 2>/dev/null | head -1)}
[ -n "$AGENT" ] && [ -f "$AGENT" ] || { echo "FAIL: no hermes-agent package; build it first"; exit 1; }
[ -n "$LUCI" ]  && [ -f "$LUCI" ]  || { echo "FAIL: no luci-app-hermes package; build it first"; exit 1; }

# The JS never reaches the router's shell, so it is parsed here rather than there. A
# syntax error would otherwise reach a browser as a blank page with a console message
# nobody is looking at.
echo "-- parsing the views --"
for f in "$ROOT"/package/luci-app-hermes/htdocs/luci-static/resources/view/hermes/*.js; do
	docker run --rm -v "$f:/x.js:ro" node:22-alpine node --check /x.js \
		|| { echo "FAIL check_js_parses: $(basename "$f") does not parse"; exit 1; }
done
echo "PASS check_js_parses ($(ls "$ROOT"/package/luci-app-hermes/htdocs/luci-static/resources/view/hermes/*.js | wc -l | tr -d ' ') views)"

echo "-- container checks: $IMAGE ($PLATFORM) --"
# -i is load-bearing: without it docker hands `sh -s` an empty stdin, nothing runs, the
# container exits 0, and this gate passes having measured nothing.
docker run --rm -i --platform "$PLATFORM" \
	-v "$AGENT:/agent.apk:ro" -v "$LUCI:/luci.apk:ro" \
	"$IMAGE" /bin/sh -s <<'CONTAINER'
set -eu
fail() { echo "FAIL $1: $2"; exit 1; }
CANARY=sk-luci-gate-canary

mkdir -p /var/lock /var/run /var/state
apk update -q
apk add -q --allow-untrusted /agent.apk >/dev/null 2>&1
apk add -q luci-base rpcd >/dev/null 2>&1

# ---- 1. installs ----
apk add --allow-untrusted /luci.apk >/tmp/add.log 2>&1 || { cat /tmp/add.log; fail check_installs "apk add failed"; }
apk info -e luci-app-hermes >/dev/null 2>&1 || fail check_installs "not registered"
echo "PASS check_installs"

# ---- 2. the files land where luci-base looks ----
# These paths are luci-base's own search locations. A file one directory out installs
# perfectly and is then invisible, which looks like a broken app rather than a misplaced
# file.
for f in /www/luci-static/resources/view/hermes/overview.js \
         /www/luci-static/resources/view/hermes/settings.js \
         /usr/share/luci/menu.d/luci-app-hermes.json \
         /usr/share/rpcd/acl.d/luci-app-hermes.json \
         /usr/libexec/rpcd/hermes; do
	[ -e "$f" ] || fail check_files_land "missing: $f"
done
[ -x /usr/libexec/rpcd/hermes ] || fail check_files_land "the rpcd backend is not executable"
echo "PASS check_files_land"

# ---- 3. the menu and ACL are valid JSON ----
# rpcd and luci-base both fail quietly on malformed JSON: the entry simply never appears,
# with nothing in any log to say why.
for f in /usr/share/luci/menu.d/luci-app-hermes.json /usr/share/rpcd/acl.d/luci-app-hermes.json; do
	jsonfilter -i "$f" -e '@' >/dev/null 2>&1 || fail check_json_valid "$f is not valid JSON"
done
echo "PASS check_json_valid"

# ---- 4. the backend appears on ubus ----
ubusd >/dev/null 2>&1 & sleep 1
rpcd  >/dev/null 2>&1 & sleep 2
ubus list 2>/dev/null | grep -qx hermes || fail check_ubus_object "rpcd did not register the hermes object"
echo "PASS check_ubus_object"

# ---- 5. status answers with the fields the pages read ----
out=$(ubus call hermes status 2>&1) || { echo "$out"; fail check_status_answers "the call failed"; }
for k in running enabled version data_dir free_kb provider_key_set; do
	echo "$out" | grep -q "\"$k\"" || { echo "$out"; fail check_status_answers "no $k in the reply"; }
done
echo "PASS check_status_answers"

# ---- 6. a key written through the RPC lands root-only ----
ubus call hermes set_secret "{\"name\":\"provider\",\"value\":\"  $CANARY  \"}" >/dev/null 2>&1 \
	|| fail check_secret_written_0600 "set_secret failed"
mode=$(ls -l /etc/hermes-agent/provider.key | awk '{print $1}')
[ "$mode" = "-rw-------" ] || fail check_secret_written_0600 "mode is $mode, want -rw------- (0600)"
# Whitespace trimmed, or the service reads a key with a trailing newline and the provider
# rejects it with an authentication error that points nowhere near the cause.
[ "$(cat /etc/hermes-agent/provider.key)" = "$CANARY" ] || fail check_secret_written_0600 "the value was not trimmed"
echo "PASS check_secret_written_0600"

# ---- 7. and no method hands it back ----
# The whole point of the write-only design, asserted rather than intended. Every method
# the ACL exposes for reading is called and none may mention the canary.
for m in status logs; do
	if ubus call hermes "$m" 2>/dev/null | grep -q "$CANARY"; then
		fail check_secret_never_returned "the $m method returned the key"
	fi
done
ubus call hermes status 2>/dev/null | grep -q '"provider_key_set": true' \
	|| fail check_secret_never_returned "status does not even report the key as present"
echo "PASS check_secret_never_returned"

# ---- 8. clean removal ----
apk del luci-app-hermes >/dev/null 2>&1 || fail check_clean_removal "apk del failed"
[ -e /usr/libexec/rpcd/hermes ] && fail check_clean_removal "the rpcd backend is still there"
[ -e /usr/share/luci/menu.d/luci-app-hermes.json ] && fail check_clean_removal "the menu entry is still there"
# The key must NOT be removed with the package: it lives in /etc/hermes-agent, which
# belongs to the agent, and taking the web interface off should not silently
# de-authenticate a working service.
[ -e /etc/hermes-agent/provider.key ] || fail check_clean_removal "removing the web app deleted the agent's key"
echo "PASS check_clean_removal"
CONTAINER

echo "gate-luci: all 9 checks passed"
