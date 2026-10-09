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
# Since LuCI r13 the Security page's backend is checked here too: status as facts only, the
# factor refused unless what it needs exists, every Security call refused outside the owner
# profile, and the page's calls held to the read and write blocks. The enrolment itself, the QR
# decoded and the PIN followed through the router, is scripts/gate-unlock.sh, against the real
# openwrt-mcp and the real daemon.
#
# What this does NOT check is the rendered page. LuCI in a bare rootfs container needs a
# session, a theme and a ubus session object before it will render anything at all, and
# standing that up would test the container far more than it tests this app. What is
# checked instead is everything the browser depends on: the files land where luci-base
# looks, the JS parses, the menu and ACL are valid JSON, the ubus object exists, and the
# calls the pages make return what the pages expect.
set -eu

CHECKS='check_installs check_files_land check_json_valid check_js_parses check_ubus_object check_status_answers check_status_reads_version_from_disk check_free_space_before_first_start check_secret_written_0600 check_secret_never_returned check_telegram_state_reported check_read_acl_is_narrow check_secret_write_failure_reported check_secret_path_mismatch_refused check_provider_key_written_0600 check_provider_key_name_refused check_provider_key_path_mismatch_refused check_chatgpt_sign_in_from_the_page check_upgrade_restarts_rpcd check_removed_provider_takes_its_key check_messages_survive_the_reload check_saved_when_only_a_key_changed check_stale_message_not_shown check_profile_field_defaults_to_owner check_security_status_reports_facts_only check_security_factor_never_outruns_what_exists check_security_factor_announced_when_reload_cannot_tell check_security_packages_written_only_with_a_factor check_security_refused_outside_the_owner_profile check_security_page_calls_are_granted check_security_pin_fields_never_prefilled check_security_pin_saved_points_to_the_factor check_security_qr_shown_once check_security_factor_needs_its_prerequisite check_security_page_offers_nothing_it_cannot_do check_security_packages_switch_needs_a_factor check_clean_removal'

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
# hermes-agent depends on openwrt-mcp (0.21.5-r3), which is not in OpenWrt's feed.
MCP=${MCP:-$("$ROOT/scripts/mcp-apk.sh" "$ARCH")} || exit 1

