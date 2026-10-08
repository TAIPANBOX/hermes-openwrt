# apk-retry.sh -- sourced inside every OpenWrt container a build or a gate starts, as `. /apk-retry.sh`.
#
# downloads.openwrt.org cuts downloads off now and then. On 2026-10-08 it did so all day: CI's
# build step died on "libreadline8 ... failed to extract ...: Connection aborted", a gate on 429,
# and a Flint 2 installing from the README got "2 errors;" with python3-light missing. apk itself
# never retries. So `apk` here is a function that runs the real one and, only when its output says
# a download was cut off, runs it again, up to five times, with a pause that grows. Any other
# failure (an untrusted signature, a missing package, a conflict) returns at once with apk's own
# status and output, so a gate that expects apk to refuse still sees it refuse the first time.
#
# The output is apk's, stdout and stderr together, printed after each try.
apk() {
	_ar_n=0
	while :; do
		_ar_out=$(command apk "$@" 2>&1); _ar_rc=$?
		[ -n "$_ar_out" ] && printf '%s\n' "$_ar_out"
		[ "$_ar_rc" -eq 0 ] && return 0
		case "$_ar_out" in
			*"Connection aborted"*|*"wget: exited with error"*|*"error 429"*|*"returned error: 429"*|*"Temporary failure"*|*"timed out"*|*"Connection reset"*) ;;
			*) return "$_ar_rc" ;;
		esac
		_ar_n=$((_ar_n + 1))
		[ "$_ar_n" -lt 5 ] || return "$_ar_rc"
		echo "apk-retry: a download from the feed was cut off; try $((_ar_n + 1)) of 5 in $((_ar_n * 10)) s" >&2
		sleep $((_ar_n * 10))
	done
}
