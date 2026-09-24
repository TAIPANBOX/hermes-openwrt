#!/bin/sh
# teeth-named-routers.sh -- gate-named-routers.sh has to fail on a box named by name and
# on one named by model number, pass a tree that names only the two test routers, and
# refuse to pass when there is nothing to read.
set -u
GATE=$(cd "$(dirname "$0")" && pwd)/gate-named-routers.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
# $1 the case, $2 the exit wanted, $3 the tree, $4 text the output has to hold
expect() {
	out=$("$GATE" "$3" 2>&1); rc=$?
	if [ "$rc" -eq "$2" ] && printf '%s\n' "$out" | grep -q -- "$4"; then
		echo "teeth ok: $1"
	else
		echo "TEETH FAILED: $1 (exit $rc, wanted $2)"; printf '%s\n' "$out" | sed 's/^/  /'; fail=1
	fi
}

mkdir -p "$T/clean/docs" "$T/by-name" "$T/by-model" "$T/empty"
printf 'Measured on the Flint 2 and the Brume 2, both aarch64_cortex-a53.\n' > "$T/clean/README.md"
printf '<svg><text>GL-MT6000 and GL-MT2500</text></svg>\n' > "$T/clean/docs/boxes.svg"
cp -R "$T/clean/." "$T/by-name/"
printf '# Found on a %s AX on 2026-09-15.\n' 'Beryl' >> "$T/by-name/README.md"
cp -R "$T/clean/." "$T/by-model/"
printf 'profile glinet_gl-%s\n' 'b3000' > "$T/by-model/notes.txt"

expect "the two test routers pass" 0 "$T/clean" "PASS: check_names_only_the_test_routers"
expect "a box named by name fails" 1 "$T/by-name" "README.md:2:"
expect "a box named by model number fails" 1 "$T/by-model" "notes.txt:1:"
expect "nothing to read refuses" 1 "$T/empty" "measured nothing"

[ "$fail" -eq 0 ] && echo "teeth-named-routers: 4 cases held"
exit "$fail"
