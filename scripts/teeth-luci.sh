#!/bin/sh
# teeth-luci.sh -- prove gate-luci.sh can fail, and fail at the right check.
#
# Thirty-five faults, each a change somebody could plausibly make to the rpcd backend, its ACL or
# the pages. Faults 19 to 31 are LuCI r13's, for the Security page and the PIN and phone behind it.
# Faults 32 and 33 are r14's, the factor announced to procd once; 34 and 35 are 0.21.5-r2's, the
# two states in which reload_config has nothing to tell and set_factor must.
# The original eighteen: each a change somebody could plausibly make to the rpcd backend or its
# ACL. Faults 1 to 3 are each caught by a different one of the three checks gate-luci.sh
# added alongside them; fault 4 is the second side of fault 1's check, a grant beside the
# page's ubus object rather than inside it; fault 5 measures the free space on the data
# directory itself again, which a new install does not have yet.
# Faults 6 to 8 are the Providers page's: a crafted provider name, the sign-in status,
# and a sign-in that is not detached. Fault 9 leaves out the post-upgrade script.
# Faults 10 to 14 are LuCI r8's: the version read by running Hermes again, a provider
# deleted without its key, a message not kept across the reload, an old message shown
# anyway, and a Save & Apply message kept before the apply went through; the last four are in the page's own JavaScript, which gate-luci.sh runs
# Faults 15 to 17 are LuCI r9's, in the same JavaScript: a key-only Save & Apply that
# waits for an apply LuCI never announces, a leftover message shown beside the next one,
# and "Saved" beside a key that did not save.
# from the installed package. The faults are applied to a copy of the
# already-built LuCI tree and the result repackaged, the same shape as teeth-telegram.sh,
# and for the same reason: a rebuild from scratch per fault would quadruple the job and
# prove nothing extra, none of these is a build error.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
WORK="$ROOT/build/luci-app-hermes-apk"
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
ACL="$WORK/tree/usr/share/rpcd/acl.d/luci-app-hermes.json"
RPCD="$WORK/tree/usr/libexec/rpcd/hermes"
PROVIDERS="$WORK/tree/www/luci-static/resources/view/hermes/providers.js"
FLASH="$WORK/tree/www/luci-static/resources/hermes/flash.js"
SRC_PROVIDERS="$ROOT/package/luci-app-hermes/htdocs/luci-static/resources/view/hermes/providers.js"
SRC_FLASH="$ROOT/package/luci-app-hermes/htdocs/luci-static/resources/hermes/flash.js"
SETTINGS="$WORK/tree/www/luci-static/resources/view/hermes/settings.js"
SRC_SETTINGS="$ROOT/package/luci-app-hermes/htdocs/luci-static/resources/view/hermes/settings.js"
SECURITY="$WORK/tree/www/luci-static/resources/view/hermes/security.js"
SRC_SECURITY="$ROOT/package/luci-app-hermes/htdocs/luci-static/resources/view/hermes/security.js"
SRC_ACL="$ROOT/package/luci-app-hermes/root/usr/share/rpcd/acl.d/luci-app-hermes.json"
SRC_RPCD="$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes"

[ -d "$WORK/tree" ] || { echo "teeth-luci: no tree at $WORK/tree; build the LuCI package first:"
	echo "  ./package/luci-app-hermes/build.sh"
	exit 1; }

