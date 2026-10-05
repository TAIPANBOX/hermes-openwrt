#!/bin/sh
# teeth-figures.sh -- gate-figures.sh must fail on each fault it exists for, pass on a clean
# copy, and refuse a tree with nothing to read.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
n=0

fresh() {
	rm -rf "$T/r"; mkdir -p "$T/r"
	# the whole tree git knows (untracked files included), so every link has its target
	(cd "$SRC" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar cf -) | tar xf - -C "$T/r"
}
expect() { # name, want rc (0 pass, 1 fail), the check whose line must say so
	name=$1 want=$2 check=$3
	set +e; out=$(ROOT="$T/r" "$HERE/gate-figures.sh" 2>&1); rc=$?; set -e
	if [ "$want" = 0 ]; then
		[ "$rc" = 0 ] || { echo "teeth FAILED: $name: the gate failed on a clean copy"; echo "$out"; exit 1; }
	else
		echo "$out" | grep -q "^FAIL: $check" || { echo "teeth FAILED: $name: $check did not fail"; echo "$out"; exit 1; }
	fi
	echo "teeth ok: $name"; n=$((n + 1))
}

fresh; expect "a clean copy passes" 0 -

fresh; sed -i.bak 's/"install: key, feed line, apk add", 24, 64/"install: key, feed line, apk add", 24, 99/' "$T/r/docs/measurements/figures.json"
grep -q ', 24, 99' "$T/r/docs/measurements/figures.json" || { echo "teeth FAILED: the data fault was not planted"; exit 1; }
expect "a number changed in the data and not redrawn" 1 check_figures_match_their_data

fresh; printf '\n![gone](docs/no-such-figure.svg)\n' >> "$T/r/README.md"
expect "a picture that is not there" 1 check_doc_images_exist

fresh; printf '\nSee [the usb section](docs/usb.md#no-such-heading).\n' >> "$T/r/README.md"
expect "an anchor no heading gives" 1 check_doc_links_resolve

fresh; printf '\nSee [moved](docs/no-such-file.md).\n' >> "$T/r/docs/use.md"
expect "a link to a file that is not there" 1 check_doc_links_resolve

rm -rf "$T/r"; mkdir -p "$T/r/scripts"; cp "$SRC/scripts/figures.py" "$T/r/scripts/"
set +e; out=$(ROOT="$T/r" "$HERE/gate-figures.sh" 2>&1); rc=$?; set -e
{ [ "$rc" != 0 ] && echo "$out" | grep -q "measured nothing"; } || { echo "teeth FAILED: an empty tree was not refused"; echo "$out"; exit 1; }
echo "teeth ok: nothing to read is refused"; n=$((n + 1))
echo "teeth-figures: $n cases held"