# The JS never reaches the router's shell, so it is parsed here rather than there. A
# syntax error would otherwise reach a browser as a blank page with a console message
# nobody is looking at.
echo "-- parsing the views --"
for f in "$ROOT"/package/luci-app-hermes/htdocs/luci-static/resources/view/hermes/*.js \
         "$ROOT"/package/luci-app-hermes/htdocs/luci-static/resources/hermes/*.js; do
	docker run --rm -v "$f:/x.js:ro" node:22-alpine node --check /x.js \
		|| { echo "FAIL check_js_parses: $(basename "$f") does not parse"; exit 1; }
done
echo "PASS check_js_parses ($(ls "$ROOT"/package/luci-app-hermes/htdocs/luci-static/resources/view/hermes/*.js | wc -l | tr -d ' ') views, $(ls "$ROOT"/package/luci-app-hermes/htdocs/luci-static/resources/hermes/*.js | wc -l | tr -d ' ') module)"

# The installed web root comes back out of the container here, for the view checks
# after it: what they load is what the package put on the router.
WWW=$(mktemp -d "${TMPDIR:-/tmp}/gate-luci-www.XXXXXX")
trap 'rm -rf "$WWW"' EXIT

echo "-- container checks: $IMAGE ($PLATFORM) --"
# -i is load-bearing: without it docker hands `sh -s` an empty stdin, nothing runs, the
# container exits 0, and this gate passes having measured nothing.
docker run -v "$ROOT/scripts/apk-retry.sh:/apk-retry.sh:ro" ${APK_CACHE:+-v "$APK_CACHE:/apk-cache"} --rm -i --platform "$PLATFORM" \
	-v "$AGENT:/agent.apk:ro" -v "$LUCI:/luci.apk:ro" -v "$MCP:/mcp.apk:ro" -v "$WWW:/out" \
	"$IMAGE" /bin/sh -s <<'CONTAINER'
. /apk-retry.sh  # apk retries a download the feed cut off; see the file
set -eu
fail() { echo "FAIL $1: $2"; exit 1; }
CANARY=sk-luci-gate-canary

mkdir -p /var/lock /var/run /var/state
apk update -q
apk add -q --allow-untrusted /agent.apk /mcp.apk >/dev/null 2>&1
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
         /www/luci-static/resources/view/hermes/security.js \
         /www/luci-static/resources/hermes/flash.js \
         /usr/share/luci/menu.d/luci-app-hermes.json \
         /usr/share/rpcd/acl.d/luci-app-hermes.json \
         /usr/libexec/rpcd/hermes; do
	[ -e "$f" ] || fail check_files_land "missing: $f"
done
[ -x /usr/libexec/rpcd/hermes ] || fail check_files_land "the rpcd backend is not executable"
echo "PASS check_files_land"
# Readable by the host user that removes it again, which on a Linux runner is not root.
mkdir -p /out/luci-static/resources
cp -a /www/luci-static/resources/view /www/luci-static/resources/hermes /out/luci-static/resources/
chmod -R a+rwX /out

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

# ---- 5a. the version comes from the disk, and asking starts nothing ----
# Until LuCI r8 status ran `hermes --version`: Python, all of Hermes imported, and a
# network check for a newer upstream release, 4 s on a Brume 2 (2026-09-25) for every
# page load. /usr/bin/hermes is replaced by a stand-in that leaves a mark and sleeps;
# the answer has to be the version pip recorded, with no mark and no wait.
ver_fail() { fail check_status_reads_version_from_disk "$1"; }
META=$(ls /usr/lib/hermes-agent/site-packages/hermes_agent-*.dist-info/METADATA 2>/dev/null | head -n1)
[ -f "$META" ] || ver_fail "the agent package carries no hermes_agent METADATA to read; measured nothing"
want="Hermes Agent v$(sed -n 's/^Version: *//p' "$META" | head -n1)"
cp /usr/bin/hermes /tmp/hermes.real
printf '#!/bin/sh\ntouch /tmp/hermes-was-run\nsleep 5\necho "Hermes Agent v9.9.9"\n' > /usr/bin/hermes
t0=$(date +%s)
got=$(ubus -t 30 call hermes status | jsonfilter -e '@.version')
took=$(( $(date +%s) - t0 ))
[ "$got" = "$want" ] || ver_fail "status reports '$got', the installed METADATA says '$want'"
[ -e /tmp/hermes-was-run ] && ver_fail "status ran /usr/bin/hermes"
[ "$took" -le 2 ] || ver_fail "status took $took s"
mv "$META" "$META.aside"
got=$(ubus call hermes status | jsonfilter -e '@.version')
mv "$META.aside" "$META"
[ "$got" = "not installed" ] || ver_fail "with no METADATA, status reports '$got'"
cp /tmp/hermes.real /usr/bin/hermes; rm -f /tmp/hermes.real /tmp/hermes-was-run
echo "PASS check_status_reads_version_from_disk"

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
# And no program the backend runs while it writes one is handed the key, in its arguments or in
# its environment. jshn's json_load puts the whole message on a `jshn` command line, which any
# account on the router can read from /proc, and json_get_var exports what it reads to every
# program started after it: both held the key until LuCI r13. Recorders stand in front of the
# programs that could be handed it and write down each start, its arguments and its environment.
for f in /usr/bin/jshn /usr/bin/jsonfilter /sbin/uci; do
	mv "$f" "$f.real"
	{ echo '#!/bin/sh'
	  echo "{ printf 'ARGV %s' \"\$0\"; for a in \"\$@\"; do printf ' %s' \"\$a\"; done; printf '\\n'; env; printf 'END\\n'; } >> /tmp/shim.log"
	  echo "exec $f.real \"\$@\""; } > "$f"
	chmod 755 "$f"
done
: > /tmp/shim.log
LEAK=sk-luci-gate-leak-canary-47213
ubus call hermes set_secret "{\"name\":\"provider\",\"value\":\"$LEAK\"}" >/dev/null 2>&1 || fail check_secret_never_returned "set_secret failed under the recorders"
for f in /usr/bin/jshn /usr/bin/jsonfilter /sbin/uci; do mv -f "$f.real" "$f"; done
grep -q '^ARGV /usr/bin/jsonfilter' /tmp/shim.log || fail check_secret_never_returned "the recorders saw no program run, so the key's absence from them proves nothing"
if grep -q "$LEAK" /tmp/shim.log; then fail check_secret_never_returned "the key was in the arguments or the environment of a program the backend ran: $(grep -B1 -m1 "$LEAK" /tmp/shim.log | head -c 160)"; fi
rm -f /tmp/shim.log
printf '%s' "$CANARY" > /etc/hermes-agent/provider.key
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
# Three, since the Security page (LuCI r13): security_status answers facts only, never a secret
# and never the QR, so it may be read by a session that cannot write. Everything that writes a
# PIN or a secret, or returns enrolment material, is in the write block, and
# check_security_page_calls_are_granted holds the page's own calls to that split.
[ "$#" -eq 3 ] || acl_fail "read.ubus.hermes grants $# methods ($hermes_methods), want status, logs and security_status"
case " $hermes_methods " in *" status "*) ;; *) acl_fail "status missing from read.ubus.hermes" ;; esac
case " $hermes_methods " in *" logs "*) ;;   *) acl_fail "logs missing from read.ubus.hermes" ;; esac
case " $hermes_methods " in *" security_status "*) ;; *) acl_fail "security_status missing from read.ubus.hermes" ;; esac
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