# ---- refuse to start on a tree an earlier run left broken ----
#
# Same trap teeth-telegram.sh guards against: this script plants faults in a SHARED
# build tree, and a run that went red partway would otherwise leave its last fault
# behind for the next run to mistake for the original.
for pair in "$ROOT/package/luci-app-hermes/root/usr/share/rpcd/acl.d/luci-app-hermes.json:$ACL" \
            "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes:$RPCD" \
            "$SRC_PROVIDERS:$PROVIDERS" "$SRC_FLASH:$FLASH" "$SRC_SECURITY:$SECURITY"; do
	src=${pair%%:*}; tree=${pair##*:}
	cmp -s "$src" "$tree" || {
		echo "teeth-luci: the build tree's $(basename "$tree") differs from the repository's." >&2
		echo "teeth-luci: an earlier run left a fault in it. Rebuild before running teeth:" >&2
		echo "teeth-luci:   ./package/luci-app-hermes/build.sh" >&2
		exit 1
	}
done

cleanup() {
	# Unconditional, on every exit path, including a fault that never got restored.
	cp "$ROOT/package/luci-app-hermes/root/usr/share/rpcd/acl.d/luci-app-hermes.json" "$ACL" 2>/dev/null || true
	cp "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$RPCD" 2>/dev/null || true
	cp "$SRC_PROVIDERS" "$PROVIDERS" 2>/dev/null || true
	cp "$SRC_FLASH" "$FLASH" 2>/dev/null || true
	cp "$SRC_SECURITY" "$SECURITY" 2>/dev/null || true
	chmod 0644 "$ACL" "$PROVIDERS" "$FLASH" "$SECURITY" 2>/dev/null || true
	chmod 0755 "$RPCD" 2>/dev/null || true
	# The mutant is a package a feed builder would otherwise collect from this
	# directory and sign. It does not outlive this script.
	rm -f "$WORK/mutant.apk"
}
trap cleanup EXIT INT TERM

# 0.19.0-r99, not the version build.sh would use, so a stray mutant is unmistakable if
# it is ever found anywhere but here.
repack_luci() {
	# A failed or interrupted repack must never leave a PREVIOUS mutant.apk sitting
	# there to be silently reused as if it carried this fault: macOS Docker Desktop's
	# bind-mount sync has been seen to serve stale content to the packaging container
	# (recorded 2026-09-13), and the surest defense is to remove the old file before
	# asking for a new one rather than trust that mkpkg always overwrites cleanly.
	rm -f "$WORK/mutant.apk"
	docker run --rm -i -v "$WORK:/work" -v "$ROOT/scripts/mkpkg-root.sh:/mkpkg-root:ro" -e OWN="$(id -u):$(id -g)" -w /work "$ALPINE" sh /mkpkg-root \
		--info "name:luci-app-hermes" --info "version:0.19.0-r99" --info "arch:noarch" \
		--info "license:MIT" --info "origin:luci-app-hermes" \
		--info "description:deliberately broken build, teeth-luci.sh" \
		--info "depends:luci-base hermes-agent" \
		--script "post-install:/work/post-install" \
		--script "${UPGRADE_SCRIPT:-post-upgrade:/work/post-install}" \
		--script "pre-deinstall:/work/pre-deinstall" \
		--files /work/tree --output /work/mutant.apk >/dev/null 2>&1
}

run_gate() {
	ARCH="$ARCH" LUCI="$WORK/mutant.apk" "$ROOT/scripts/gate-luci.sh" >/tmp/teeth-luci.out 2>&1
}

# SHARD=i/n runs every n-th fault starting at the i-th (0-based), so CI can run the faults on
# n runners at once. Every fault is still planted in every shard, which keeps each fault's own
# "planted nothing" guard live everywhere; only the gate run is skipped outside the shard.
SHARD=${SHARD:-0/1}
SHARD_I=${SHARD%/*}; SHARD_N=${SHARD#*/}
case "$SHARD_I/$SHARD_N" in *[!0-9/]*|/*|*/) echo "teeth-luci: SHARD must be i/n, not '$SHARD'" >&2; exit 1 ;; esac
[ "$SHARD_N" -ge 1 ] && [ "$SHARD_I" -lt "$SHARD_N" ] || { echo "teeth-luci: SHARD $SHARD is out of range" >&2; exit 1; }
FAULT_K=0 RAN=0
expect_red() {
	name=$1; want=$2
	FAULT_K=$((FAULT_K + 1))
	if [ $(((FAULT_K - 1) % SHARD_N)) -ne "$SHARD_I" ]; then echo "teeth skip (shard $SHARD): $name"; return 0; fi
	RAN=$((RAN + 1))
	if run_gate; then
		echo "TEETH FAIL: $name left the gate green"; cat /tmp/teeth-luci.out; exit 1
	fi
	# FAIL and the name, not the name alone: the view checks all run and print PASS for
	# the ones a fault did not reach, so the bare name would match a check that passed.
	if ! grep -q "^FAIL $want:" /tmp/teeth-luci.out; then
		echo "TEETH FAIL: $name went red, but not at $want"
		grep FAIL /tmp/teeth-luci.out | head -3; exit 1
	fi
	echo "teeth ok: $name -> $want"
}

