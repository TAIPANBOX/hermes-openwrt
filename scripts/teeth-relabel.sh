#!/bin/sh
# teeth-relabel.sh -- prove gate-relabel.sh can fail, and fails on the fault it exists for.
#
# Two packages are made from one tiny tree, exactly as build-in-container.sh makes the
# relabelled copy from the primary: same files, same scripts, a different arch label.
# With the same depends the gate must stay green; with bash dropped from the second
# call, which is the r4 fault verbatim, it must go red and name bash; with a file
# missing it must say it measured nothing rather than pass.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT INT TERM
mkdir -p "$W/tree/usr/bin"
printf '#!/bin/sh\necho teeth\n' > "$W/tree/usr/bin/teeth-relabel"
chmod 0755 "$W/tree/usr/bin/teeth-relabel"

mk() { # mk <out> <arch> <depends>
	docker run --rm -i -v "$W:/work" -w /work "$ALPINE" apk mkpkg \
		--info "name:teeth-relabel" --info "version:0.0.0-r1" --info "arch:$2" \
		--info "license:MIT" --info "origin:teeth-relabel" \
		--info "description:teeth-relabel.sh" --info "depends:$3" \
		--files /work/tree --output "/work/$1" >/dev/null 2>&1
}
DEPS="python3 python3-pip ca-bundle bash ffmpeg ffprobe ripgrep"
mk primary.apk aarch64_generic "$DEPS"

# non-fault: the honest relabel
mk same.apk aarch64_cortex-a53 "$DEPS"
if ! "$ROOT/scripts/gate-relabel.sh" "$W/primary.apk" "$W/same.apk" >/tmp/teeth-relabel.out 2>&1; then
	echo "TEETH FAIL: the gate went red on an honest relabel"; cat /tmp/teeth-relabel.out; exit 1
fi
echo "teeth ok: honest relabel -> green"

# fault: the r4 defect, bash dropped from the second mkpkg call
mk nobash.apk aarch64_cortex-a53 "python3 python3-pip ca-bundle ffmpeg ffprobe ripgrep"
if "$ROOT/scripts/gate-relabel.sh" "$W/primary.apk" "$W/nobash.apk" >/tmp/teeth-relabel.out 2>&1; then
	echo "TEETH FAIL: bash missing on the relabelled package left the gate green"; exit 1
fi
grep -q -- "- bash" /tmp/teeth-relabel.out || { echo "TEETH FAIL: went red, but the diff does not name bash"; cat /tmp/teeth-relabel.out; exit 1; }
echo "teeth ok: bash dropped on the relabel -> red, names bash"

# absent subject: must not pass
if "$ROOT/scripts/gate-relabel.sh" "$W/primary.apk" "$W/missing.apk" >/tmp/teeth-relabel.out 2>&1; then
	echo "TEETH FAIL: a missing package passed"; exit 1
fi
grep -q "measured nothing" /tmp/teeth-relabel.out || { echo "TEETH FAIL: missing package failed without saying it measured nothing"; exit 1; }
echo "teeth ok: missing package -> measured nothing"
echo "teeth-relabel: 1 fault, 1 non-fault, 1 absent subject; green restored"
