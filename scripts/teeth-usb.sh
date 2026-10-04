#!/bin/sh
# teeth-usb.sh -- gate-usb.sh has to turn red on each fault planted in hermes-usb or in the
# init, each caught by the check named beside it; with nothing planted it passes.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE=$ROOT/scripts/gate-usb.sh
USB=$ROOT/package/hermes-agent/files/hermes-usb
INIT=$ROOT/package/hermes-agent/files/hermes-agent.init
T=$(mktemp -d "${TMPDIR:-/tmp}/teeth-usb.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0

# $1 fault, $2 check, $3 file (usb|init), $4 text, $5 replacement
plant() {
	src=$USB; [ "$3" = init ] && src=$INIT
	python3 - "$src" "$T/$3" "$4" "$5" <<'PY' || { echo "TEETH FAILED: $1 (the text to plant over is gone)"; fail=1; return; }
import sys
src, dst, old, new = sys.argv[1:]
s = open(src).read()
if s.count(old) != 1:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new, 1))
PY
	if [ "$3" = init ]; then out=$(USB_INIT="$T/init" ONLY="$2" "$GATE" 2>&1)
	else out=$(USB_BIN="$T/usb" ONLY="$2" "$GATE" 2>&1); fi
	if printf '%s\n' "$out" | grep -q "^FAIL $2"; then echo "teeth ok: $1 -> $2"
	else echo "TEETH FAILED: $1 did not turn $2 red"; printf '%s\n' "$out" | tail -5 | sed 's/^/  /'; fail=1; fi
}
M=check_move_copies_and_restarts_on_the_stick
B=check_back_returns_the_data_inside

plant "no wait for the gateway" $M usb \
	'while busy && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done' ':'
plant "the pid record read as a bare number" $M usb \
	'gateway_pid() { sed -n' 'gateway_pid() { cat "$1/gateway.pid" 2>/dev/null; return; sed -n'
plant "the service group not waited for" $B usb \
	'	[ -n "$(cat "$CGROUP/cgroup.procs" 2>/dev/null)" ] && return 0
	return 1' '	return 1'
plant "back without the wait" $B usb \
	'	stop_gateway "$data_dir"
	if ! { mkdir' '	"$SERVICE" stop >/dev/null 2>&1
	if ! { mkdir'
plant "the copy inside left behind" $M usb \
	'	find "$data_dir" -xdev -mindepth 1 -maxdepth 1 -exec rm -rf {} +' '	:'
plant "a disk with something mounted taken" check_move_refuses_a_device_in_use usb \
	'		[ -z "$where" ] || die' '		[ -z "$where" ] || true'
plant "a device that is not on USB taken" check_move_refuses_a_device_in_use usb \
	'			*) die "$part is not on USB' '			*) true "$part is not on USB'
plant "a data directory already mounted taken" check_move_refuses_a_data_dir_set_up_by_hand usb \
	'	[ -z "$m" ] || die' '	[ -z "$m" ] || true'
plant "an fstab section on it ignored" check_move_refuses_a_data_dir_set_up_by_hand usb \
	'	[ -z "$s" ] || die' '	[ -z "$s" ] || true'
plant "a symbolic link followed" check_move_refuses_a_data_dir_set_up_by_hand usb \
	'	[ -L "$data_dir" ] && die' '	[ -L "$data_dir" ] && true'
plant "a copy that differs taken" check_copy_that_differs_switches_nothing usb \
	'	r=$?; rm -f /tmp/hermes-usb.a /tmp/hermes-usb.b; return $r' '	rm -f /tmp/hermes-usb.a /tmp/hermes-usb.b; return 0'
plant "no room check" check_move_refuses_a_stick_without_room usb \
	'	if ! num "$have" || [ "$have" -lt "$need" ]; then' '	if false; then'
plant "--format before the size is known" check_move_refuses_a_stick_without_room usb \
	'[ $(( sectors / 2 * 9 / 10 )) -ge "$need" ] ||' 'true ||'
plant "another filesystem formatted unasked" check_format_only_when_asked_and_without_lazy_init usb \
	'	elif [ "$t" != ext4 ]; then' '	elif false; then'
plant "lazy inode tables left to the kernel" check_format_only_when_asked_and_without_lazy_init usb \
	' -E lazy_itable_init=0,lazy_journal_init=0' ''
plant "missing tools not checked" check_missing_tools_named_and_nothing_changed usb \
	'	need_tools
	[ -z "$(uci -q get hermes.main.data_uuid)" ]' '	[ -z "$(uci -q get hermes.main.data_uuid)" ]'
plant "back leaves the fstab entry" $B usb \
	'	uci -q delete fstab.hermes_data; uci commit fstab
	uci -q delete hermes.main.data_uuid; uci commit hermes
	restart' '	uci -q delete hermes.main.data_uuid; uci commit hermes
	restart'
plant "back from any stick" $B usb \
	'	[ "$(uuid_of "$dev")" = "$want" ] || die' '	true || die'
plant "the init starts without the stick" check_missing_stick_stops_the_start init \
	'		if ! on_stick; then' '		if false; then'
plant "the init refuses even with the stick" check_missing_stick_stops_the_start init \
	'		if ! on_stick; then' '		if true; then'

out=$("$GATE" 2>&1) && echo "teeth ok: with nothing planted the gate passes" || {
	echo "TEETH FAILED: the gate does not pass as it is"; printf '%s\n' "$out" | tail -8 | sed 's/^/  /'; fail=1; }
exit "$fail"