# ---- 17. the Security page's status: facts, and never a secret ----
# What the page reads to say what is in force. The PIN, a phone's secret and the QR are not facts
# about the router, they are credentials, so none of them is in this reply, and the answer follows
# the real openwrt-mcp rather than being made up from the page's own state. Where there is nothing
# to follow (no client, no binary, a profile this does not apply to) it says so, and offers nothing.
sf() { fail check_security_status_reports_facts_only "$1"; }
MCP=/usr/bin/openwrt-mcp
# The agent's own start pairs this client; the gate pairs it directly.
rm -rf /etc/openwrt-mcp/pin /etc/openwrt-mcp/mfa*
$MCP unpair hermes-main >/dev/null 2>&1 || true
$MCP pair hermes-main >/dev/null 2>&1 || sf "could not pair a hermes-main client to read about"
uci set hermes.main.profile=owner; uci set hermes.security.factor=none; uci set hermes.security.window=15m
uci set hermes.security.max_failures=5; uci set hermes.security.lockout=15m; uci commit hermes
sec_get() { ubus call hermes security_status 2>/dev/null; }
want() { # <json> <path> <value>
	got=$(echo "$1" | jsonfilter -e "@.$2")
	[ "$got" = "$3" ] || { echo "$1" | head -c 600; sf "$2 is '$got', want '$3'"; }
}
st=$(sec_get) || sf "the call failed"
want "$st" profile owner; want "$st" applies true; want "$st" mcp_ok true; want "$st" paired true
want "$st" factor none; want "$st" factor_ready true; want "$st" window 15m; want "$st" max_failures 5; want "$st" lockout 15m
want "$st" pin_set false; want "$st" totp_enrolled false; want "$st" totp_pending false; want "$st" packages off
# Exactly these facts and no other key: a debugging field added later is the way a secret gets in.
keys_of() { ( set +u; . /usr/share/libubox/jshn.sh; json_load "$1"; json_get_keys k; echo "$k" | tr ' ' '\n' | sort | tr '\n' ' ' ); }
[ "$(keys_of "$st")" = "applies factor factor_ready lockout max_failures mcp_ok packages paired pin_set profile totp_enrolled totp_pending window " ] \
	|| sf "the reply carries other keys than the facts: $(keys_of "$st")"
# It follows what openwrt-mcp holds.
SECRETPIN=73195028
printf '%s\n' "$SECRETPIN" | $MCP pin set hermes-main >/dev/null || sf "could not set a PIN"
st=$(sec_get); want "$st" pin_set true; want "$st" totp_enrolled false
j=$($MCP mfa enrol hermes-main --pending --json); SECRET=$(echo "$j" | jsonfilter -e '@.secret'); URI=$(echo "$j" | jsonfilter -e '@.uri')
st=$(sec_get); want "$st" totp_pending true; want "$st" totp_enrolled false
$MCP mfa enrol hermes-main >/dev/null || sf "could not enrol"
st=$(sec_get); want "$st" totp_enrolled true
# No secret in it, whatever state it is in.
for needle in "$SECRETPIN" "$SECRET" "$URI" 'otpauth' 'pbkdf2'; do
	if echo "$st" | grep -q "$needle"; then sf "the status reply holds '$needle'"; fi
