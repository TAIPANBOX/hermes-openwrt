#!/bin/sh
# teeth-usb.sh -- gate-usb.sh has to turn red on each fault planted in hermes-usb, the init, the
# shared stick check, the hotplug script, the gateway wrapper, hermes-login or the hermes launcher,
# each caught by the check named beside it; with nothing planted it passes.
#   SHARD=i/n teeth-usb.sh   only every n-th fault from the i-th (CI spreads them over runners)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE=$ROOT/scripts/gate-usb.sh
F=$ROOT/package/hermes-agent/files
T=$(mktemp -d "${TMPDIR:-/tmp}/teeth-usb.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0; k=0
SHARD_I=${SHARD%/*}; SHARD_N=${SHARD#*/}
[ -n "${SHARD:-}" ] || { SHARD_I=0; SHARD_N=1; }
# the launcher is written by build.sh; take it from there
sed -n "/^cat > \"\$OUT\/usr\/bin\/hermes\" <<'LAUNCHER'$/,/^LAUNCHER$/p" "$ROOT/package/hermes-agent/build.sh" | sed '1d;$d' > "$T/launcher.src"
[ -s "$T/launcher.src" ] || { echo "TEETH FAILED: measured nothing: the launcher is not in build.sh where expected"; exit 1; }

# $1 fault, $2 check, $3 file (usb|init|lib|plug|gw|login|launcher), $4 text, $5 replacement
plant() {
	k=$((k + 1)); [ $(( (k - 1) % SHARD_N )) -eq "$SHARD_I" ] || return 0
	case "$3" in
		usb) src=$F/hermes-usb; var=USB_BIN ;;
		init) src=$F/hermes-agent.init; var=USB_INIT ;;
		lib) src=$F/hermes-usb-check; var=USB_LIB ;;
		plug) src=$F/hermes-usb.hotplug; var=USB_PLUG ;;
		gw) src=$F/hermes-gateway; var=USB_GW ;;
		login) src=$F/hermes-login; var=USB_LOGIN ;;
		launcher) src=$T/launcher.src; var=USB_LAUNCHER ;;
	esac
	python3 - "$src" "$T/$3" "$4" "$5" <<'PY' || { echo "TEETH FAILED: $1 (the text to plant over is not there exactly once)"; fail=1; return; }
import sys
src, dst, old, new = sys.argv[1:]
s = open(src).read()
if s.count(old) != 1:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new, 1))
PY
	out=$(env "$var=$T/$3" ONLY="$2" "$GATE" 2>&1)
	if printf '%s\n' "$out" | grep -q "^FAIL $2"; then echo "teeth ok: $1 -> $2"
	else echo "TEETH FAILED: $1 did not turn $2 red"; printf '%s\n' "$out" | tail -5 | sed 's/^/  /'; fail=1; fi
}
M=check_move_copies_and_restarts_on_the_stick
B=check_back_returns_the_data_inside
U=check_move_refuses_a_device_in_use
H=check_move_refuses_a_data_dir_set_up_by_hand
S=check_missing_stick_stops_the_start
P=check_stick_coming_and_going
I=check_interrupted_or_running_move_starts_nothing

# the waits
plant "no wait for the gateway" $M usb \
	'while { gateway_alive || group_busy; } && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done' ':'
plant "the pid record read as a bare number" $M usb \
	'gateway_pid() { sed -n' 'gateway_pid() { cat "$1/gateway.pid" 2>/dev/null; return; sed -n'
plant "the service group not waited for" $B usb \
	'group_busy()    { [ -n "$(cat "$CGROUP/cgroup.procs" 2>/dev/null)" ]; }' 'group_busy()    { false; }'
plant "back without the wait" $B usb \
	'	stop_gateway "$target"' '	"$SERVICE" stop >/dev/null 2>&1'
# move
plant "the copy set aside inside left behind" $M usb \
	'	rm -rf "$aside"' '	:'
plant "a disk with another partition mounted taken" $U usb \
	'		[ -z "$where" ] || die' '		[ -z "$where" ] || true'
plant "a whole disk taken" $U usb \
	'	[ -e "/sys/class/block/$name/partition" ] || die' '	true || die'
plant "a device that is not on USB taken" $U usb \
	'			*) die "$part is not on USB' '			*) true "$part is not on USB'
plant "a data directory not on the root filesystem taken" $H usb \
	'	[ "$(mounted_on "$data_dir")" = / ] && [ -z "$(hermes_mount_source "$data_dir")" ] \' '	true \'
plant "an fstab section on it ignored" $H usb \
	'	[ -z "$s" ] || die' '	[ -z "$s" ] || true'
plant "a symbolic link followed" $H usb \
	'	[ "$(readlink -f "$data_dir")" = "$data_dir" ] || die' '	true || die'
plant "a system tree taken" $H usb \
	'/etc|/etc/*|/usr|' '/nonexistent|/usr|'
plant "a copy that differs taken" check_copy_that_differs_switches_nothing usb \
	'	r=$?; rm -f "$a" "$b"; return $r' '	rm -f "$a" "$b"; return 0'
plant "no room check" check_move_refuses_a_stick_without_room usb \
	'	num "$have" && [ "$have" -ge "$need" ] || die "$part has' '	true || die "$part has'
plant "--format before the size is known" check_move_refuses_a_stick_without_room usb \
	'[ $(( sectors / 2 * 8 / 10 )) -ge "$need" ] ||' 'true ||'
