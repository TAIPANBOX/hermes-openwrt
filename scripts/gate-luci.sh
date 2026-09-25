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

CHECKS='check_installs check_files_land check_json_valid check_js_parses check_ubus_object check_status_answers check_free_space_before_first_start check_secret_written_0600 check_secret_never_returned check_telegram_state_reported check_read_acl_is_narrow check_secret_write_failure_reported check_secret_path_mismatch_refused check_provider_key_written_0600 check_provider_key_name_refused check_provider_key_path_mismatch_refused check_chatgpt_sign_in_from_the_page check_upgrade_restarts_rpcd check_clean_removal'

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

AGENT=${AGENT:-$(pick_apk 'hermes-agent-[0-9]*.apk')}
# The LuCI package is architecture-neutral, so its one build directory is unambiguous
# and the root only ever holds copies of the same file.
LUCI=${LUCI:-$(ls -t "$ROOT"/build/luci-app-hermes-apk/luci-app-hermes-*.apk "$ROOT"/luci-app-hermes-*.apk 2>/dev/null | head -1)}
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
         /www/luci-static/resources/view/hermes/providers.js \
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

# ---- 5b. free space before the first start, where the data will live ----
# The service creates its data directory at its first start, so a new install has none
# yet. status used to run df on the missing path, get nothing and report 0, which put
# 0 B and the low-space warning in front of every new owner: seen on both test routers
# on 2026-09-25, after a clean install by README, with 6.5 GB free. The figure has to be
# the free space of the nearest directory that exists, for the directory the service
# will actually use, and asking must not create anything.
free_case() { # $1 data_dir as set in UCI, $2 the directory the service would use
	uci set hermes.main.data_dir="$1"; uci commit hermes
	st=$(ubus call hermes status 2>/dev/null)
	got=$(echo "$st" | jsonfilter -e '@.free_kb')
	dir=$(echo "$st" | jsonfilter -e '@.data_dir')
	[ "$dir" = "$2" ] || fail check_free_space_before_first_start "data_dir '$1' is reported as '$dir'; the service would use '$2'"
	probe=$2
	while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
	want=$(df -k "$probe" | awk 'NR==2 {print $4}')
	[ -n "$got" ] && [ "$got" -gt 0 ] \
		|| fail check_free_space_before_first_start "free_kb is ${got:-missing} for $2 before it exists; $probe has $want KiB free"
	d=$((got - want)); [ "$d" -ge 0 ] || d=$((0 - d))
	[ "$d" -le $((want / 100 + 1024)) ] \
		|| fail check_free_space_before_first_start "free_kb is $got for $2, but $probe has $want KiB free"
	[ -e "$2" ] && fail check_free_space_before_first_start "asking for status created $2"
	true
}
rm -rf /srv/hermes /mnt/gate-not-mounted
free_case /srv/hermes /srv/hermes
free_case /mnt/gate-not-mounted/hermes /mnt/gate-not-mounted/hermes
free_case '' /srv/hermes
uci set hermes.main.data_dir=/srv/hermes; uci commit hermes
echo "PASS check_free_space_before_first_start"

# ---- 6. a key written through the RPC lands root-only ----
ubus call hermes set_secret "{\"name\":\"provider\",\"value\":\"  $CANARY  \"}" >/dev/null 2>&1 \
	|| fail check_secret_written_0600 "set_secret failed"
mode=$(ls -l /etc/hermes-agent/provider.key | awk '{print $1}')
[ "$mode" = "-rw-------" ] || fail check_secret_written_0600 "mode is $mode, want -rw------- (0600)"
# Whitespace trimmed, or the service reads a key with a trailing newline and the provider
# rejects it with an authentication error that points nowhere near the cause.
[ "$(cat /etc/hermes-agent/provider.key)" = "$CANARY" ] || fail check_secret_written_0600 "the value was not trimmed"
echo "PASS check_secret_written_0600"

