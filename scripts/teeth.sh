#!/bin/sh
# teeth.sh -- prove gate-package.sh can actually fail, and fail at the right check.
#
# Twelve faults, each one a real change could introduce, each caught by a different
# check. If two faults trip the same check, one of them is not testing what its name
# says, and the gate is thinner than its list of checks suggests.
#
# The faults are applied to the tree that was already built and the result repackaged,
# rather than rebuilt from source. A full rebuild per fault would triple the job and
# tell us nothing extra: every one of these is a packaging mistake, not a build one.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
# Keyed by release line, like the builder: both lines produce an x86_64 tree and they
# are not interchangeable, so a bare build/$ARCH would find whichever ran last.
LINE=${LINE:-25.12}
W="$ROOT/build/$LINE/$ARCH"
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
SITE="$W/tree/usr/lib/hermes-agent/site-packages"
DEPS_OK="python3 python3-pip ca-bundle bash ffmpeg ffprobe ripgrep openwrt-mcp>=0.5.0.3 iputils-ping"

[ -d "$W/tree" ] || {
	echo "teeth: no build tree at $W/tree; build the package first:"
	echo "  ./package/hermes-agent/build-in-container.sh $ARCH"
	exit 1; }

# Same discipline as teeth-telegram.sh, and for the same reason: this plants faults in a
# shared build tree, and a run that goes red partway would otherwise leave one there for
# the next build, the next gate, and the next feed to inherit.
if ! cmp -s "$ROOT/package/hermes-agent/files/hermes-agent.init" "$W/tree/etc/init.d/hermes-agent"; then
	echo "teeth: the build tree's init script differs from the repository's; rebuild first:" >&2
	echo "  ./package/hermes-agent/build-in-container.sh $ARCH" >&2
	exit 1
fi

cleanup() {
	[ -f /tmp/shim.bak ] && cp /tmp/shim.bak "$SITE/webbrowser.py" 2>/dev/null
	[ -f /tmp/postinstall.bak ] && cp /tmp/postinstall.bak "$W/post-install" 2>/dev/null
	[ -f /tmp/postupgrade.bak ] && cp /tmp/postupgrade.bak "$W/post-upgrade" 2>/dev/null
	chmod 0755 "$W/post-upgrade" 2>/dev/null || true
	[ -f /tmp/wrap.bak ] && cp /tmp/wrap.bak "$W/tree/usr/sbin/hermes-gateway" 2>/dev/null
	[ -f /tmp/env.bak ] && cp /tmp/env.bak "$W/tree/usr/lib/hermes-agent/hermes-env" 2>/dev/null
	[ -f /tmp/boot.bak ] && cp /tmp/boot.bak "$W/tree/usr/lib/hermes-agent/gateway-boot/sitecustomize.py" 2>/dev/null
	chmod 0755 "$W/post-install" 2>/dev/null || true
	# The init is restored from the repository rather than from a backup: a backup taken
	# at the top of a run that had already been poisoned by an earlier crashed run would
	# faithfully restore the poison.
	cp "$ROOT/package/hermes-agent/files/hermes-agent.init" "$W/tree/etc/init.d/hermes-agent" 2>/dev/null || true
	chmod 0755 "$W/tree/etc/init.d/hermes-agent" 2>/dev/null || true
	rm -f "$W/mutant.apk"
}
trap cleanup EXIT INT TERM
# a backup is taken by the fault that changes its file; one left by an earlier run that
# stopped half way would otherwise be restored over a fresh build's file
rm -f /tmp/shim.bak /tmp/postinstall.bak /tmp/postupgrade.bak /tmp/wrap.bak /tmp/init.bak /tmp/env.bak /tmp/boot.bak

