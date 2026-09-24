#!/bin/sh
# teeth.sh -- prove gate-package.sh can actually fail, and fail at the right check.
#
# Five faults, each one a real change could introduce, each caught by a different
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
DEPS_OK="python3 python3-pip ca-bundle bash ffmpeg ffprobe ripgrep"

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
	[ -f /tmp/wrap.bak ] && cp /tmp/wrap.bak "$W/tree/usr/sbin/hermes-gateway" 2>/dev/null
	chmod 0755 "$W/post-install" 2>/dev/null || true
	# The init is restored from the repository rather than from a backup: a backup taken
	# at the top of a run that had already been poisoned by an earlier crashed run would
	# faithfully restore the poison.
	cp "$ROOT/package/hermes-agent/files/hermes-agent.init" "$W/tree/etc/init.d/hermes-agent" 2>/dev/null || true
	chmod 0755 "$W/tree/etc/init.d/hermes-agent" 2>/dev/null || true
	rm -f "$W/mutant.apk"
}
trap cleanup EXIT INT TERM

repack() {
	docker run --rm -i -v "$W:/work" -w /work "$ALPINE" apk mkpkg \
		--info "name:hermes-agent" --info "version:0.0.0-r1" --info "arch:$ARCH" \
		--info "license:MIT" --info "origin:hermes-agent" \
		--info "description:deliberately broken build, teeth.sh" \
		--info "depends:$1" \
		--script "post-install:/work/post-install" \
		--script "pre-deinstall:/work/pre-deinstall" \
		--files /work/tree --output /work/mutant.apk >/dev/null 2>&1
}

expect_red() {
	name=$1; want=$2
	if APK="$W/mutant.apk" ARCH="$ARCH" "$ROOT/scripts/gate-package.sh" >/tmp/teeth.out 2>&1; then
		echo "TEETH FAIL: $name left the gate green"; cat /tmp/teeth.out; exit 1
	fi
	if ! grep -q "$want" /tmp/teeth.out; then
		echo "TEETH FAIL: $name went red, but not at $want"; grep FAIL /tmp/teeth.out | head -3; exit 1
	fi
	echo "teeth ok: $name -> $want"
}

# ---- fault 1: no webbrowser shim ----
# The check this must trip is the one the whole musllinux-wheel bet rests on. OpenWrt
# ships no webbrowser in any python3-* package, so without the shim the CLI cannot
# print its own version, and a package that shipped like that would look complete right
# up until someone ran it.
cp "$SITE/webbrowser.py" /tmp/shim.bak
rm -f "$SITE/webbrowser.py" "$SITE/__pycache__/webbrowser."*
repack "$DEPS_OK"
expect_red "webbrowser shim removed" check_cli_runs
cp /tmp/shim.bak "$SITE/webbrowser.py"

# ---- fault 2: an undeclared runtime dependency ----
# apk would not complain: the package installs fine without ffmpeg declared, and the
# gap only shows the first time someone sends a voice message.
repack "python3 python3-pip ca-bundle ripgrep"
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
sed 's|^exec /usr/bin/hermes gateway run --external-supervisor$|sleep 12; exec /usr/bin/hermes gateway run --external-supervisor --toolsets file,web|' \
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

# ---- and green again, so the reds above were the faults and not the harness ----
repack "$DEPS_OK"
APK="$W/mutant.apk" ARCH="$ARCH" "$ROOT/scripts/gate-package.sh" >/tmp/teeth.out 2>&1 || {
	echo "TEETH FAIL: the restored package is not green, so a fault was not undone"
	tail -20 /tmp/teeth.out; exit 1; }
rm -f "$W/mutant.apk"
echo "teeth: 5 faults, 5 distinct checks, green restored"