# ---- 7b. the page can tell a missing package from a missing token ----
# Two different failures with two different fixes, and the settings page decides which
# to show from these two fields. Reporting a token as present while the library is
# absent would send somebody to look for a configuration mistake that is not there.
ubus call hermes status 2>/dev/null | grep -q '"telegram_lib_installed"' \
	|| fail check_telegram_state_reported "status does not report whether the client library is installed"
# The add-on is not installed in this container, so the honest answer is false. A field
# that is present and always true would pass a grep and mislead the page.
ubus call hermes status 2>/dev/null | grep -q '"telegram_lib_installed": false' \
	|| fail check_telegram_state_reported "the library is absent here, yet status does not say so"
# And it must follow the manifest rather than being a constant.
mkdir -p /usr/lib/hermes-agent
: > /usr/lib/hermes-agent/telegram.manifest
ubus call hermes status 2>/dev/null | grep -q '"telegram_lib_installed": true' \
	|| fail check_telegram_state_reported "the manifest is present, yet status still says the library is not"
rm -f /usr/lib/hermes-agent/telegram.manifest
echo "PASS check_telegram_state_reported"

# ---- 8. and no method hands it back ----
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

# ---- 9. the read ACL is exactly what the pages call, and nothing else ----
# Read access is the wider audience: any session that holds it may call whatever this
# block grants. service.list is never called by either view and hands procd's own
# environment block to such a session (the runtime gate proves no secret is in it, but
# nothing else should have to rely on that); a file grant would hand over the key file
# itself while every ubus grant still read exactly status and logs. So the block is
# compared whole, not probed for the grants that have caused trouble so far. jshn rather
# than jsonfilter, because jsonfilter reads the keys it is asked about and cannot list the
# ones nobody thought to ask about.
#
# jshn is not written for `set -u` and returns 1 for an absent key, and rpcd reads `*` as
# a wildcard, which the shell would expand into file names, so this section runs with
# both relaxed and every lookup that may miss is guarded.
acl_fail() { fail check_read_acl_is_narrow "$1"; }
set +u -f
. /usr/share/libubox/jshn.sh
json_load_file /usr/share/rpcd/acl.d/luci-app-hermes.json 2>/dev/null || acl_fail "the ACL file does not load"
json_select luci-app-hermes 2>/dev/null || acl_fail "the ACL file has no luci-app-hermes group"
json_select read 2>/dev/null || acl_fail "the group has no read block"
json_get_keys read_keys
seen=' '
for k in $read_keys; do
	case "$seen" in *" $k "*) acl_fail "the read block lists \"$k\" twice" ;; esac
	seen="$seen$k "
	t=; json_get_type t "$k" 2>/dev/null || true
	case "$k:$t" in
		comment:string|description:string|ubus:object|uci:array) ;;
		*) acl_fail "the read block grants \"$k\"${t:+ ($t)}, which neither view calls" ;;
	esac
done
json_select ubus 2>/dev/null || acl_fail "the read block grants no ubus objects, so the pages could not call status"
json_get_keys ubus_objects
[ "$(echo $ubus_objects)" = hermes ] || acl_fail "read.ubus grants \"$(echo $ubus_objects)\", want hermes alone"
t=; json_get_type t hermes 2>/dev/null || true
[ "$t" = array ] || acl_fail "read.ubus.hermes is ${t:-missing}, want a list of methods"
hermes_methods=; json_get_values hermes_methods hermes 2>/dev/null || true
set -- $hermes_methods
[ "$#" -eq 2 ] || acl_fail "read.ubus.hermes grants $# methods ($hermes_methods), want status and logs"
case " $hermes_methods " in *" status "*) ;; *) acl_fail "status missing from read.ubus.hermes" ;; esac
case " $hermes_methods " in *" logs "*) ;;   *) acl_fail "logs missing from read.ubus.hermes" ;; esac
json_select ..
uci_configs=; json_get_values uci_configs uci 2>/dev/null || true
[ "$(echo $uci_configs)" = hermes ] || acl_fail "read.uci grants \"$(echo $uci_configs)\", want hermes alone"
set -u +f
echo "PASS check_read_acl_is_narrow"