done
ubus call hermes status 2>/dev/null | grep -q "$SECRETPIN" && sf "status holds the PIN"
# It follows UCI, and a factor that is not one is not passed off as one.
uci set hermes.security.factor=pin; uci set hermes.security.window=1h; uci set hermes.security.max_failures=3; uci set hermes.security.lockout=2h; uci commit hermes
st=$(sec_get); want "$st" factor pin; want "$st" window 1h; want "$st" max_failures 3; want "$st" lockout 2h; want "$st" factor_ready true
uci set hermes.security.factor=bogus; uci commit hermes
st=$(sec_get); want "$st" factor invalid; want "$st" factor_ready false
# What the factor needs, not whether something is enrolled: pin+totp with the PIN gone is not ready.
uci set hermes.security.factor=pin+totp; uci commit hermes
st=$(sec_get); want "$st" factor_ready true
$MCP pin clear hermes-main >/dev/null; st=$(sec_get); want "$st" factor_ready false; want "$st" pin_set false
# No client, no answer: a PIN stored for a client that is not paired is not reported as set.
printf '%s\n' "$SECRETPIN" | $MCP pin set hermes-main >/dev/null
$MCP unpair hermes-main >/dev/null
st=$(sec_get); want "$st" paired false; want "$st" pin_set false; want "$st" totp_enrolled false; want "$st" mcp_ok true
$MCP pair hermes-main >/dev/null
# No openwrt-mcp, no answer.
mv /usr/bin/openwrt-mcp /usr/bin/openwrt-mcp.aside
st=$(sec_get); mv /usr/bin/openwrt-mcp.aside /usr/bin/openwrt-mcp
want "$st" mcp_ok false; want "$st" paired false; want "$st" pin_set false
# Profiles: owner is the default and the only one this applies to; admin is root's old name.
uci -q delete hermes.main.profile; uci commit hermes; st=$(sec_get); want "$st" profile owner; want "$st" applies true
for pair in root:root:false admin:root:false assistant:assistant:false nonsense:invalid:false; do
	prof=${pair%%:*}; rest=${pair#*:}; shown=${rest%%:*}; applies=${rest#*:}
	uci set hermes.main.profile=$prof; uci commit hermes
	st=$(sec_get); want "$st" profile "$shown"; want "$st" applies "$applies"
done
uci set hermes.main.profile=owner; uci commit hermes
rm -rf /etc/openwrt-mcp/pin /etc/openwrt-mcp/mfa*; $MCP unpair hermes-main >/dev/null 2>&1 || true
echo "PASS check_security_status_reports_facts_only"

# ---- 18. the factor can only be set to what exists ----
# The owner who chooses PIN with none set, or an app code before a phone is enrolled, would be
# refused every unlock by their own router. So set_factor refuses what the page's own radio
# buttons would not offer, and writes nothing when it refuses: not the factor, not the window,
# not another page's staged changes along with it. Clearing the PIN a factor needs is the same
# lock-out from the other side.
ff() { fail check_security_factor_never_outruns_what_exists "$1"; }
$MCP unpair hermes-main >/dev/null 2>&1 || true; $MCP pair hermes-main >/dev/null || ff "could not pair"
uci set hermes.main.profile=owner; uci set hermes.security.factor=none; uci set hermes.security.window=15m
uci set hermes.security.max_failures=5; uci set hermes.security.lockout=15m; uci commit hermes
# The reload trigger, observed where procd hears it. A new factor reaches the openwrt-mcp
# policies only when procd is told `config.change` for hermes and restarts the agent. There is
# no procd here, so an rpcd stand-in answers as its `service` object and writes down every
# event, and the real /sbin/reload_config runs against it. LuCI r13 ran only reload_config,
# whose first run after a boot keeps a copy of every config and tells nobody, so the first
# factor chosen after a boot stayed out of the policies until a restart (a Brume 2, 2026-10-02).
service_standin() {
	cat > /usr/libexec/rpcd/service <<'SVC'
#!/bin/sh
case "$1" in
	list) echo '{"event":{"type":"str","data":{}}}' ;;
	call) [ "$2" = event ] && { cat >> /tmp/service-events; echo >> /tmp/service-events; echo '{}'; } ;;
esac
SVC
	chmod 755 /usr/libexec/rpcd/service
	killall rpcd 2>/dev/null; sleep 1; rpcd >/dev/null 2>&1 & sleep 2
	ubus list 2>/dev/null | grep -qx service || fail "$1" "the procd stand-in did not come up"
	rm -f /tmp/service-events
}
service_standin_gone() {
	rm -f /usr/libexec/rpcd/service /tmp/service-events
	killall rpcd 2>/dev/null; sleep 1; rpcd >/dev/null 2>&1 & sleep 2
}
hermes_events() { [ -f /tmp/service-events ] || { echo 0; return; }; grep -c '"package" *: *"hermes"' /tmp/service-events || true; }
service_standin check_security_factor_never_outruns_what_exists
# As after a boot: reload_config has not run yet, so it has no copy to compare with.
rm -f /var/run/config.md5
sf_call() { # <factor> <window> <max failures> <lockout>
	ubus call hermes set_factor "{\"factor\":\"$1\",\"window\":\"$2\",\"max_failures\":$3,\"lockout\":\"$4\"}" 2>&1
}
refused() { # <what> <call output>
	echo "$2" | grep -q '"ok": false' || { echo "$2"; ff "$1 was accepted"; }
}
snap() { md5sum /etc/config/hermes | cut -d' ' -f1; }
before=$(snap)
refused "pin with no PIN set" "$(sf_call pin 15m 5 15m)"
refused "totp with no phone" "$(sf_call totp 15m 5 15m)"
refused "pin+totp with neither" "$(sf_call pin+totp 15m 5 15m)"
printf '%s\n' 4821 | $MCP pin set hermes-main >/dev/null
refused "totp with a PIN but no phone" "$(sf_call totp 15m 5 15m)"
refused "pin+totp with a PIN but no phone" "$(sf_call pin+totp 15m 5 15m)"
$MCP mfa enrol hermes-main --pending --json >/dev/null
refused "totp with a phone only pending" "$(sf_call totp 15m 5 15m)"
refused "a factor that is not one" "$(sf_call sms 15m 5 15m)"
refused "a window without a unit" "$(sf_call pin 15 5 15m)"
refused "an empty window" "$(sf_call pin '' 5 15m)"
refused "a window in words" "$(sf_call pin '15 minutes' 5 15m)"
refused "no failures allowed" "$(sf_call pin 15m 0 15m)"
refused "a negative count" "$(sf_call pin 15m -1 15m)"
refused "a hundred failures" "$(sf_call pin 15m 100 15m)"
refused "a lockout in the wrong unit" "$(sf_call pin 15m 5 1x)"
refused "an empty lockout" "$(sf_call pin 15m 5 '')"
refused "a command in the window" "$(sf_call pin '$(id)' 5 15m)"
refused "a second command in the window" "$(sf_call pin '15m;reboot' 5 15m)"
sleep 1
[ "$(snap)" = "$before" ] || ff "a refused set_factor changed /etc/config/hermes"
[ "$(hermes_events)" = 0 ] || ff "a refused set_factor still told procd the config changed"
[ "$(uci -q get hermes.security.factor)" = none ] || ff "the factor is $(uci -q get hermes.security.factor) after only refusals"
# What is allowed: none always, pin with the PIN, and nothing else yet.
out=$(sf_call pin 20m 3 1h); echo "$out" | grep -q '"ok": true' || { echo "$out"; ff "pin with a PIN set was refused"; }
[ "$(uci -q get hermes.security.factor)" = pin ] && [ "$(uci -q get hermes.security.window)" = 20m ] \
	&& [ "$(uci -q get hermes.security.max_failures)" = 3 ] && [ "$(uci -q get hermes.security.lockout)" = 1h ] || ff "the accepted choice is not what was asked for"
