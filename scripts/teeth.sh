#!/bin/sh
# teeth.sh -- prove gate-package.sh can actually fail, and fail at the right check.
#
# Three faults, each one a real change could introduce, each caught by a different
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
DEPS_OK="python3 python3-pip ca-bundle ffmpeg ffprobe ripgrep"

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
	chmod 0755 "$W/post-install" 2>/dev/null || true
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

# ---- and green again, so the reds above were the faults and not the harness ----
repack "$DEPS_OK"
APK="$W/mutant.apk" ARCH="$ARCH" "$ROOT/scripts/gate-package.sh" >/tmp/teeth.out 2>&1 || {
	echo "TEETH FAIL: the restored package is not green, so a fault was not undone"
	tail -20 /tmp/teeth.out; exit 1; }
rm -f "$W/mutant.apk"
echo "teeth: 3 faults, 3 distinct checks, green restored"