repack() {
	docker run --rm -i -v "$W:/work" -v "$ROOT/scripts/mkpkg-root.sh:/mkpkg-root:ro" -e OWN="$(id -u):$(id -g)" -w /work "$ALPINE" sh /mkpkg-root \
		--info "name:hermes-agent" --info "version:0.0.0-r1" --info "arch:$ARCH" \
		--info "license:MIT" --info "origin:hermes-agent" \
		--info "description:deliberately broken build, teeth.sh" \
		--info "depends:$1" \
		--script "post-install:/work/post-install" \
		--script "post-upgrade:/work/post-upgrade" \
		--script "pre-deinstall:/work/pre-deinstall" \
		--files /work/tree --output /work/mutant.apk >/dev/null 2>&1
}

expect_red() {
	name=$1; want=$2
	if APK="$W/mutant.apk" ARCH="$ARCH" "$ROOT/scripts/gate-package.sh" >/tmp/teeth.out 2>&1; then
		echo "TEETH FAIL: $name left the gate green"; cat /tmp/teeth.out; exit 1
	fi
	if ! grep -q "^FAIL .*$want" /tmp/teeth.out; then
		echo "TEETH FAIL: $name went red, but not at $want"; grep FAIL /tmp/teeth.out | head -3; exit 1
	fi
	echo "teeth ok: $name -> $want"
}

# ---- fault 1: no webbrowser shim ----
# OpenWrt ships no webbrowser in any python3-* package. Until 0.21.5 the CLI could not
# print its own version without the shim; since then it imports webbrowser lazily, and
# this fault went on passing only because the match also found check 3's PASS line (the
# gateway, check 6, was what broke). Check 3 now imports the ChatGPT sign-in, which needs
# the shim, so this fault is caught where it is named.
cp "$SITE/webbrowser.py" /tmp/shim.bak
rm -f "$SITE/webbrowser.py" "$SITE/__pycache__/webbrowser."*
repack "$DEPS_OK"
expect_red "webbrowser shim removed" check_cli_runs
cp /tmp/shim.bak "$SITE/webbrowser.py"

# ---- fault 2: an undeclared runtime dependency ----
# apk would not complain: the package installs fine without ffmpeg declared, and the
# gap only shows the first time someone sends a voice message.
repack "python3 python3-pip ca-bundle ripgrep openwrt-mcp>=0.5.0.3 iputils-ping"
expect_red "ffmpeg undeclared" check_deps_resolve

# ---- fault 3: a post-install that does not enable the service ----
# The router would come back from a reboot with the agent installed and silent.
cp "$W/post-install" /tmp/postinstall.bak
printf '#!/bin/sh\nexit 0\n' > "$W/post-install"; chmod 0755 "$W/post-install"
repack "$DEPS_OK"
expect_red "post-install neutered" check_ships_disabled
cp /tmp/postinstall.bak "$W/post-install"

# ---- fault 4: a flag the CLI does not accept on that subcommand ----
# Not a hypothetical. This is the defect that shipped: `--toolsets` on `gateway run`,
# which killed the service at argument parsing on every start with the configuration the
# package ships, while every other check in the gate stayed green. It was found by
# looking at the log box on the LuCI page in a browser, weeks of gate runs later.
# The argv the service runs is now built in the wrapper rather than the init, so the
# fault has to be planted where the words actually are. Planting it in the init would
# change nothing and the check would stay green, which is how this fault broke when the
# wrapper was introduced: teeth caught it on the first CI run.
#
# The sleep is the other half of the fault. On an emulated CPU the wrapper's helpers and
# the gateway's own start-up together run past the ten seconds check 6 used to wait from
# launch, so there this fault stayed green (the aarch64 leg of CI, 2026-09-24) while every
# native run caught it. Sleeping before the exec makes every machine at least that slow,
# so the check's timing is tested everywhere rather than only where CI happens to emulate.
INIT="$W/tree/etc/init.d/hermes-agent"
WRAP="$W/tree/usr/sbin/hermes-gateway"
cp "$WRAP" /tmp/wrap.bak
# The exec goes through hermes-drop since 0.21.5-r3, so the line is matched by its tail.
sed 's|^exec \(.*/usr/bin/hermes gateway run --external-supervisor\)$|sleep 12; exec \1 --toolsets file,web|' \
	"$WRAP" > /tmp/wrap.new