plant "another filesystem formatted unasked" check_format_only_when_asked_and_without_lazy_init usb \
	'	elif [ "$t" != ext4 ]; then' '	elif false; then'
plant "lazy inode tables left to the kernel" check_format_only_when_asked_and_without_lazy_init usb \
	' -E lazy_itable_init=0,lazy_journal_init=0' ''
plant "blocks reserved for root" check_format_only_when_asked_and_without_lazy_init usb \
	'mkfs.ext4 -F -q -m 0' 'mkfs.ext4 -F -q'
plant "missing tools not checked" check_missing_tools_named_and_nothing_changed usb \
	'	need_tools
	lock' '	lock'
plant "a failed mount leaves the data set aside" check_failed_mount_puts_everything_back usb \
	'		put_back "$aside" "$data_dir"; die "could not mount $part on $data_dir' '		die "could not mount $part on $data_dir'
plant "move beside a copy an interrupted move left" $I usb \
	'	left=$(hermes_data_leftovers "$data_dir"); [ -z "$left" ] || die' '	left=""; true || die'
# back
plant "back leaves the fstab entry" $B usb \
	'	uci -q delete fstab.hermes_data; uci commit fstab
	unlock; restart' '	unlock; restart'
plant "back deletes what is underneath" $B usb \
	'		mv "$target" "$under" || { remount; die "could not set aside what lies under $target; the stick is mounted again, nothing was switched"; }' '		rm -rf "$target"'
plant "a failed back leaves the stick unmounted" check_failed_back_puts_the_stick_back usb \
	'		remount; die "could not put the copy in place' '		die "could not put the copy in place'
# forget
plant "forget without --yes" check_lost_stick_forgotten usb \
	'	[ "${1:-}" = --yes ] || die "forget gives up' '	true || die "forget gives up'
plant "forget with the stick mounted" check_lost_stick_forgotten usb \
	'	[ -z "$(hermes_mount_source "$target")" ] || die "a stick is mounted on $target;' '	true || die "a stick is mounted on $target;'
# the shared check
plant "back from any stick" $B lib \
	'	if [ "$(block info "$_hd_dev" 2>/dev/null | sed -n '"'"'s/.*UUID="\([^"]*\)".*/\1/p'"'"')" != "$_hd_uuid" ]; then' '	if false; then'
plant "a stick on a parent taken for the stick on the directory" $S lib \
	'if ($5 == d) last = src' 'if (index(d, $5) == 1 && $5 != "/") last = src'
plant "a disabled section read as the data inside" $S lib \
	'	if [ "$(uci -q get fstab.hermes_data.enabled)" = 0 ]; then' '	if [ "$(uci -q get fstab.hermes_data.enabled)" = 0 ]; then return 0; fi; if false; then'
plant "a section without a UUID read as the data inside" $S lib \
	'	if [ "$_hd_uuid" = "?" ]; then' '	if [ "$_hd_uuid" = "?" ]; then return 0; fi; if false; then'
plant "a running move's lock ignored" $I lib \
	'	if [ -z "${HERMES_USB_SELF:-}" ] && [ -d "$HERMES_USB_LOCK" ]; then' '	if false; then'
plant "a stale lock taken for a running move" $I lib \
	'		if [ -n "$_hd_pid" ] && [ -d "/proc/$_hd_pid" ]; then' '		if true; then'
plant "a copy an interrupted move left ignored" $I lib \
	'	if [ -n "$_hd_left" ]; then' '	if false; then'
# the callers
plant "the init does not ask" $S init \
	'	why=$(hermes_data_ok "$data_dir") || { echo "$NAME: $why. Not starting." >&2; return 1; }' '	:'
plant "the wrapper does not ask (procd's respawn)" $S gw \
	'why=$(hermes_data_ok "$HERMES_HOME") || { echo "hermes-gateway: $why. Not starting." >&2; exit 1; }' ':'
plant "hermes-login does not ask" $S login \
	'why=$(hermes_data_ok "$data_dir") || { echo "hermes-login: $why" >&2; exit 1; }' ':'
plant "the launcher does not ask" $S launcher \
	'	why=$(hermes_data_ok "${HERMES_HOME%/}") || { echo "hermes: $why" >&2; exit 1; }' '	:'
# hotplug
plant "the stick's arrival starts nothing" $P plug \
	'		"$SERVICE" start' '		:'
plant "any device's arrival starts Hermes" $P plug \
	'		[ "$(hermes_mount_source "$dir")" = "/dev/${DEVNAME:-}" ] || exit 0' '		:'
plant "a disabled service started by a stick" $P plug \
	'		"$SERVICE" enabled >/dev/null 2>&1 || exit 0' '		:'
plant "the stick's departure stops nothing" $P plug \
	'		hermes_data_ok "$dir" >/dev/null || "$SERVICE" stop' '		:'
plant "any device's departure stops Hermes" $P plug \
	'		hermes_data_ok "$dir" >/dev/null || "$SERVICE" stop' '		"$SERVICE" stop'

if [ "$SHARD_I" = 0 ]; then
	out=$("$GATE" 2>&1) && echo "teeth ok: with nothing planted the gate passes" || {
		echo "TEETH FAILED: the gate does not pass as it is"; printf '%s\n' "$out" | tail -8 | sed 's/^/  /'; fail=1; }
fi
exit "$fail"