# ---- 10. a write that cannot land is reported, not swallowed ----
rm -f /etc/hermes-agent/provider.key
mkdir /etc/hermes-agent/provider.key
out=$(ubus call hermes set_secret '{"name":"provider","value":"anything"}' 2>&1) || true
echo "$out" | grep -q '"ok": false' || { echo "$out"; fail check_secret_write_failure_reported "a failed write was reported as ok"; }
rmdir /etc/hermes-agent/provider.key 2>/dev/null
printf '%s' "$CANARY" > /etc/hermes-agent/provider.key
chmod 0600 /etc/hermes-agent/provider.key
echo "PASS check_secret_write_failure_reported"

# ---- 11. a UCI path pointing elsewhere is refused, not silently rerouted ----
# An operator who moves key_file in UCI must find out immediately, not discover after a
# restart that the service still cannot find a key this page happily reported as set.
uci set hermes.main.key_file=/tmp/elsewhere.key
uci commit hermes
# A marker captured right before the call, not an assumption about what an earlier
# check left behind, so this proves the SLOT specifically did not move, whatever ran
# before it.
MARKER_BEFORE=$(cat /etc/hermes-agent/provider.key 2>/dev/null)
out=$(ubus call hermes set_secret '{"name":"provider","value":"should-not-land"}' 2>&1) || true
echo "$out" | grep -q '"ok": false' || { echo "$out"; fail check_secret_path_mismatch_refused "set_secret did not refuse"; }
echo "$out" | grep -q '/tmp/elsewhere.key' || { echo "$out"; fail check_secret_path_mismatch_refused "the error does not name the service path"; }
[ -e /tmp/elsewhere.key ] && fail check_secret_path_mismatch_refused "a value was written to the mismatched path"
MARKER_AFTER=$(cat /etc/hermes-agent/provider.key 2>/dev/null)
[ "$MARKER_AFTER" = "$MARKER_BEFORE" ] \
	|| fail check_secret_path_mismatch_refused "the fixed slot changed from '$MARKER_BEFORE' to '$MARKER_AFTER'"
[ "$MARKER_AFTER" != "should-not-land" ] \
	|| fail check_secret_path_mismatch_refused "the refused value landed in the fixed slot anyway"
ubus call hermes status 2>/dev/null | grep -q '"provider_key_managed": false' \
	|| fail check_secret_path_mismatch_refused "status still reports the key as page-managed"
ubus call hermes status 2>/dev/null | grep -q '"provider_key_set": false' \
	|| fail check_secret_path_mismatch_refused "status does not follow the UCI-configured path"
# And the other way round: a key at the UCI path shows as set even though the slot this
# page writes is unchanged, so the status follows the service and not the page.
printf '%s' 'sk-elsewhere-canary' > /tmp/elsewhere.key
ubus call hermes status 2>/dev/null | grep -q '"provider_key_set": true' \
	|| fail check_secret_path_mismatch_refused "status does not see a key at the UCI-configured path"
rm -f /tmp/elsewhere.key
uci -q delete hermes.main.key_file
uci commit hermes
echo "PASS check_secret_path_mismatch_refused"

