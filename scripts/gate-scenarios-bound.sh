#!/bin/sh
# gate-scenarios-bound.sh -- every scenario names a check, and every named check exists.
#
# Why a binding gate rather than a Gherkin runner
#
# The value asked for is that a feature file can be read INSTEAD of the code. A real
# runner (godog, cucumber, pytest-bdd) buys step definitions, which is a second
# implementation of the same behaviour and a second thing to keep true. What actually
# decays without enforcement is the LINK: a scenario is written, the check it describes
# is renamed six weeks later, and the feature file becomes prose that no longer
# corresponds to anything running.
#
# So this asserts the link, in both directions:
#
#   forward   every `# -> check_name` in a feature file names a check the gate lists
#   backward  every check the gate lists is claimed by some scenario
#
# The backward direction is the one that catches the real drift. Without it a gate can
# grow three checks nobody wrote a scenario for, and the feature file still reads as a
# complete description of the behaviour while covering half of it.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# feature file : the gates whose --selftest lists their checks, comma separated
#
# More than one gate per feature file, because a scenario describes BEHAVIOUR and the
# repository ships two release lines that prove it differently: apk refuses a colliding
# install and opkg silently accepts one, so the 24.10 gate has to compare file lists that
# the 25.12 gate can let apk compare. The set compared below is therefore the UNION of
# what the gates run. Requiring each gate to cover every scenario on its own would force
# the 24.10 gate to duplicate checks that differ in nothing but the release.
PAIRS='features/telegram.feature:scripts/gate-telegram.sh,scripts/gate-telegram-opkg.sh'

rc=0
for pair in $PAIRS; do
	feature=${pair%%:*}
	gate=${pair##*:}

	[ -f "$feature" ] || { echo "FAIL: no feature file at $feature"; exit 1; }

	# What the feature file claims.
	claimed=$(grep -o '# -> check_[a-z_]*' "$feature" | sed 's/# -> //' | sort -u)

	# What the gates actually run, taken together.
	listed=""
	ngates=0
	for g in $(echo "$gate" | tr ',' ' '); do
		[ -x "$g" ] || { echo "FAIL: $g is not executable"; exit 1; }
		one=$("$g" --selftest)
		# A gate whose selftest went quiet would silently shrink the union and let a
		# scenario go unproven while this file still reported a pass.
		[ -n "$one" ] || { echo "FAIL: $g --selftest listed no check at all"; exit 1; }
		listed=$(printf '%s\n%s\n' "$listed" "$one")
		ngates=$((ngates + 1))
	done
	listed=$(echo "$listed" | grep . | sort -u)

	nc=$(echo "$claimed" | grep -c . || true)
	nl=$(echo "$listed" | grep -c . || true)
	# A pair where either side reads as empty compares nothing with nothing and passes.
	# That is the failure this file exists to prevent, so it is asserted first.
	[ "$nc" -gt 0 ] || { echo "FAIL: $feature names no check at all"; exit 1; }
	[ "$nl" -gt 0 ] || { echo "FAIL: the gates listed no check at all"; exit 1; }

	# busybox has no comm; sort and uniq answer the same question.
	orphan_scenarios=$(printf '%s\n%s\n%s\n' "$claimed" "$listed" "$listed" | sort | uniq -u)
	orphan_checks=$(printf '%s\n%s\n%s\n' "$listed" "$claimed" "$claimed" | sort | uniq -u)

	if [ -n "$orphan_scenarios" ]; then
		echo "FAIL: $feature names checks no gate runs:"
		echo "$orphan_scenarios" | sed 's/^/    /'
		rc=1
	fi
	if [ -n "$orphan_checks" ]; then
		echo "FAIL: the gates run checks no scenario in $feature describes:"
		echo "$orphan_checks" | sed 's/^/    /'
		rc=1
	fi
	# A scenario without a binding comment is invisible to the two comparisons above: it
	# would be read as behaviour and enforce nothing.
	ns=$(grep -c '^  Scenario:' "$feature" || true)
	[ "$ns" -eq "$nc" ] || {
		echo "FAIL: $feature has $ns scenarios but $nc binding comments; one names no check"
		rc=1; }

	# Last, so a run that is about to report a failure never opens by announcing a pass.
	[ "$rc" -eq 0 ] && echo "PASS: $feature, $nc scenarios bound to $nl checks across $ngates gates"
done

exit $rc
