#!/bin/sh
# teeth-usb.sh -- gate-usb.sh has to turn red on each fault planted in hermes-usb, the init, the
# shared stick check, the hotplug script, the gateway wrapper or hermes-login, each caught by the
# check named beside it; with nothing planted it passes.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE=$ROOT/scripts/gate-usb.sh
F=$ROOT/package/hermes-agent/files
T=$(mktemp -d "${TMPDIR:-/tmp}/teeth-usb.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0

# $1 fault, $2 check, $3 file (usb|init|lib|plug|gw|login), $4 text, $5 replacement
plant() {
	case "$3" in
		usb) src=$F/hermes-usb; var=USB_BIN ;;
		init) src=$F/hermes-agent.init; var=USB_INIT ;;
		lib) src=$F/hermes-usb-check; var=USB_LIB ;;
		plug) src=$F/hermes-usb.hotplug; var=USB_PLUG ;;
		gw) src=$F/hermes-gateway; var=USB_GW ;;
		login) src=$F/hermes-login; var=USB_LOGIN ;;
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

plant "no wait for the gateway" $M usb \
	'while { gateway_alive || group_busy; } && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done' ':'
plant "the pid record read as a bare number" $M usb \
	'gateway_pid() { sed -n' 'gateway_pid() { cat "$1/gateway.pid" 2>/dev/null; return; sed -n'
plant "the service group not waited for" $B usb \
	'group_busy()    { [ -n "$(cat "$CGROUP/cgroup.procs" 2>/dev/null)" ]; }' 'group_busy()    { false; }'
plant "back without the wait" $B usb \
	'	stop_gateway "$target"' '	"$SERVICE" stop >/dev/null 2>&1'
plant "the copy set aside inside left behind" $M usb \
	'	rm -rf "$aside"' '	:'
plant "a disk with another partition mounted taken" $U usb \
	'		[ -z "$where" ] || die' '		[ -z "$where" ] || true'
plant "a whole disk taken" $U usb \
	'	[ -e "/sys/class/block/$name/partition" ] || die' '	true || die'
plant "a device that is not on USB taken" $U usb \
	'			*) die "$part is not on USB' '			*) true "$part is not on USB'
plant "a data directory not on the root filesystem taken" $H usb \
	'	[ "$(mounted_on "$data_dir")" = / ] || die' '	true || die'
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
plant "back leaves the fstab entry" $B usb \
	'	uci -q delete fstab.hermes_data; uci commit fstab
	restart' '	restart'
plant "back deletes what is underneath" $B usb \
	'under="$target.underneath.$$"; mv "$target" "$under"; else rmdir "$target"; fi' 'rm -rf "$target"; else rmdir "$target"; fi'
plant "back from any stick" $B lib \
	'	if [ "$(block info "$_hd_dev" 2>/dev/null | sed -n '"'"'s/.*UUID="\([^"]*\)".*/\1/p'"'"')" != "$_hd_uuid" ]; then' '	if false; then'
plant "the stick check takes any mount point" $S lib \
	'	if [ "$_hd_mp" != "$_hd_dir" ]; then' '	if false; then'
plant "the init does not ask" $S init \
	'	why=$(hermes_data_ok "$data_dir") || { echo "$NAME: $why. Not starting." >&2; return 1; }' '	:'
plant "the wrapper does not ask (procd's respawn)" $S gw \
	'why=$(hermes_data_ok "$HERMES_HOME") || { echo "hermes-gateway: $why. Not starting." >&2; exit 1; }' ':'
plant "hermes-login does not ask" $S login \
	'why=$(hermes_data_ok "$data_dir") || { echo "hermes-login: $why" >&2; exit 1; }' ':'
plant "the stick's arrival starts nothing" $P plug \
	'		hermes_data_ok "$dir" >/dev/null && "$SERVICE" start' '		:'
plant "a disabled service started by a stick" $P plug \
	'		"$SERVICE" enabled >/dev/null 2>&1 || exit 0' '		:'
plant "the stick's departure stops nothing" $P plug \
	'		hermes_data_ok "$dir" >/dev/null || "$SERVICE" stop' '		:'

out=$("$GATE" 2>&1) && echo "teeth ok: with nothing planted the gate passes" || {
	echo "TEETH FAILED: the gate does not pass as it is"; printf '%s\n' "$out" | tail -8 | sed 's/^/  /'; fail=1; }
exit "$fail"