# ---- 12. a further provider's key lands 0600 in its own slot ----
# provider:<section> is the slot, /etc/hermes-agent/<section>.key the file, and the
# page writes it while it saves the section, so a section not committed yet is fine.
PCANARY=sk-luci-gate-provider-canary
uci set hermes.claude=provider; uci set hermes.claude.base_url=https://api.anthropic.com/v1
uci set hermes.claude.model=claude-haiku-4-5; uci commit hermes
out=$(ubus call hermes set_secret "{\"name\":\"provider:claude\",\"value\":\"  $PCANARY  \"}" 2>&1)
echo "$out" | grep -q '"ok": true' || { echo "$out"; fail check_provider_key_written_0600 "set_secret refused a provider slot"; }
mode=$(ls -l /etc/hermes-agent/claude.key | awk '{print $1}')
[ "$mode" = "-rw-------" ] || fail check_provider_key_written_0600 "mode is $mode, want -rw------- (0600)"
[ "$(cat /etc/hermes-agent/claude.key)" = "$PCANARY" ] || fail check_provider_key_written_0600 "the value was not trimmed"
st=$(ubus call hermes status 2>/dev/null)
[ "$(echo "$st" | jsonfilter -e '@.provider_keys.claude.set')" = true ] || fail check_provider_key_written_0600 "status does not report the stored key"
[ "$(echo "$st" | jsonfilter -e '@.provider_keys.claude.managed')" = true ] || fail check_provider_key_written_0600 "status does not report the slot as managed"
for m in status logs; do
	ubus call hermes "$m" 2>/dev/null | grep -q "$PCANARY" && fail check_provider_key_written_0600 "the $m method returned a provider key"
done
out=$(ubus call hermes set_secret '{"name":"provider:fresh","value":"sk-fresh"}' 2>&1)
echo "$out" | grep -q '"ok": true' || { echo "$out"; fail check_provider_key_written_0600 "a key for a section being saved in the same pass was refused"; }
rm -f /etc/hermes-agent/fresh.key
echo "PASS check_provider_key_written_0600"

# ---- 13. a crafted provider slot is refused and writes nothing ----
before=$(ls -A /etc/hermes-agent | sort | tr '\n' ' ')
for name in 'provider:../escape' 'provider:Bad' 'provider:provider' 'provider:' 'provider:a/b' 'provider:-x'; do
	out=$(ubus call hermes set_secret "{\"name\":\"$name\",\"value\":\"sk-crafted\"}" 2>&1) || true
	echo "$out" | grep -q '"ok": false' || { echo "$out"; fail check_provider_key_name_refused "$name was accepted"; }
done
[ -e /etc/escape.key ] && fail check_provider_key_name_refused "a key was written outside /etc/hermes-agent"
[ "$(ls -A /etc/hermes-agent | sort | tr '\n' ' ')" = "$before" ] || fail check_provider_key_name_refused "a refused name still wrote a file"
echo "PASS check_provider_key_name_refused"

# ---- 14. a provider whose key_file points elsewhere is refused, like the main key ----
uci set hermes.claude.key_file=/tmp/elsewhere-claude.key; uci commit hermes
out=$(ubus call hermes set_secret '{"name":"provider:claude","value":"should-not-land"}' 2>&1) || true
echo "$out" | grep -q '"ok": false' || { echo "$out"; fail check_provider_key_path_mismatch_refused "set_secret did not refuse"; }
[ -e /tmp/elsewhere-claude.key ] && fail check_provider_key_path_mismatch_refused "a value was written to the mismatched path"
[ "$(ubus call hermes status | jsonfilter -e '@.provider_keys.claude.managed')" = false ] \
	|| fail check_provider_key_path_mismatch_refused "status still reports the slot as managed"
uci -q delete hermes.claude; uci commit hermes; rm -f /etc/hermes-agent/claude.key
echo "PASS check_provider_key_path_mismatch_refused"