grep -q "option factor 'pin'" /etc/config/hermes || ff "the accepted choice was not committed to /etc/config/hermes"
i=0; while [ "$(hermes_events)" = 0 ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
[ "$(hermes_events)" -ge 1 ] || ff "the first choice after a boot did not tell procd hermes changed, so the policies would keep the old factor until a restart"
sleep 1; [ "$(hermes_events)" = 1 ] || ff "one choice told procd $(hermes_events) times, so the agent restarts more than once"
# And once reload_config has its copy: still told, and still once.
[ -f /var/run/config.md5 ] || ff "reload_config did not run, so LuCI's next apply restarts the agent again for this change"
rm -f /tmp/service-events
out=$(sf_call none 20m 3 1h); echo "$out" | grep -q '"ok": true' || { echo "$out"; ff "none was refused"; }
i=0; while [ "$(hermes_events)" = 0 ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
sleep 1; [ "$(hermes_events)" = 1 ] || ff "a later choice told procd $(hermes_events) times instead of once"
# Activating the phone opens the rest.
code=$(python3 - <<'PY'
import base64, hashlib, hmac, struct, subprocess, time, json
j = json.loads(subprocess.run(["/usr/bin/openwrt-mcp", "mfa", "enrol", "hermes-main", "--pending", "--json"], capture_output=True, text=True).stdout)
s = j["secret"]; key = base64.b32decode(s + "=" * (-len(s) % 8))
h = hmac.new(key, struct.pack(">Q", int(time.time() // 30)), hashlib.sha1).digest(); o = h[-1] & 15
print("%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** 6))
PY
) || ff "could not make a code"
$MCP mfa activate hermes-main "$code" >/dev/null || ff "could not activate the phone"
for f in totp pin+totp none; do
	out=$(sf_call "$f" 15m 5 15m); echo "$out" | grep -q '"ok": true' || { echo "$out"; ff "$f was refused with a PIN and an active phone"; }
	[ "$(uci -q get hermes.security.factor)" = "$f" ] || ff "factor $f was not written"
done
# Another page's staged edits are not committed along with this one.
uci set hermes.main.max_turns=33
out=$(sf_call pin 15m 5 15m); echo "$out" | grep -q '"ok": true' || ff "set_factor refused with a LuCI edit staged"
grep -q "max_turns '33'" /etc/config/hermes && ff "set_factor committed another page's staged change (max_turns 33) with its own"
[ -n "$(uci changes hermes)" ] || ff "set_factor swallowed another page's staged change instead of leaving it staged"
uci revert hermes
# The PIN the factor needs cannot be cleared; one it does not need can.
for f in pin pin+totp; do
	uci set hermes.security.factor=$f; uci commit hermes
	out=$(ubus call hermes clear_pin 2>&1); echo "$out" | grep -q '"ok": false' || { echo "$out"; ff "clear_pin was accepted with the factor $f"; }
	[ "$(ubus call hermes security_status | jsonfilter -e '@.pin_set')" = true ] || ff "the PIN was cleared although the factor is $f"
done
for f in none totp; do
	printf '%s\n' 4821 | $MCP pin set hermes-main >/dev/null
	uci set hermes.security.factor=$f; uci commit hermes
	out=$(ubus call hermes clear_pin 2>&1); echo "$out" | grep -q '"ok": true' || { echo "$out"; ff "clear_pin was refused with the factor $f"; }
	[ "$(ubus call hermes security_status | jsonfilter -e '@.pin_set')" = false ] || ff "the PIN was not cleared with the factor $f"
done
service_standin_gone
rm -rf /etc/openwrt-mcp/pin /etc/openwrt-mcp/mfa*; $MCP unpair hermes-main >/dev/null 2>&1 || true
uci set hermes.security.factor=none; uci commit hermes
echo "PASS check_security_factor_never_outruns_what_exists"

# ---- 18b. a choice reaches the agent when reload_config cannot tell procd ----
# reload_config tells procd only about a config whose sum it holds and whose content has changed
# since. Two states on 2026-10-08 (LuCI 0.21.5-r1) left it nothing to tell, and the page said
# "Saved" while the agent kept the old factor: its file had no line for hermes (it had run while
# /etc/config/hermes did not exist, as after a reinstall; reproduced on a Flint 2 by deleting the
# line), and its line for hermes already held the sum of the new content (a Beryl AX). In both,
# set_factor tells procd itself, once; and once reload_config can tell, set_factor does not.
fr() { fail check_security_factor_announced_when_reload_cannot_tell "$1"; }
$MCP unpair hermes-main >/dev/null 2>&1 || true; $MCP pair hermes-main >/dev/null || fr "could not pair"
printf '%s\n' 4821 | $MCP pin set hermes-main >/dev/null || fr "could not set a PIN"
uci set hermes.main.profile=owner; uci set hermes.security.factor=none; uci set hermes.security.window=15m
uci set hermes.security.max_failures=5; uci set hermes.security.lockout=15m; uci commit hermes
service_standin check_security_factor_announced_when_reload_cannot_tell
told_once() { # <what>
	i=0; while [ "$(hermes_events)" = 0 ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
	sleep 1; [ "$(hermes_events)" = 1 ] || fr "$1: procd was told $(hermes_events) times that hermes changed, not once"
}
hermes_line() { grep -c '[[:space:]]/var/run/config.check/hermes$' /var/run/config.md5 2>/dev/null || true; }
# a. the md5 file is there, without a line for hermes
/sbin/reload_config >/dev/null 2>&1 < /dev/null
[ -f /var/run/config.md5 ] || fr "reload_config kept no md5 file, so this measured nothing"
sed -i '\|/var/run/config.check/hermes$|d' /var/run/config.md5
[ "$(hermes_line)" = 0 ] || fr "the hermes line is still in the md5 file, so this measured nothing"
rm -f /tmp/service-events
out=$(sf_call pin 15m 5 15m); echo "$out" | grep -q '"ok": true' || { echo "$out"; fr "pin with a PIN set was refused"; }
told_once "an md5 file without a hermes line"
[ "$(hermes_line)" = 1 ] || fr "after the call reload_config's file still has no line for hermes, so the next apply is silent too"
# b. the line for hermes already holds the sum of what the call will leave
uci set hermes.security.factor=none; uci commit hermes
out=$(sf_call none 15m 5 15m); echo "$out" | grep -q '"ok": true' || { echo "$out"; fr "none was refused"; }
/sbin/reload_config >/dev/null 2>&1 < /dev/null
[ "$(grep '[[:space:]]/var/run/config.check/hermes$' /var/run/config.md5 | cut -d' ' -f1)" = "$(uci show hermes 2>/dev/null | md5sum | cut -d' ' -f1)" ] \
	|| fr "the snapshot's hermes sum is not that of the content, so this measured nothing"
rm -f /tmp/service-events
out=$(sf_call none 15m 5 15m); echo "$out" | grep -q '"ok": true' || { echo "$out"; fr "none was refused"; }
told_once "a snapshot whose hermes sum already matches"
# c. the control: an ordinary change with a stale sum is told by reload_config, and not again
rm -f /tmp/service-events
out=$(sf_call pin 20m 5 15m); echo "$out" | grep -q '"ok": true' || { echo "$out"; fr "pin was refused"; }
told_once "an ordinary change"
service_standin_gone
rm -rf /etc/openwrt-mcp/pin /etc/openwrt-mcp/mfa*; $MCP unpair hermes-main >/dev/null 2>&1 || true
uci set hermes.security.factor=none; uci set hermes.security.window=15m; uci commit hermes
echo "PASS check_security_factor_announced_when_reload_cannot_tell"

# ---- 18c. the owner's opt-in to package installs: official only with a factor, nothing else ----
# hermes.security.packages is off unless the owner turns it on, and official (the official OpenWrt
# feed) is the only other value. An install waits for an unlock like any change, so official is
# refused while no factor is in force: the agent's start would write no package policy, and the
# switch would promise what nothing honours. Off is always allowed. It is written the way set_factor
# writes, without another LuCI session's staged changes, and procd is told once.
pk() { fail check_security_packages_written_only_with_a_factor "$1"; }
$MCP unpair hermes-main >/dev/null 2>&1 || true; $MCP pair hermes-main >/dev/null || pk "could not pair"
printf '%s\n' 4821 | $MCP pin set hermes-main >/dev/null || pk "could not set a PIN"
uci set hermes.main.profile=owner; uci set hermes.security.factor=none; uci -q delete hermes.security.packages; uci commit hermes
service_standin check_security_packages_written_only_with_a_factor
sp_call() { ubus call hermes set_packages "{\"packages\":\"$1\"}" 2>&1; }
pkg_state() { ubus call hermes security_status 2>/dev/null | jsonfilter -e '@.packages'; }
[ "$(pkg_state)" = off ] || pk "with nothing set security_status reads packages '$(pkg_state)', not off"
before=$(md5sum < /etc/config/hermes)
out=$(sp_call official); echo "$out" | grep -q '"ok": false' || { echo "$out"; pk "official was accepted with no factor in force"; }
echo "$out" | grep -qi 'factor' || pk "the refusal of official with no factor does not name the factor: $out"
for v in yes on all Official '' '$(id)' 'official;reboot' 'official --allow-untrusted'; do
	out=$(sp_call "$v"); echo "$out" | grep -q '"ok": false' || { echo "$out"; pk "packages '$v' was accepted"; }
done
sleep 1
[ "$(md5sum < /etc/config/hermes)" = "$before" ] || pk "a refused set_packages changed /etc/config/hermes"
[ "$(hermes_events)" = 0 ] || pk "a refused set_packages told procd the config changed"
[ -z "$(uci -q get hermes.security.packages)" ] || pk "after only refusals packages is $(uci -q get hermes.security.packages)"
# With a factor in force: official is written, committed and announced once.
uci set hermes.security.factor=pin; uci commit hermes
rm -f /tmp/service-events
out=$(sp_call official); echo "$out" | grep -q '"ok": true' || { echo "$out"; pk "official was refused with the factor pin in force"; }
[ "$(uci -q get hermes.security.packages)" = official ] || pk "official was answered ok and not written"
grep -q "option packages 'official'" /etc/config/hermes || pk "official was not committed to /etc/config/hermes"
[ "$(uci -q get hermes.security.factor)" = pin ] || pk "writing packages changed the factor to $(uci -q get hermes.security.factor)"
i=0; while [ "$(hermes_events)" = 0 ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
sleep 1; [ "$(hermes_events)" = 1 ] || pk "one switch told procd $(hermes_events) times that hermes changed, not once"
[ "$(pkg_state)" = official ] || pk "security_status reads '$(pkg_state)' after official was written"
# Another page's staged edits are not committed along with this one, and off is always allowed.
uci set hermes.main.max_turns=33
out=$(sp_call off); echo "$out" | grep -q '"ok": true' || { echo "$out"; pk "off was refused"; }
grep -q "max_turns '33'" /etc/config/hermes && pk "set_packages committed another page's staged change (max_turns 33) with its own"
[ -n "$(uci changes hermes)" ] || pk "set_packages swallowed another page's staged change instead of leaving it staged"
uci revert hermes
[ "$(uci -q get hermes.security.packages)" = off ] || pk "off was answered ok and not written"
uci set hermes.security.factor=none; uci commit hermes
out=$(sp_call off); echo "$out" | grep -q '"ok": true' || { echo "$out"; pk "off was refused with no factor in force"; }
# A value the service would refuse to start on is shown as one, never as off or official.
uci set hermes.security.packages=bogus; uci commit hermes
[ "$(pkg_state)" = invalid ] || pk "an unknown packages value reads '$(pkg_state)', not invalid"
service_standin_gone
rm -rf /etc/openwrt-mcp/pin /etc/openwrt-mcp/mfa*; $MCP unpair hermes-main >/dev/null 2>&1 || true
uci -q delete hermes.security.packages; uci set hermes.security.factor=none; uci commit hermes
echo "PASS check_security_packages_written_only_with_a_factor"

# ---- 19. outside the owner profile the Security calls refuse ----
# The page says it offers nothing there, and that is the page. The backend is what a script, an
# old tab or a hand-made request reaches, and in the root and assistant profiles the agent has no
# openwrt-mcp change policy to protect, so a PIN set there would be a setting that guards nothing.
po() { fail check_security_refused_outside_the_owner_profile "$1"; }
$MCP pair hermes-main >/dev/null 2>&1 || true
service_standin check_security_refused_outside_the_owner_profile
for prof in root admin assistant nonsense; do
	uci set hermes.main.profile=$prof; uci commit hermes
	before=$(md5sum /etc/config/hermes | cut -d' ' -f1)
	for call in 'set_pin {"pin":"4821","again":"4821"}' 'clear_pin' 'enrol_start' 'enrol_activate {"code":"123456"}' 'set_factor {"factor":"none","window":"15m","max_failures":5,"lockout":"15m"}' 'set_packages {"packages":"off"}'; do
		m=${call%% *}; a=; [ "$m" = "$call" ] || a=${call#* }
		if [ -n "$a" ]; then out=$(ubus call hermes "$m" "$a" 2>&1); else out=$(ubus call hermes "$m" 2>&1); fi
		echo "$out" | grep -q '"ok": false' || { echo "$out" | head -c 300; po "$m was not refused in the $prof profile"; }
		echo "$out" | grep -qi 'owner' || po "$m's refusal in the $prof profile does not say it is the owner profile only"
	done
	[ "$(md5sum /etc/config/hermes | cut -d' ' -f1)" = "$before" ] || po "a refused call changed /etc/config/hermes in the $prof profile"
	[ ! -e /etc/openwrt-mcp/pin ] && [ ! -e /etc/openwrt-mcp/mfa.pending ] || po "a refused call wrote a PIN or a pending enrolment in the $prof profile"
done
sleep 1; [ "$(hermes_events)" = 0 ] || po "a refused call told procd the config changed"
# The control: the same call in the owner profile is accepted, so the refusals were the profile's.
uci set hermes.main.profile=owner; uci commit hermes
out=$(ubus call hermes set_pin '{"pin":"4821","again":"4821"}' 2>&1); echo "$out" | grep -q '"ok": true' || { echo "$out"; po "set_pin was refused in the owner profile too, so the refusals above prove nothing"; }
uci -q delete hermes.main.profile; uci commit hermes
out=$(ubus call hermes clear_pin 2>&1); echo "$out" | grep -q '"ok": true' || { echo "$out"; po "with no profile set (which is owner) clear_pin was refused"; }
service_standin_gone
rm -rf /etc/openwrt-mcp/pin /etc/openwrt-mcp/mfa*; $MCP unpair hermes-main >/dev/null 2>&1 || true
uci set hermes.main.profile=owner; uci commit hermes
echo "PASS check_security_refused_outside_the_owner_profile"

# ---- 20. every call the Security page makes is granted, and only the facts to a reader ----
# The page's calls are read off its own source, so a call added to it later and left out of
# the ACL (LuCI then answers "Access denied" on a page that renders fine) or put in the wrong
# block (a reader of the page able to start an enrolment) cannot get past this.
ag() { fail check_security_page_calls_are_granted "$1"; }
JS=/www/luci-static/resources/view/hermes/security.js
[ -f "$JS" ] || ag "the Security page is not installed"
[ "$(jsonfilter -i /usr/share/luci/menu.d/luci-app-hermes.json -e '@["admin/services/hermes/security"].action.path')" = hermes/security ] \
	|| ag "the menu has no Services -> Hermes Agent -> Security entry that opens hermes/security"
[ "$(jsonfilter -i /usr/share/luci/menu.d/luci-app-hermes.json -e '@["admin/services/hermes/security"].depends.acl[0]')" = luci-app-hermes ] \
	|| ag "the Security menu entry is not behind the app's ACL"
page_methods=$(sed -n "s/.*object: 'hermes', method: '\([a-z_]*\)'.*/\1/p" "$JS" | sort -u | tr '\n' ' ')
[ -n "$page_methods" ] || ag "the page declares no call, so this measured nothing"
set +u -f
. /usr/share/libubox/jshn.sh
json_load "$(/usr/libexec/rpcd/hermes list)"; json_get_keys listed_keys; listed=$listed_keys
acl_methods() { # <read|write> -> the hermes methods that block grants
	json_load_file /usr/share/rpcd/acl.d/luci-app-hermes.json; json_select luci-app-hermes; json_select "$1"; json_select ubus
	m=; json_get_values m hermes 2>/dev/null || true; echo $m
}
READ=$(acl_methods read); WRITE=$(acl_methods write)
set -u +f
for m in $page_methods; do
	case " $listed " in *" $m "*) ;; *) ag "the page calls $m, which the rpcd backend does not offer" ;; esac
	case " $READ " in *" $m "*) inr=1 ;; *) inr=0 ;; esac
	case " $WRITE " in *" $m "*) inw=1 ;; *) inw=0 ;; esac
	[ $((inr + inw)) -ge 1 ] || ag "the page calls $m, which no ACL block grants"
	case "$m" in
		status|logs|security_status) [ "$inr" = 1 ] || ag "$m is not in the read block" ;;
		*) [ "$inw" = 1 ] || ag "$m is not in the write block"; [ "$inr" = 0 ] || ag "$m, which writes a secret or returns enrolment material, is in the read block" ;;
	esac
done
for m in set_pin clear_pin enrol_start enrol_activate set_factor set_packages; do
	case " $page_methods " in *" $m "*) ;; *) ag "the page does not call $m" ;; esac