# ---- fault 1: service.list is granted again ----
# The narrow read ACL is the whole point of the check; re-adding the grant is the exact
# regression a careless merge of an older acl.d file would reintroduce.
sed 's/"hermes": \[ "status", "logs", "security_status" \]/"hermes": [ "status", "logs", "security_status" ], "service": [ "list" ]/' \
	"$ACL" > /tmp/acl.new
grep -q '"service": \[ "list" \]' /tmp/acl.new || {
	echo "teeth-luci: fault 1 planted nothing; the read grant in the ACL no longer reads as expected" >&2
	exit 1; }
cp /tmp/acl.new "$ACL"
repack_luci
expect_red "service.list re-added to the read ACL" check_read_acl_is_narrow
# Restored here, not only in the exit trap: fault 2 and fault 3 repackage the SAME
# tree, and an ACL still carrying fault 1 would fail check_read_acl_is_narrow before
# either of their own checks ever ran, reporting the wrong check as the one that caught
# them.
cp "$ROOT/package/luci-app-hermes/root/usr/share/rpcd/acl.d/luci-app-hermes.json" "$ACL"

# ---- fault 2: a failed write is reported as ok ----
sed 's/if \[ "\$write_ok" -ne 1 \]; then/if false; then/' "$RPCD" > /tmp/rpcd.new && cp /tmp/rpcd.new "$RPCD"
repack_luci
expect_red "write-failure check removed from set_secret" check_secret_write_failure_reported
cp "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$RPCD"

# ---- fault 3: a UCI path mismatch is no longer refused ----
sed 's/if \[ "\$svc" != "\$path" \]; then/if false; then/' "$RPCD" > /tmp/rpcd.new && cp /tmp/rpcd.new "$RPCD"
repack_luci
expect_red "path-mismatch refusal removed from set_secret" check_secret_path_mismatch_refused
cp "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$RPCD"

# ---- fault 4: a file read grant beside the page's own calls ----
# Fault 1 adds a grant inside the one ubus object the check used to read. This one adds
# a grant beside it, where the check did not look until 2026-09-24: rpcd would hand the
# key file itself to any session with read access, while the ubus grants still read
# exactly status and logs. Both faults land on check_read_acl_is_narrow on purpose, one
# for each side of the same boundary.
sed 's|"comment": "status reports only whether a key is PRESENT, never its value or length; security_status[^"]*",|&  "file": { "/etc/hermes-agent/*": [ "read" ] },|' \
	"$ACL" > /tmp/acl.new
grep -q '"/etc/hermes-agent/\*": \[ "read" \]' /tmp/acl.new || {
	echo "teeth-luci: fault 4 planted nothing; the read comment in the ACL no longer reads as expected" >&2
	exit 1; }
cp /tmp/acl.new "$ACL"
repack_luci
expect_red "a file read grant beside the page's own calls" check_read_acl_is_narrow
cp "$ROOT/package/luci-app-hermes/root/usr/share/rpcd/acl.d/luci-app-hermes.json" "$ACL"

# ---- fault 5: free space measured on the missing data directory again ----
# The first version of status ran df on the configured path, which a new install does
# not have until the first start, and reported 0. Put back, only the check added for it
# may catch it.
sed 's|free_kb=$(df -k "$probe" 2>/dev/null|free_kb=$(df -k "$data_dir" 2>/dev/null|' "$RPCD" > /tmp/rpcd.new
grep -q 'free_kb=$(df -k "$data_dir" 2>/dev/null' /tmp/rpcd.new || {
	echo "teeth-luci: fault 5 planted nothing; the free space line in the backend no longer reads as expected" >&2
	exit 1; }
