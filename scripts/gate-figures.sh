#!/bin/sh
# gate-figures.sh -- the README's figures come from their data, and the documentation's
# pictures and links all lead somewhere.
#
# The README was cut down to install steps, pictures and tables on 2026-10-05, and the long
# explanations moved to docs/. Two things decay after a move like that without anyone seeing:
# a figure redrawn by hand that no longer matches the numbers it shows, and a link or anchor
# that pointed at a section which now lives in another file. Both are checked here.
#
#   check_figures_match_their_data  scripts/figures.py, run on docs/measurements/figures.json,
#                                   writes exactly the SVGs that are committed
#   check_doc_images_exist          every picture README.md, CONTRIBUTING.md, SECURITY.md and
#                                   docs/*.md show is a file in the repository
#   check_doc_links_resolve         every relative link in them reaches a file, and every
#                                   #anchor a heading in that file
#
# ROOT may be set to check another tree (scripts/teeth-figures.sh does).
set -eu

CHECKS='check_figures_match_their_data check_doc_images_exist check_doc_links_resolve'
if [ "${1:-}" = "--selftest" ]; then
	for c in $CHECKS; do echo "$c"; done
	exit 0
fi

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:-$(cd "$HERE/.." && pwd)}
FIGURES="usb-choice.svg boxes.svg rerun.svg install-flow.svg unlock.svg"
rc=0

check_figures_match_their_data() {
	[ -f "$ROOT/docs/measurements/figures.json" ] || { echo "measured nothing: no docs/measurements/figures.json"; return 1; }
	out=$(mktemp -d)
	(cd "$ROOT" && python3 scripts/figures.py "$out") >/dev/null || { rm -rf "$out"; return 1; }
	r=0
	for f in $FIGURES; do
		[ -f "$ROOT/docs/$f" ] || { echo "  docs/$f is not committed"; r=1; continue; }
		cmp -s "$out/$f" "$ROOT/docs/$f" || { echo "  docs/$f differs from what scripts/figures.py draws from its data"; r=1; }
	done
	rm -rf "$out"
	return $r
}

check_doc_images_exist() { python3 "$HERE/docs_links.py" "$ROOT" images; }
check_doc_links_resolve() { python3 "$HERE/docs_links.py" "$ROOT" links; }

for c in $CHECKS; do
	if out=$($c 2>&1); then
		echo "PASS: $c ${out:+($(echo "$out" | tail -1))}"
	else
		echo "FAIL: $c"
		echo "$out" | sed 's/^/  /'
		rc=1
	fi
done
exit $rc
