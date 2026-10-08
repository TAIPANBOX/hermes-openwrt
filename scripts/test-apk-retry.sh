#!/bin/sh
# test-apk-retry.sh -- apk-retry.sh retries a cut-off download and nothing else.
# A stand-in `apk` on PATH fails the way it is told to, a set number of times, and counts calls.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/apk" <<'STUB'
#!/bin/sh
n=$(cat "$STATE/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE/calls"
if [ "$n" -le "$FAILS" ]; then echo "$MSG"; exit 1; fi
echo "OK: 1 MiB in 1 packages"
STUB
chmod 0755 "$T/apk"
run() { # fails, message -> prints "rc calls"
	rm -f "$T/calls"
	rc=0
	( sleep() { :; }
	  PATH="$T:$PATH" STATE=$T FAILS=$1 MSG=$2; export PATH STATE FAILS MSG
	  . "$ROOT/scripts/apk-retry.sh"
	  apk add x ) >/dev/null 2>&1 || rc=$?
	echo "$rc $(cat "$T/calls")"
}
fail() { echo "FAIL $1: $2"; exit 1; }
[ "$(run 2 'ERROR: libreadline8-8.3-r1: Connection aborted')" = "0 3" ] || fail check_retries_a_cut_off_download "two cut-offs then OK should take three calls and succeed"
[ "$(run 9 'ERROR: wget: exited with error 4')" = "1 5" ] || fail check_gives_up_after_five "a feed that never answers should be tried five times, then fail"
[ "$(run 1 'ERROR: UNTRUSTED signature')" = "1 1" ] || fail check_never_retries_a_real_refusal "an untrusted signature must fail at once, untried again"
[ "$(run 0 '')" = "0 1" ] || fail check_success_is_one_call "a clean apk must run once"
# Under set -eu, as every build and gate sources it: a cut-off must still be retried, not end the shell.
rm -f "$T/calls"
out=$(PATH="$T:$PATH" STATE=$T FAILS=2 MSG='ERROR: wget: exited with error 4' \
	sh -eu -c 'sleep() { :; }; . "$1"; apk update -q; echo after-apk' x "$ROOT/scripts/apk-retry.sh" 2>&1) || true
case "$out" in *after-apk*) ;; *) fail check_retries_under_set_e "under set -eu a cut-off ended the shell instead of being retried: $out" ;; esac
[ "$(cat "$T/calls")" = 3 ] || fail check_retries_under_set_e "under set -eu, two cut-offs then OK should take three calls"
# Every script that starts an OpenWrt container and runs apk update or add in it sources the helper,
# so a new gate written without it cannot quietly go back to dying on the first cut-off download.
n=0
for f in "$ROOT"/scripts/*.sh "$ROOT"/package/*/build-in-container.sh; do
	case "$f" in */apk-retry.sh|*/test-apk-retry.sh) continue ;; esac
	# only inside the body of a heredoc fed to `sh -s`, up to its closing tag: a page that tells a
	# reader to run apk (build-feed.sh writes one) is not a container running it
	if awk 'h==0 && /sh -s <</ { t=$0; sub(/.*<</, "", t); gsub(/[^A-Za-z_]/, "", t); h=1; next }
	        h==1 && $0 == t { h=0; next }
	        h==1 && /(^|[;&|{ ])apk (-q )?(update|add) / { found=1 }
	        END { exit !found }' "$f"; then
		n=$((n + 1))
		grep -q '^\. /apk-retry\.sh' "$f" && grep -q 'scripts/apk-retry.sh:/apk-retry.sh:ro' "$f" \
			|| fail check_every_container_script_sources_it "$(basename "$f") runs apk in a container without /apk-retry.sh"
	fi
done
[ "$n" -gt 0 ] || fail check_every_container_script_sources_it "measured nothing: no script runs apk in a container"
echo "PASS: test-apk-retry (cut-off retried, also under set -e, five tries at most, a refusal never retried, success once; $n container scripts source it)"