cp /tmp/rpcd.new "$RPCD"
repack_luci
expect_red "free space measured on the missing data directory" check_free_space_before_first_start
cp "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$RPCD"

# ---- fault 6: a provider slot takes any name ----
sed 's/echo "$name" | grep -qE .\^\[a-z\]\[a-z0-9-\]{0,30}\$. || return 1/true/' "$RPCD" > /tmp/rpcd.new
grep -q 'provider_section' /tmp/rpcd.new && ! grep -q 'grep -qE .\^\[a-z\]\[a-z0-9-\]{0,30}\$. || return 1' /tmp/rpcd.new || {
	echo "teeth-luci: fault 6 planted nothing; the provider name check no longer reads as expected" >&2
	exit 1; }
cp /tmp/rpcd.new "$RPCD"
repack_luci
expect_red "a provider slot takes any name" check_provider_key_name_refused
cp "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$RPCD"

# ---- fault 7: the page is told ChatGPT is signed in whatever auth.json says ----
sed "s/grep -qs '\"openai-codex\"' \"\$data_dir\/auth.json\"/true/" "$RPCD" > /tmp/rpcd.new
grep -q 'chatgpt_signed_in" "$(true && echo 1' /tmp/rpcd.new || {
	echo "teeth-luci: fault 7 planted nothing; the signed-in check no longer reads as expected" >&2
	exit 1; }
cp /tmp/rpcd.new "$RPCD"
repack_luci
expect_red "ChatGPT reported as signed in regardless" check_chatgpt_sign_in_from_the_page
cp "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$RPCD"

# ---- fault 8: the sign-in runs in the foreground ----
# rpcd waits for the backend's output to end, so a sign-in that is not detached holds
# the call for as long as the owner takes to enter the code.
sed 's|( setsid "$LOGIN" chatgpt > "$LOGIN_LOG" 2>&1 < /dev/null & echo $! > "$LOGIN_PID" ) > /dev/null 2>&1|"$LOGIN" chatgpt > "$LOGIN_LOG" 2>\&1 < /dev/null|' "$RPCD" > /tmp/rpcd.new
grep -q '^		"$LOGIN" chatgpt > "$LOGIN_LOG" 2>&1 < /dev/null$' /tmp/rpcd.new || {
	echo "teeth-luci: fault 8 planted nothing; the detached sign-in no longer reads as expected" >&2
	exit 1; }
cp /tmp/rpcd.new "$RPCD"
repack_luci
expect_red "the sign-in runs in the foreground" check_chatgpt_sign_in_from_the_page
cp "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$RPCD"

# ---- fault 9: no post-upgrade script ----
# The package as it was up to r6: rpcd restarted on an install only, so an upgrade left
# the previous method list in place.
printf '#!/bin/sh\nexit 0\n' > "$WORK/noop" && chmod 0755 "$WORK/noop"
# Set and unset explicitly: an assignment in front of a function call outlives the call
# in POSIX shells, and the green run below must repack with the real script again.
UPGRADE_SCRIPT="post-upgrade:/work/noop"
repack_luci
unset UPGRADE_SCRIPT
expect_red "the package without a post-upgrade script" check_upgrade_restarts_rpcd
rm -f "$WORK/noop"

# plant FILE FROM TO WHAT: replace one exact line fragment, and refuse if it is not
# there exactly once, so a fault that planted nothing cannot pass as caught.
plant() {
	n=$(grep -cF -- "$2" "$1" || true)
	[ "$n" = 1 ] || { echo "teeth-luci: $4 planted nothing; '$2' occurs $n times in $(basename "$1")" >&2; exit 1; }
	FROM=$2 TO=$3 awk 'BEGIN { f = ENVIRON["FROM"]; t = ENVIRON["TO"] }
		{ i = index($0, f); if (i) $0 = substr($0, 1, i - 1) t substr($0, i + length(f)); print }' "$1" > /tmp/planted
	cp /tmp/planted "$1"
}