# ---- 15. ChatGPT sign-in from the page ----
# hermes-login is replaced by a stand-in that prints what upstream's device-code flow
# prints and waits for a marker instead of a browser. The call has to return at once,
# the status has to carry the address and the code, and the result has to follow the
# data directory's auth.json, which is all the page ever reads of it.
cp /usr/sbin/hermes-login /tmp/hermes-login.real
cat > /usr/sbin/hermes-login <<'STUB'
#!/bin/sh
if [ "${2:-}" = "--logout" ]; then rm -f /srv/hermes/auth.json; echo "hermes-login: ChatGPT is signed out."; exit 0; fi
echo "To continue, follow these steps:"
echo "  1. Open this URL in your browser:"
printf '     \033[94mhttps://auth.openai.com/codex/device\033[0m\n'
echo "  2. Enter this code:"
printf '     \033[94mGATE-TEST1\033[0m\n'
echo "Waiting for sign-in..."
while [ ! -e /tmp/gate-approve ]; do sleep 1; done
mkdir -p /srv/hermes
echo '{"providers": {"openai-codex": {"tokens": {}}}}' > /srv/hermes/auth.json
echo "hermes-login: ChatGPT is signed in; /model in a chat now offers it."
STUB
chmod 0755 /usr/sbin/hermes-login
gpt_fail() { fail check_chatgpt_sign_in_from_the_page "$1"; }
[ "$(ubus call hermes status | jsonfilter -e '@.chatgpt_signed_in')" = false ] || gpt_fail "signed in before any sign-in"
out=$(ubus -t 10 call hermes chatgpt_login 2>&1) || gpt_fail "the call did not return; the sign-in is not detached ($out)"
echo "$out" | grep -q '"ok": true' || { echo "$out"; gpt_fail "the sign-in did not start"; }
i=0; while [ "$i" -lt 15 ]; do
	st=$(ubus call hermes chatgpt_login_status 2>/dev/null)
	[ "$(echo "$st" | jsonfilter -e '@.state')" = waiting ] && break
	sleep 1; i=$((i + 1))
done
[ "$(echo "$st" | jsonfilter -e '@.code')" = GATE-TEST1 ] || { echo "$st"; gpt_fail "status does not carry the code"; }
[ "$(echo "$st" | jsonfilter -e '@.url')" = https://auth.openai.com/codex/device ] || { echo "$st"; gpt_fail "status does not carry the address"; }
touch /tmp/gate-approve
i=0; while [ "$i" -lt 15 ]; do
	[ "$(ubus call hermes chatgpt_login_status | jsonfilter -e '@.state')" = done ] && break
	sleep 1; i=$((i + 1))
done
[ "$i" -lt 15 ] || gpt_fail "the finished sign-in was never reported as done"
[ "$(ubus call hermes status | jsonfilter -e '@.chatgpt_signed_in')" = true ] || gpt_fail "status does not follow the signed-in auth.json"
out=$(ubus call hermes chatgpt_logout 2>&1)
echo "$out" | grep -q '"ok": true' || { echo "$out"; gpt_fail "signing out failed"; }
[ "$(ubus call hermes status | jsonfilter -e '@.chatgpt_signed_in')" = false ] || gpt_fail "still signed in after signing out"
cp /tmp/hermes-login.real /usr/sbin/hermes-login; rm -f /tmp/gate-approve /tmp/hermes-login.log /tmp/hermes-login.pid
echo "PASS check_chatgpt_sign_in_from_the_page"

# ---- 16. an upgrade restarts rpcd, like an install does ----
# rpcd reads each plugin's method list once, at start. apk runs post-install on a new
# install only and post-upgrade on an upgrade, so a package with post-install alone
# left every router that upgraded with the previous method list: on the Brume 2 and the
# Flint 2 on 2026-09-25, r6 to r7 left the Providers page's ChatGPT calls answering
# "Method not found" until rpcd was restarted by hand. opkg's postinst runs on both.
if command -v apk >/dev/null; then
	apk adbdump /luci.apk 2>/dev/null | awk '/^  post-upgrade:/ {f = 1; next} /^  [a-z-]+:/ {f = 0} f' > /tmp/post-upgrade
	grep -q 'rpcd restart' /tmp/post-upgrade || fail check_upgrade_restarts_rpcd "the package has no post-upgrade script that restarts rpcd"
fi
echo "PASS check_upgrade_restarts_rpcd"

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

# Counted from $CHECKS itself, the same way --selftest counts them, so this line
# cannot go stale the next time a check is added or removed here.
n=0; for c in $CHECKS; do n=$((n + 1)); done
echo "gate-luci: all $n checks passed"
