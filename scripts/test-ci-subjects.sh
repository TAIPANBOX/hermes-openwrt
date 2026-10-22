#!/bin/sh
# test-ci-subjects.sh -- ci-subjects.sh picks the legs a change needs, and never fewer: a change to
# the product takes every leg that plants or reads it, anything unknown takes all of them, and only
# documentation takes none. Each case is a set of changed files and the legs it must give.
#
# And its teeth: the same cases against a selector that runs nothing and one that runs everything
# must fail, so a selector that quietly returns either is caught here.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SEL=${SELECTOR:-$ROOT/scripts/ci-subjects.sh}
ALL='["core","runtime","teeth","usb","usb-teeth-0","usb-teeth-1","usb-teeth-2","usb-teeth-3","luci-teeth-0","luci-teeth-1","luci-teeth-2","luci-teeth-3","unlock","unlock-teeth-0","unlock-teeth-1","unlock-teeth-2","unlock-teeth-3"]'
UNLOCK='"unlock","unlock-teeth-0","unlock-teeth-1","unlock-teeth-2","unlock-teeth-3"'
USB='"usb","usb-teeth-0","usb-teeth-1","usb-teeth-2","usb-teeth-3"'

fails=0 n=0
case_() {  # $1 name, $2 expected JSON, rest: changed files
	name=$1; want=$2; shift 2
	n=$((n + 1))
	got=$(printf '%s\n' "$@" | "$SEL" --files)
	[ "$got" = "$want" ] || { echo "FAIL: $name: want $want, got $got"; fails=$((fails + 1)); }
}
run_cases() {
	case_ "documentation only" '[]' README.md docs/security.md CLAUDE.md features/unlock.feature
	case_ "the README's figures" '[]' docs/measurements/figures.json scripts/figures.py docs/boxes.svg
	case_ "the hourly watch the unlock gate runs" "[$UNLOCK]" docs/examples/router_check.sh
	case_ "a hermes-agent file" "[\"core\",\"runtime\",\"teeth\",$USB,$UNLOCK]" package/hermes-agent/files/hermes-jail.py
	case_ "the Telegram add-on" "[\"core\",\"runtime\",\"teeth\",$USB,$UNLOCK]" package/hermes-agent-telegram/build-in-container.sh
	case_ "the LuCI app" "[\"core\",\"luci-teeth-0\",\"luci-teeth-1\",\"luci-teeth-2\",\"luci-teeth-3\",$UNLOCK]" package/luci-app-hermes/root/usr/libexec/rpcd/hermes
	case_ "the unlock gate" "[$UNLOCK]" scripts/gate-unlock.sh scripts/unlock-harness.py
	case_ "the usb teeth" "[$USB]" scripts/teeth-usb.sh
	case_ "the runtime tests" '["runtime"]' scripts/test-runtime.py
	case_ "the package gate" '["core","teeth"]' scripts/gate-package.sh
	case_ "the workflow" "$ALL" .github/workflows/ci.yml
	case_ "the upstream pin" "$ALL" package/upstream/upstream.env
	case_ "a file no rule names" "$ALL" scripts/something-new.sh
	case_ "an unknown file beside documentation" "$ALL" README.md Makefile
	case_ "two subjects together" "[\"runtime\",$USB]" scripts/test-runtime.py scripts/gate-usb.sh
}

run_cases
[ "$n" -gt 0 ] || { echo "FAIL: measured nothing: no case ran"; exit 1; }
[ "$fails" -eq 0 ] || { echo "test-ci-subjects: $fails of $n cases failed"; exit 1; }
echo "PASS: test-ci-subjects ($n cases)"

# teeth: a selector that runs nothing, and one that runs everything, must each fail some case
[ -z "${SELECTOR:-}" ] || exit 0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '#!/bin/sh\ncat >/dev/null; echo "[]"\n' > "$W/none"
printf '#!/bin/sh\ncat >/dev/null; echo %s\n' "'$ALL'" > "$W/all"
chmod 755 "$W/none" "$W/all"
for bad in none all; do
	if SELECTOR="$W/$bad" "$0" >/dev/null 2>&1; then echo "TEETH FAIL: a selector that runs $bad passed"; exit 1; fi
	echo "teeth ok: a selector that runs $bad fails"
done
