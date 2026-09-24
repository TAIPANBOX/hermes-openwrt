#!/bin/sh
# gate-named-routers.sh -- the routers this repository is tested on, and the only routers
# it names, are the GL.iNet Flint 2 and Brume 2 (CLAUDE.md, invariant 15). A finding made
# on another box is described by its architecture instead. This fails on the lab's other
# boxes, by name or by model number, anywhere in the tracked tree.
#
#   gate-named-routers.sh             the repository's tracked files
#   gate-named-routers.sh DIR         every file under DIR (teeth-named-routers.sh uses it)
#   gate-named-routers.sh --selftest  the check it runs, for gate-scenarios-bound.sh
set -u
CHECK=check_names_only_the_test_routers
if [ "${1:-}" = "--selftest" ]; then echo "$CHECK"; exit 0; fi

# The lab's other boxes. This file and its teeth are the only ones allowed to spell them,
# so both are left out of the search.
OTHERS='beryl|marble|mt3000|b3000'

LIST=$(mktemp) HITS=$(mktemp)
trap 'rm -f "$LIST" "$LIST.kept" "$HITS"' EXIT
if [ -n "${1:-}" ]; then
	cd "$1" || exit 1
	find . -type f | sed 's|^\./||' > "$LIST"
else
	cd "$(dirname "$0")/.." || exit 1
	git ls-files > "$LIST"
fi
grep -v -E '^scripts/(gate|teeth)-named-routers\.sh$' "$LIST" > "$LIST.kept"
n=$(grep -c . "$LIST.kept")
[ "$n" -gt 0 ] || { echo "FAIL: $CHECK measured nothing: no files to read"; exit 1; }

tr '\n' '\0' < "$LIST.kept" | xargs -0 grep -n -i -I -E "$OTHERS" > "$HITS" 2>/dev/null
if [ -s "$HITS" ]; then
	echo "FAIL: $CHECK: a router this repository is not tested on is named:"
	sed 's/^/  /' "$HITS"
	exit 1
fi
echo "PASS: $CHECK ($n files read, none names a router but the Flint 2 and the Brume 2)"