# ---- fault 10: the version read by running Hermes again ----
# The line status had until r8: Python started, Hermes imported, upstream asked for a
# newer release, 4 s on every page load.
plant "$RPCD" 'version=$(sed -n '"'"'s/^Version: *//p'"'"' "$meta" | head -n1)' \
	'version=$(/usr/bin/hermes --version 2>/dev/null | head -n1 | sed '"'"'s/^Hermes Agent v//; s/ .*//'"'"')' "fault 10"
repack_luci
expect_red "the version read by running Hermes" check_status_reads_version_from_disk
cp "$ROOT/package/luci-app-hermes/root/usr/libexec/rpcd/hermes" "$RPCD"

# ---- fault 11: a provider deleted without its key ----
plant "$PROVIDERS" "callSetSecret('provider:' + section_id, '')" "Promise.resolve({ ok: true })" "fault 11"
repack_luci
expect_red "a provider deleted without its key" check_removed_provider_takes_its_key
cp "$SRC_PROVIDERS" "$PROVIDERS"

# ---- fault 12: a message not kept across the reload ----
plant "$FLASH" "window.sessionStorage.setItem(KEY, JSON.stringify(list));" "void list;" "fault 12"
repack_luci
expect_red "a message not kept across the reload" check_messages_survive_the_reload
cp "$SRC_FLASH" "$FLASH"

# ---- fault 13: an old message shown anyway ----
plant "$FLASH" "now - m.at < FRESH_MS" "true" "fault 13"
repack_luci
expect_red "an old message shown anyway" check_stale_message_not_shown
cp "$SRC_FLASH" "$FLASH"

# ---- fault 14: a Save & Apply message kept before the apply went through ----
# Kept at once instead of on 'uci-applied', an apply that was rolled back leaves "Saved"
# for the next visit.
plant "$FLASH" "onApply.push({ text: text, kind: kind });" "self.keep(text, kind);" "fault 14"
repack_luci
expect_red "a Save & Apply message kept before the apply went through" check_messages_survive_the_reload
cp "$SRC_FLASH" "$FLASH"

# ---- fault 15: a key-only Save & Apply waits for an apply LuCI never announces ----
# What LuCI r8 did: with nothing staged LuCI answers 204, neither announces nor reloads,
# and "Saved" was never shown.
plant "$FLASH" "if (!changed) {" "if (false) {" "fault 15"
repack_luci
expect_red "a key-only Save & Apply that never says it saved" check_saved_when_only_a_key_changed
cp "$SRC_FLASH" "$FLASH"

# ---- fault 16: what a rolled-back apply left waiting is shown beside the next one ----
plant "$FLASH" "this.dropPending();" "void 0;" "fault 16"
repack_luci
expect_red "a leftover Save & Apply message shown twice" check_saved_when_only_a_key_changed
cp "$SRC_FLASH" "$FLASH"

# ---- fault 17: "Saved" beside a key that did not save, with nothing else to apply ----
plant "$FLASH" "if (!failures.length)" "if (true)" "fault 17"
repack_luci
expect_red "\"Saved\" beside a key that did not save" check_saved_when_only_a_key_changed
cp "$SRC_FLASH" "$FLASH"

# ---- fault 18: the profile field puts the agent back to root on save ----
# The field writes hermes.main.profile on every save; defaulting it to the root profile
# would undo the package's own default the first time somebody saved the page.
plant "$SETTINGS" "o.default = 'owner';" "o.default = 'root';" "fault 18"
repack_luci
expect_red "the profile field defaulting to root" check_profile_field_defaults_to_owner
cp "$SRC_SETTINGS" "$SETTINGS"

