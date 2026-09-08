#!/bin/sh
# teeth-telegram.sh -- prove gate-telegram.sh can fail, and fail at the right check.
#
# Four faults, each one a change somebody could plausibly make, each caught by a
# different check. Two are packaging faults in the add-on and two are edits to the base
# package's init script, because half of what this gate protects is not in the add-on at
# all: it is the four refusals that keep a bot with router tools from answering strangers.
#
# The faults are applied to trees that were already built and the result repackaged. A
# rebuild per fault would quadruple the job and prove nothing extra: none of these is a
# build error.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
LINE=${LINE:-25.12}
BW="$ROOT/build/$LINE/$ARCH"
AW="$ROOT/build/$LINE/$ARCH-telegram"
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
INIT="$BW/tree/etc/init.d/hermes-agent"
ASITE="$AW/tree/usr/lib/hermes-agent/site-packages"

for d in "$BW/tree" "$AW/tree"; do
	[ -d "$d" ] || { echo "teeth-telegram: no tree at $d; build both packages first:"
		echo "  ./package/hermes-agent/build-in-container.sh $ARCH"
		echo "  ./package/hermes-agent-telegram/build-in-container.sh $ARCH"
		exit 1; }
done

# ---- refuse to start on a tree an earlier run left broken ----
#
# This script plants faults in a SHARED build tree, and the first version of it restored
# them only on the success path. A run that went red partway left the tree carrying its
# last fault, and the next run then backed THAT up as the original and faithfully
# restored it. The failure is silent and it points downstream: a feed built afterwards
# would have signed and published the mutation.
#
# So: the tree's copy of the init script must equal the repository's before anything is
# planted, and the trap below puts it back however this script exits.
if ! cmp -s "$ROOT/package/hermes-agent/files/hermes-agent.init" "$INIT"; then
	echo "teeth-telegram: the build tree's init script differs from the repository's." >&2
	echo "teeth-telegram: an earlier run left a fault in it. Rebuild before running teeth:" >&2
	echo "teeth-telegram:   ./package/hermes-agent/build-in-container.sh $ARCH" >&2
	exit 1
fi

cleanup() {
	# Unconditional, on every exit path, including a fault that never got restored.
	cp "$ROOT/package/hermes-agent/files/hermes-agent.init" "$INIT" 2>/dev/null || true
	chmod 0755 "$INIT" 2>/dev/null || true
	[ -d /tmp/telegram.bak ] && mv /tmp/telegram.bak "$ASITE/telegram" 2>/dev/null
	rm -f "$AW/tree/usr/bin/hermes"
	rmdir "$AW/tree/usr/bin" 2>/dev/null || true
	# The mutants are packages a feed builder would otherwise collect from these
	# directories and sign. They do not outlive this script.
	rm -f "$BW/mutant.apk" "$AW/mutant.apk"
}
trap cleanup EXIT INT TERM

# 0.19.0-r99, not the 0.0.0-r1 that teeth.sh uses for the base package on its own.
# The add-on declares `hermes-agent>=0.19.0 hermes-agent<0.19.1`, so a mutant base
# outside that range is refused by apk before any of these faults can be exercised: the
# first run of this script went red at check_no_file_collision for every base fault,
# which was the version constraint doing its job and telling us nothing about the fault.
repack_base() {
	docker run --rm -i -v "$BW:/work" -w /work "$ALPINE" apk mkpkg \
		--info "name:hermes-agent" --info "version:0.19.0-r99" --info "arch:$ARCH" \
		--info "license:MIT" --info "origin:hermes-agent" \
		--info "description:deliberately broken build, teeth-telegram.sh" \
		--info "depends:python3 python3-pip ca-bundle ffmpeg ffprobe ripgrep" \
		--script "post-install:/work/post-install" \
		--script "pre-deinstall:/work/pre-deinstall" \
		--files /work/tree --output /work/mutant.apk >/dev/null 2>&1
}

repack_addon() {
	docker run --rm -i -v "$AW:/work" -w /work "$ALPINE" apk mkpkg \
		--info "name:hermes-agent-telegram" --info "version:0.0.0-r1" --info "arch:$ARCH" \
		--info "license:MIT" --info "origin:hermes-agent-telegram" \
		--info "description:deliberately broken build, teeth-telegram.sh" \
		--info "depends:hermes-agent" \
		--files /work/tree --output /work/mutant.apk >/dev/null 2>&1
}