done
echo "PASS check_security_page_calls_are_granted ($(echo $page_methods | wc -w | tr -d ' ') calls read off the page)"

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

# ---- the views, as the browser runs them ----
# scripts/test-luci-views.mjs loads the installed pages with a stand-in for LuCI and
# checks what they decide: a deleted provider takes its key, a message said just before
# a reload is there after it, a Save & Apply that changed only a key says so at once
# (LuCI then does not reload), and an old message is not shown.
echo "-- the views, on the installed files --"
docker run --rm -v "$ROOT/scripts/test-luci-views.mjs:/test.mjs:ro" -v "$WWW:/www:ro" node:22-alpine \
	node /test.mjs /www check_removed_provider_takes_its_key check_messages_survive_the_reload check_saved_when_only_a_key_changed check_stale_message_not_shown check_profile_field_defaults_to_owner check_security_pin_fields_never_prefilled check_security_pin_saved_points_to_the_factor check_security_qr_shown_once check_security_factor_needs_its_prerequisite check_security_page_offers_nothing_it_cannot_do check_security_packages_switch_needs_a_factor

# Counted from $CHECKS itself, the same way --selftest counts them, so this line
# cannot go stale the next time a check is added or removed here.
n=0; for c in $CHECKS; do n=$((n + 1)); done
echo "gate-luci: all $n checks passed"