# ---- fault 19: the status says a PIN is set whatever openwrt-mcp holds ----
plant "$RPCD" 'json_add_boolean "pin_set" "$PIN_SET"' 'json_add_boolean "pin_set" "1"' "fault 19"
repack_luci
expect_red "the status reporting a PIN that is not there" check_security_status_reports_facts_only
cp "$SRC_RPCD" "$RPCD"

# ---- fault 20: a factor chosen without what it needs ----
# The owner who picks PIN before setting one is refused every unlock by their own router.
plant "$RPCD" 'if ! sec_factor_ready "$factor"; then' 'if false; then' "fault 20"
repack_luci
expect_red "a factor accepted with what it needs missing" check_security_factor_never_outruns_what_exists
cp "$SRC_RPCD" "$RPCD"

# ---- fault 21: the commit takes another page's staged changes ----
# A plain `uci commit hermes` after the write, which is how the first version of set_factor did it.
plant "$RPCD" 'rm -rf "$d"' 'rm -rf "$d"; uci -q commit hermes' "fault 21"
repack_luci
expect_red "set_factor committing another page's staged changes" check_security_factor_never_outruns_what_exists
cp "$SRC_RPCD" "$RPCD"

# ---- fault 22: the Security calls answer in every profile ----
plant "$RPCD" 'if [ "$(sec_profile)" != owner ]; then' 'if false; then' "fault 22"
repack_luci
expect_red "the Security calls answering outside the owner profile" check_security_refused_outside_the_owner_profile
cp "$SRC_RPCD" "$RPCD"

# ---- fault 23: a call the page makes, left out of the permissions ----
# LuCI then answers "Access denied" on a page that renders fine.
plant "$ACL" '"enrol_activate", "set_factor" ],' '"enrol_activate" ],' "fault 23"
repack_luci
expect_red "set_factor left out of the write permission" check_security_page_calls_are_granted
cp "$SRC_ACL" "$ACL"

# ---- fault 24: the PIN field filled in with a mask ----
# The usual way a field comes to be prefilled: "so that it shows a PIN is set".
plant "$SECURITY" "'id': 'hermes-sec-pin', 'class': 'cbi-input-password', 'value': ''," \
	"'id': 'hermes-sec-pin', 'class': 'cbi-input-password', 'value': st.pin_set ? '********' : ''," "fault 24"
repack_luci
expect_red "the PIN field prefilled" check_security_pin_fields_never_prefilled
cp "$SRC_SECURITY" "$SECURITY"

# ---- fault 25: a PIN left in its fields once it is sent ----
plant "$SECURITY" 'wipePin();' 'void 0;' "fault 25"
repack_luci
expect_red "the PIN left in its fields after it is sent" check_security_pin_fields_never_prefilled
cp "$SRC_SECURITY" "$SECURITY"

# ---- fault 26: the QR still on a page that was left ----
plant "$SECURITY" "window.addEventListener('pagehide', function () { held = null; codeIn = null; paint(); });" 'void 0;' "fault 26"
repack_luci
expect_red "the QR kept when the page is left" check_security_qr_shown_once
cp "$SRC_SECURITY" "$SECURITY"

# ---- fault 27: the secret kept in the tab's storage ----
# So that it survives the reload: the message mechanism the other pages use is the obvious place.
plant "$SECURITY" 'held = { secret: r.secret, png: r.qr_png_base64 };' "held = { secret: r.secret, png: r.qr_png_base64 }; flash.keep(r.secret, 'info');" "fault 27"
repack_luci
expect_red "the phone's secret kept in the tab's storage" check_security_qr_shown_once
cp "$SRC_SECURITY" "$SECURITY"

# ---- fault 28: a choice open that has no PIN behind it ----
plant "$SECURITY" "if (!ok) attrs.disabled = 'disabled';" 'void 0;' "fault 28"
repack_luci
expect_red "every factor open whatever exists" check_security_factor_needs_its_prerequisite
cp "$SRC_SECURITY" "$SECURITY"