grep -q -- '--toolsets file,web' /tmp/wrap.new || {
	echo "teeth: fault 4 planted nothing; the wrapper's exec line no longer reads as expected" >&2; exit 1; }
cp /tmp/wrap.new "$WRAP" && chmod 0755 "$WRAP"
repack "$DEPS_OK"
expect_red "a flag the gateway subcommand rejects" check_service_command_runs
cp /tmp/wrap.bak "$WRAP" && chmod 0755 "$WRAP"

# ---- fault 5: the key handed to procd instead of read by the wrapper ----
# This is the shape the package shipped in until hardware showed the cost: procd keeps
# whatever env it is given and returns all of it to `ubus call service list`, which rpcd
# ACLs can expose well beyond root. argv and uci stayed clean the whole time, so the two
# older key checks could not see it.
cp "$INIT" /tmp/init.bak
sed -e 's|procd_set_param command /usr/sbin/hermes-gateway "$key_file"|procd_set_param command "$PROG" gateway run --external-supervisor|' \
    -e 's|\t\tOPENAI_BASE_URL="$base_url" \\|\t\tOPENAI_BASE_URL="$base_url" \\\n\t\tOPENAI_API_KEY="$key" \\|' \
	"$INIT" > /tmp/init.new && cp /tmp/init.new "$INIT"
repack "$DEPS_OK"
expect_red "the key handed to procd's env" check_key_not_in_procd_env
cp /tmp/init.bak "$INIT"

# ---- fault 6: an upgrade that switches the start at boot back on ----
# The shape the package had until r7: post-upgrade ran the same enable as post-install, so
# an owner's `disable` lasted only until the next apk upgrade.
cp "$W/post-upgrade" /tmp/postupgrade.bak
grep -q '/etc/init.d/hermes-agent enable' "$W/post-upgrade" && {
	echo "teeth: fault 6 planted nothing; post-upgrade enables the service already" >&2; exit 1; }
awk '$0 == "exit 0" { print "/etc/init.d/hermes-agent enable" } { print }' /tmp/postupgrade.bak > "$W/post-upgrade"; chmod 0755 "$W/post-upgrade"
grep -q '/etc/init.d/hermes-agent enable' "$W/post-upgrade" || {
	echo "teeth: fault 6 planted nothing; post-upgrade no longer ends with exit 0" >&2; exit 1; }
repack "$DEPS_OK"
expect_red "an upgrade that enables the service" check_upgrade_keeps_boot_start
cp /tmp/postupgrade.bak "$W/post-upgrade"; chmod 0755 "$W/post-upgrade"

# ---- fault 7: the init hands procd the key itself ----
# The key's path is the only thing the command may carry; an extra argument with the key in
# it is ignored by the wrapper and the service still starts, so only the argv check sees it.
cp "$INIT" /tmp/init.bak
sed 's|procd_set_param command /usr/sbin/hermes-gateway "$key_file"|procd_set_param command /usr/sbin/hermes-gateway "$key_file" "$(cat "$key_file")"|' \
	"$INIT" > /tmp/init.new
grep -q '"$key_file" "$(cat "$key_file")"' /tmp/init.new || {
	echo "teeth: fault 7 planted nothing; the init's command line no longer reads as expected" >&2; exit 1; }
cp /tmp/init.new "$INIT"
repack "$DEPS_OK"
expect_red "the key on the init's command line" check_key_not_in_argv
cp /tmp/init.bak "$INIT"

