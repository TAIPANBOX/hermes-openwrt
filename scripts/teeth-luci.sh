#!/bin/sh
# teeth-luci.sh -- prove gate-luci.sh can fail, and fail at the right check.
#
# Nine faults, each a change somebody could plausibly make to the rpcd backend or its
# ACL. Faults 1 to 3 are each caught by a different one of the three checks gate-luci.sh
# added alongside them; fault 4 is the second side of fault 1's check, a grant beside the
# page's ubus object rather than inside it; fault 5 measures the free space on the data
# directory itself again, which a new install does not have yet.
# Faults 6 to 8 are the Providers page's: a crafted provider name, the sign-in status,
# and a sign-in that is not detached. Fault 9 leaves out the post-upgrade script.
# Faults 10 to 13 are LuCI r8's: the version read by running Hermes again, a provider
# deleted without its key, a message not kept across the reload, and an old message
# shown anyway; the last three are in the page's own JavaScript, which gate-luci.sh runs
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
            "$SRC_PROVIDERS:$PROVIDERS" "$SRC_FLASH:$FLASH"; do
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
	chmod 0644 "$ACL" "$PROVIDERS" "$FLASH" 2>/dev/null || true
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
	docker run --rm -i -v "$WORK:/work" -w /work "$ALPINE" apk mkpkg \
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

expect_red() {
	name=$1; want=$2
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
sed 's/"hermes": \[ "status", "logs" \]/"hermes": [ "status", "logs" ], "service": [ "list" ]/' \
	"$ACL" > /tmp/acl.new && cp /tmp/acl.new "$ACL"
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
sed 's|"comment": "status reports only whether a key is PRESENT, never its value or length",|&  "file": { "/etc/hermes-agent/*": [ "read" ] },|' \
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

# ---- and green again, so the reds were the faults and not the harness ----
cp "$ROOT/package/luci-app-hermes/root/usr/share/rpcd/acl.d/luci-app-hermes.json" "$ACL"
repack_luci
if ! run_gate; then
	echo "TEETH FAIL: the restored package is not green, so a fault was not undone"
	tail -20 /tmp/teeth-luci.out; exit 1
fi
echo "teeth-luci: 13 faults on 11 checks, green restored"