# ---- fault 29: Save letting a disabled choice through ----
plant "$SECURITY" 'if (!allowed(f, st)) return fail(' 'if (false) return fail(' "fault 29"
repack_luci
expect_red "Save sending a factor the router could not honour" check_security_factor_needs_its_prerequisite
cp "$SRC_SECURITY" "$SECURITY"

# ---- fault 30: the page offering its controls outside the owner profile ----
plant "$SECURITY" 'else if (st.applies !== true)' 'else if (false)' "fault 30"
repack_luci
expect_red "the page offering controls in the root profile" check_security_page_offers_nothing_it_cannot_do
cp "$SRC_SECURITY" "$SECURITY"

# ---- fault 31: a key read with jshn's own loader ----
# What set_secret did until LuCI r13: json_load puts the whole message, the key included, on a
# `jshn` command line, and json_get_var exports it to every program started afterwards.
plant "$RPCD" 'value=$(msg_get value)' 'json_load "$MSG"; json_get_var value value' "fault 31"
repack_luci
expect_red "a key read with json_load" check_secret_never_returned
cp "$SRC_RPCD" "$RPCD"

# ---- fault 32: only reload_config, as until LuCI r14 ----
# Its first run after a boot keeps a copy and tells procd nothing, so the first factor chosen
# after a boot stayed out of the openwrt-mcp policies until a restart.
plant "$RPCD" 'if [ "$reload_tells" != 1 ] || [ ! -x "$RELOAD" ]; then' 'if false; then' "fault 32"
repack_luci
expect_red "the first choice after a boot announced by nobody" check_security_factor_never_outruns_what_exists
cp "$SRC_RPCD" "$RPCD"

# ---- fault 33: announced as well as reloaded, every time ----
# Once reload_config has its copy it tells procd itself, so a second announcement restarts the
# agent twice for one choice.
plant "$RPCD" 'if [ "$reload_tells" != 1 ] || [ ! -x "$RELOAD" ]; then' 'if true; then' "fault 33"
repack_luci
expect_red "one choice announced twice" check_security_factor_never_outruns_what_exists
cp "$SRC_RPCD" "$RPCD"

# ---- fault 34: a copy read from the md5 file being there, as until LuCI 0.21.5-r2 ----
# A file without a line for hermes (reload_config ran while /etc/config/hermes did not exist) then
# reads as a copy reload_config will compare, so nobody tells procd.
plant "$RPCD" '[ -n "$old_sum" ] && [ "$old_sum" != "$new_sum" ] && reload_tells=1' \
	'[ -f "$CONFIG_MD5" ] && [ "$old_sum" != "$new_sum" ] && reload_tells=1' "fault 34"
repack_luci
expect_red "an md5 file without a hermes line taken for a copy" check_security_factor_announced_when_reload_cannot_tell
cp "$SRC_RPCD" "$RPCD"

# ---- fault 35: a copy whose sum already matches taken as one reload_config will tell ----
plant "$RPCD" '[ -n "$old_sum" ] && [ "$old_sum" != "$new_sum" ] && reload_tells=1' \
	'[ -n "$old_sum" ] && reload_tells=1' "fault 35"
repack_luci
expect_red "a hermes sum that already matches taken for a change" check_security_factor_announced_when_reload_cannot_tell
cp "$SRC_RPCD" "$RPCD"

# ---- and green again, so the reds were the faults and not the harness ----
cp "$ROOT/package/luci-app-hermes/root/usr/share/rpcd/acl.d/luci-app-hermes.json" "$ACL"
repack_luci
if ! run_gate; then
	echo "TEETH FAIL: the restored package is not green, so a fault was not undone"
	tail -20 /tmp/teeth-luci.out; exit 1
fi
[ "$FAULT_K" = 35 ] || { echo "TEETH FAIL: $FAULT_K faults planted, 35 expected; update the count with the faults"; exit 1; }
[ "$RAN" -ge 1 ] || { echo "TEETH FAIL: shard $SHARD ran no fault, so it measured nothing"; exit 1; }
echo "teeth-luci: $RAN of 35 faults on 23 checks (shard $SHARD), green restored"