# Which artefact each run should use. A fault in one half is exercised against the real
# other half, so a red proves the fault and not the pairing.
#
# The unmutated half is left UNSET rather than resolved here, so the gate finds it the
# way it finds it normally. Working it out a second time in this script was a second
# source of truth and it went wrong the moment the gate's own resolution improved: this
# script kept reaching into the repository root, where an .apk carries no architecture
# and the last build of any architecture wins, and every fault came back as "the base
# package would not install" instead of the check it was aimed at.
run_gate() {
	base=$1; addon=$2
	# The positional list is reused to build the env prefix, so it is read before it is
	# cleared. Clearing first would have discarded both arguments.
	set --
	[ -n "$base" ]  && set -- "$@" "BASE=$base"
	[ -n "$addon" ] && set -- "$@" "ADDON=$addon"
	env "$@" ARCH="$ARCH" "$ROOT/scripts/gate-telegram.sh" >/tmp/teeth-tg.out 2>&1
}

expect_red() {
	name=$1; want=$2; base=${3:-}; addon=${4:-}
	if run_gate "$base" "$addon"; then
		echo "TEETH FAIL: $name left the gate green"; cat /tmp/teeth-tg.out; exit 1
	fi
	if ! grep -q "$want" /tmp/teeth-tg.out; then
		echo "TEETH FAIL: $name went red, but not at $want"
		grep FAIL /tmp/teeth-tg.out | head -3; exit 1
	fi
	echo "teeth ok: $name -> $want"
}

# ---- fault 1: the add-on ships a file the base package owns ----
# The one failure this package's whole shape exists to avoid. apk refuses the install;
# opkg would take it and leave the base package's manifest describing bytes it did not
# write, so removing the add-on later would delete a file the base still needs.
mkdir -p "$AW/tree/usr/bin"
cp "$BW/tree/usr/bin/hermes" "$AW/tree/usr/bin/hermes"
repack_addon
expect_red "add-on claims the base package's launcher" check_no_file_collision "" "$AW/mutant.apk"
rm -f "$AW/tree/usr/bin/hermes"; rmdir "$AW/tree/usr/bin" 2>/dev/null || true

# ---- fault 2: the library is not actually in the package ----
# A build that resolved the delta and then failed to install it would produce a package
# of exactly the right name, the right size order, and no library.
mv "$ASITE/telegram" /tmp/telegram.bak
repack_addon
expect_red "telegram library removed from the add-on" check_library_imports "" "$AW/mutant.apk"
mv /tmp/telegram.bak "$ASITE/telegram"

# ---- fault 3: the init no longer refuses an empty allowlist ----
# The security-relevant one. Upstream default-denies, so this fault does not open the
# bot by itself; what it does is let a router boot a Telegram bot that answers nobody
# and explains nothing, which is how an operator ends up setting allow_all to make it
# work at all.
cp "$INIT" /tmp/init.bak
sed 's/no user is allowed/UNCHECKED/' "$INIT" > /tmp/init.new && cp /tmp/init.new "$INIT"
repack_base
expect_red "allowlist refusal removed from the init" check_refuses_without_allowlist "$BW/mutant.apk" ""
cp /tmp/init.bak "$INIT"

# ---- fault 4: the init no longer says which package is missing ----
# The difference between a router that tells its owner to install one package and a
# router that says "telegram is enabled" and stops.
sed 's/client library is not installed/something went wrong/' "$INIT" > /tmp/init.new && cp /tmp/init.new "$INIT"
repack_base
expect_red "the missing-library message removed" check_refuses_without_library "$BW/mutant.apk" ""
cp /tmp/init.bak "$INIT"

# ---- and green again, so the reds were the faults and not the harness ----
repack_base
repack_addon
if ! run_gate "$BW/mutant.apk" "$AW/mutant.apk"; then
	echo "TEETH FAIL: the restored packages are not green, so a fault was not undone"
	tail -20 /tmp/teeth-tg.out; exit 1
fi
echo "teeth-telegram: 4 faults, 4 distinct checks, green restored"