# ---- fault 8: an install that always takes the new defaults ----
# apk keeps an edited /etc/config/hermes and puts the shipped one beside it as .apk-new; a
# post-install that moves the new one into place throws every setting away on a reinstall.
cp "$W/post-install" /tmp/postinstall.bak
awk '$0 == "exit 0" { print "[ -f /etc/config/hermes.apk-new ] && mv /etc/config/hermes.apk-new /etc/config/hermes" } { print }' \
	/tmp/postinstall.bak > "$W/post-install"; chmod 0755 "$W/post-install"
grep -q 'hermes.apk-new' "$W/post-install" || { echo "teeth: fault 8 planted nothing" >&2; exit 1; }
repack "$DEPS_OK"
expect_red "an install that takes the new defaults over the owner's" check_config_survives
cp /tmp/postinstall.bak "$W/post-install"; chmod 0755 "$W/post-install"

# ---- fault 9: the package without iputils-ping ----
# The shape r3 to r8 shipped in: the agent runs as `hermes`, BusyBox's ping needs root, and every
# ping the agent ran answered "permission denied". Everything else installs and starts.
repack "python3 python3-pip ca-bundle bash ffmpeg ffprobe ripgrep openwrt-mcp>=0.5.0.3"
expect_red "iputils-ping undeclared" check_agent_can_ping

# ---- fault 10: hermes from a shell allowed to pip-install ----
# The shape every release up to r9 had: hermes-env did not set HERMES_DISABLE_LAZY_INSTALLS, so
# only the gateway was held to it, and a `hermes chat` typed in a shell pip-installed boto3.
ENVF="$W/tree/usr/lib/hermes-agent/hermes-env"
cp "$ENVF" /tmp/env.bak
grep -q '^export HERMES_DISABLE_LAZY_INSTALLS=1$' "$ENVF" || {
	echo "teeth: fault 10 planted nothing; hermes-env no longer sets HERMES_DISABLE_LAZY_INSTALLS" >&2; exit 1; }
sed '/^export HERMES_DISABLE_LAZY_INSTALLS=1$/d' /tmp/env.bak > "$ENVF"
repack "$DEPS_OK"
expect_red "hermes from a shell allowed to pip-install" check_shell_never_lazy_installs
cp /tmp/env.bak "$ENVF"

# ---- fault 11: a gateway that stays dumpable ----
# The shape every release up to r9 had: the keys the wrapper exports were readable in
# /proc/<gateway>/environ by the gateway's own user, the agent's terminal included.
BOOT="$W/tree/usr/lib/hermes-agent/gateway-boot/sitecustomize.py"
[ -f "$BOOT" ] || { echo "teeth: fault 11 planted nothing; no gateway sitecustomize in the tree" >&2; exit 1; }
cp "$BOOT" /tmp/boot.bak
printf '# deliberately empty: teeth.sh fault 11\n' > "$BOOT"
repack "$DEPS_OK"
expect_red "a gateway that stays dumpable" check_gateway_keys_hidden_from_its_user
cp /tmp/boot.bak "$BOOT"

# ---- fault 12: openwrt-mcp without its floor ----
# The shape every release up to r10 had. With r11's init that is a router where an upgrade of
# hermes-agent leaves an openwrt-mcp from before 0.5.0.3 in place; the init would then keep the
# narrow reads, and a guest Wi-Fi would stay out of reach with nothing in apk to say why.
repack "python3 python3-pip ca-bundle bash ffmpeg ffprobe ripgrep openwrt-mcp iputils-ping"
expect_red "openwrt-mcp with no version floor" check_needs_an_openwrt_mcp_that_redacts

# ---- and green again, so the reds above were the faults and not the harness ----
repack "$DEPS_OK"
APK="$W/mutant.apk" ARCH="$ARCH" "$ROOT/scripts/gate-package.sh" >/tmp/teeth.out 2>&1 || {
	echo "TEETH FAIL: the restored package is not green, so a fault was not undone"
	tail -20 /tmp/teeth.out; exit 1; }
rm -f "$W/mutant.apk"
echo "teeth: 12 faults, 12 distinct checks, green restored"
