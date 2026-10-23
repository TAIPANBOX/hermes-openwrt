#!/bin/sh
# ci-subjects.sh -- which of CI's package legs a pull request needs, from the files it changes.
#
#   ci-subjects.sh <base> <head>   the files git says changed between them; prints the legs as JSON
#   ci-subjects.sh --files         the changed files on standard input, one per line (the test uses it)
#
# Every leg stays a required check, so a leg a change does not need still runs and passes in
# seconds, saying why; this decides which ones do their work. A push to main and a run by hand
# take every leg (the workflow does not call this for them).
#
# Conservative by construction: a file no rule names takes every leg, and so does anything the
# whole build stands on (the workflow, the build scripts, the upstream pin, apk-retry). A rule is
# added only where the leg it skips cannot be affected: the LuCI teeth plant faults in
# luci-app-hermes alone and are read by the LuCI gate, so a change to hermes-agent's own files
# leaves them out; every other leg plants or reads something of hermes-agent, so such a change
# takes them all. Documentation and the checks that read only documentation run in the
# scenarios job, which always runs.
set -u

ALL="core runtime teeth usb usb-teeth-0 usb-teeth-1 usb-teeth-2 usb-teeth-3 luci-teeth-0 luci-teeth-1 luci-teeth-2 luci-teeth-3 unlock unlock-teeth-0 unlock-teeth-1 unlock-teeth-2 unlock-teeth-3"
LUCI_TEETH="luci-teeth-0 luci-teeth-1 luci-teeth-2 luci-teeth-3"
USB="usb usb-teeth-0 usb-teeth-1 usb-teeth-2 usb-teeth-3"
UNLOCK="unlock unlock-teeth-0 unlock-teeth-1 unlock-teeth-2 unlock-teeth-3"

# The legs one changed file needs; "all" for every leg.
legs_for() {
	case "$1" in
		# what everything is built and run with
		.github/workflows/ci.yml|scripts/ci-subjects.sh|scripts/apk-retry.sh|scripts/mkpkg-root.sh|scripts/build-*|package/upstream/*)
			echo all ;;
		# read by the unlock gate (the hourly watch it runs in the sandbox), otherwise documentation
		docs/examples/*) echo "$UNLOCK" ;;
		# documentation, and the checks that read only it, which the scenarios job runs
		README.md|CONTRIBUTING.md|SECURITY.md|CLAUDE.md|LICENSE|.gitignore|docs/*|features/*|keys/*|.github/ISSUE_TEMPLATE/*)
			echo "" ;;
		.github/workflows/upstream-watch.yml|.github/workflows/secretscan.yml|scripts/hw-flow.sh|scripts/luci-preview.sh)
			echo "" ;;
		scripts/gate-scenarios-bound.sh|scripts/gate-named-routers.sh|scripts/teeth-named-routers.sh|scripts/gate-figures.sh|scripts/teeth-figures.sh|scripts/figures.py|scripts/docs_links.py|scripts/gate-upstream-watch.sh|scripts/teeth-upstream-watch.sh|scripts/upstream-watch.sh|scripts/test-apk-retry.sh|scripts/test-ci-subjects.sh|scripts/test-hw-flow.sh)
			echo "" ;;
		# the LuCI app: its gate and teeth, and the unlock gate, whose Security checks call its backend
		package/luci-app-hermes/*|scripts/gate-luci.sh|scripts/teeth-luci.sh|scripts/test-luci-views.mjs)
			echo "core $LUCI_TEETH $UNLOCK" ;;
		# hermes-agent and its add-on: every leg but the LuCI teeth (see the top)
		package/hermes-agent/*|package/hermes-agent-telegram/*)
			echo "core runtime teeth $USB $UNLOCK" ;;
		# one gate and its teeth each
		scripts/gate-unlock.sh|scripts/unlock-harness.py|scripts/security-harness.py|scripts/qr_decode.py|scripts/teeth-unlock.sh)
			echo "$UNLOCK" ;;
		scripts/gate-usb.sh|scripts/teeth-usb.sh) echo "$USB" ;;
		scripts/gate-runtime.sh|scripts/test-runtime.py|scripts/teeth-runtime.py) echo runtime ;;
		scripts/gate-package.sh|scripts/teeth.sh) echo "core teeth" ;;
		scripts/gate-upstream.sh|scripts/teeth-upstream.sh|scripts/gate-telegram.sh|scripts/teeth-telegram.sh|scripts/gate-relabel.sh|scripts/teeth-relabel.sh|scripts/gate-apk-owner.sh|scripts/teeth-apk-owner.sh|scripts/gate-feed.sh)
			echo core ;;
		*) echo all ;;
	esac
}

if [ "${1:-}" = --files ]; then
	files=$(cat)
elif [ $# -eq 2 ]; then
	files=$(git diff --name-only "$1" "$2") || { echo "ci-subjects: git diff $1 $2 failed" >&2; exit 1; }
else
	echo "usage: ci-subjects.sh <base> <head> | ci-subjects.sh --files" >&2
	exit 2
fi

want=""
for f in $files; do
	legs=$(legs_for "$f")
	[ "$legs" = all ] && { want=$ALL; break; }
	want="$want $legs"
done
# Every leg in ALL's order, once; JSON for the workflow's fromJSON.
out=""
for leg in $ALL; do
	case " $want " in *" $leg "*) out="$out${out:+,}\"$leg\"" ;; esac
done
echo "[$out]"
