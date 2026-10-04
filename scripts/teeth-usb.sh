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
if old not in s:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new, 1))
PY
	if [ "$3" = init ]; then out=$(USB_INIT="$T/init" ONLY="$2" "$GATE" 2>&1)
	else out=$(USB_BIN="$T/usb" ONLY="$2" "$GATE" 2>&1); fi
	if printf '%s\n' "$out" | grep -q "^FAIL $2"; then echo "teeth ok: $1 -> $2"
	else echo "TEETH FAILED: $1 did not turn $2 red"; printf '%s\n' "$out" | tail -5 | sed 's/^/  /'; fail=1; fi
}

plant "no wait for the gateway to go" check_move_copies_and_restarts_on_the_stick usb \
	'while [ -e "$1/gateway.pid" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done' ':'
plant "the copy inside left behind" check_move_copies_and_restarts_on_the_stick usb \
	'find "$data_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +' ':'
plant "a device in use taken anyway" check_move_refuses_a_device_in_use usb \
	'[ -z "$where" ] || die' '[ -z "$where" ] || true'
plant "no room check" check_move_refuses_a_stick_without_room usb \
	'if [ "$have" -lt "$need" ]; then' 'if false; then'
plant "another filesystem formatted unasked" check_format_only_when_asked_and_without_lazy_init usb \
	'elif [ "$t" != ext4 ]; then' 'elif false; then'
plant "lazy inode tables left to the kernel" check_format_only_when_asked_and_without_lazy_init usb \
	' -E lazy_itable_init=0,lazy_journal_init=0' ''
plant "missing tools not checked" check_missing_tools_named_and_nothing_changed usb \
	'	need_tools
	[ -b "$part" ]' '	[ -b "$part" ]'
plant "back leaves the fstab entry" check_back_returns_the_data_inside usb \
	'	uci -q delete fstab.hermes_data; uci commit fstab
	uci -q delete hermes.main.data_uuid' '	uci -q delete hermes.main.data_uuid'
plant "the init starts without the stick" check_missing_stick_stops_the_start init \
	'	if [ -n "$data_uuid" ]; then
		mdev=' '	if false; then
		mdev='

out=$("$GATE" 2>&1) && echo "teeth ok: with nothing planted the gate passes" || {
	echo "TEETH FAILED: the gate does not pass as it is"; printf '%s\n' "$out" | tail -8 | sed 's/^/  /'; fail=1; }
exit "$fail"
