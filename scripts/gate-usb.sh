#!/bin/sh
# gate-usb.sh -- hermes-usb, and the init's refusal to start without the stick, in OpenWrt's
# own rootfs with the built hermes-agent installed. A "stick" is an image file on a loop device
# inside a privileged, disposable container; mkfs, mount, block and the fstab are the real ones.
# The service is stood in for (there is no procd here) by a script that, like the gateway,
# removes gateway.pid a few seconds after it is told to stop, so a copy that does not wait for
# it is caught. The refusal without the stick is the installed init's own.
#
#   gate-usb.sh                 every check
#   ONLY="check_a" gate-usb.sh  just those (the teeth use this)
#   USB_BIN=/path gate-usb.sh   another hermes-usb over the installed one (teeth)
#   USB_INIT=/path gate-usb.sh  another init over the installed one (teeth)
#   gate-usb.sh --selftest      the check names, for gate-scenarios-bound.sh
set -u
CHECKS='check_missing_tools_named_and_nothing_changed check_status_names_where_data_lives check_move_copies_and_restarts_on_the_stick check_move_refuses_a_device_in_use check_move_refuses_a_stick_without_room check_format_only_when_asked_and_without_lazy_init check_missing_stick_stops_the_start check_back_returns_the_data_inside'
if [ "${1:-}" = "--selftest" ]; then for c in $CHECKS; do echo "$c"; done; exit 0; fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
LINE=${RELEASE%.*}
IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:$ARCH-$RELEASE}
PLATFORM=${PLATFORM:-linux/$ARCH}
APK=${APK:-$(ls -t "$ROOT/build/$LINE/$ARCH"/hermes-agent-[0-9]*.apk 2>/dev/null | head -1 || true)}
[ -n "$APK" ] && [ -f "$APK" ] || { echo "FAIL: measured nothing: no hermes-agent apk; build it first"; exit 1; }
MCP=$("$ROOT/scripts/mcp-apk.sh" "$ARCH") || exit 1
EXTRA=""
[ -n "${USB_BIN:-}" ] && EXTRA="$EXTRA -v $USB_BIN:/override/hermes-usb:ro"
[ -n "${USB_INIT:-}" ] && EXTRA="$EXTRA -v $USB_INIT:/override/hermes-agent.init:ro"
echo "PASS: artefacts $(basename "$APK"), $(basename "$MCP")"

# shellcheck disable=SC2086
docker run --rm -i --platform "$PLATFORM" --privileged -e ONLY="${ONLY:-}" -e CHECKS="$CHECKS" \
	-v "$APK:/pkg.apk:ro" -v "$MCP:/mcp.apk:ro" $EXTRA "$IMAGE" /bin/sh -s <<'CONTAINER'
set -u
mkdir -p /var/lock /var/run /var/state /stub
apk add --allow-untrusted /pkg.apk /mcp.apk >/tmp/install.log 2>&1 || { tail -5 /tmp/install.log; echo "FAIL setup: the package would not install"; exit 1; }
[ -f /override/hermes-usb ] && cp /override/hermes-usb /usr/sbin/hermes-usb && chmod 0755 /usr/sbin/hermes-usb
[ -f /override/hermes-agent.init ] && cp /override/hermes-agent.init /etc/init.d/hermes-agent && chmod 0755 /etc/init.d/hermes-agent
[ -x /usr/sbin/hermes-usb ] || { echo "FAIL: measured nothing: /usr/sbin/hermes-usb is not installed"; exit 1; }
apk add losetup dumpe2fs >/dev/null 2>&1 || { echo "FAIL setup: losetup and dumpe2fs would not install"; exit 1; }

# The stand-in service. stop: the "gateway" goes 3 s later, as the real one takes its time.
cat > /stub/svc <<'SVC'
#!/bin/sh
D=$(uci -q get hermes.main.data_dir); [ -n "$D" ] || D=/srv/hermes
case "$1" in
	stop)  echo "stop $(date +%s)" >> /tmp/svc.log; ( sleep 3; rm -f "$D/gateway.pid" "$D/gateway.sock"; echo "gone $(date +%s)" >> /tmp/svc.log ) & ;;
	start) echo "start $(date +%s) data_on=$(awk -v d="$D" '$2 == d { print $1 }' /proc/mounts)" >> /tmp/svc.log; echo 4242 > "$D/gateway.pid" ;;
esac
SVC
chmod 0755 /stub/svc
export HERMES_USB_SERVICE=/stub/svc

D=/srv/hermes
seed() {  # a data directory that looks like the agent's, with a running gateway's pid file
	rm -rf $D; mkdir -p $D/sessions $D/logs; chmod 0700 $D
	head -c 300000 /dev/urandom > $D/state.db; echo '{"a":1}' > $D/config.yaml
	for i in 1 2 3 4 5; do head -c 20000 /dev/urandom > $D/sessions/s$i.json; done
	echo log > $D/logs/agent.log; echo 4242 > $D/gateway.pid
	( cd $D && find . -type f ! -name gateway.pid -exec md5sum {} + | sort -k 2 ) > /tmp/seed.sums
}
# Loop devices are the kernel's, shared with whatever else the Docker host runs, so only the
# ones this gate attached are ever detached, and spare device nodes are made up front.
i=0; while [ $i -lt 64 ]; do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; i=$((i + 1)); done
: > /tmp/ours
stick() {  # $1 MiB, $2 mkfs type or "none"; prints the loop device
	f=/tmp/stick.$$.$RANDOM.img; dd if=/dev/zero of=$f bs=1M count=$1 2>/dev/null
	l=$(losetup -f --show $f); echo "$l $f" >> /tmp/ours
	case "$2" in ext4) mkfs.ext4 -q -F $l ;; ext2) mke2fs -q -F -t ext2 $l ;; none) ;; esac
	echo $l
}
detach() { while read -r l f; do umount $l 2>/dev/null; losetup -d $l 2>/dev/null; rm -f $f; done < /tmp/ours; : > /tmp/ours; }
reset() { umount $D 2>/dev/null; umount /mnt/busy 2>/dev/null; detach; uci -q delete fstab.hermes_data; uci commit fstab 2>/dev/null; uci -q delete hermes.main.data_uuid; uci commit hermes; rm -f /tmp/svc.log; }
SELECTED=" ${ONLY:-} "
run() { if [ -n "${ONLY:-}" ]; then case "$SELECTED" in *" $1 "*) ;; *) return 0 ;; esac; fi; CUR=$1; ( set -u; "$1" ) && echo "PASS $1" || { echo "FAIL $1"; FAILED=1; }; }
fail() { echo "  $CUR: $*"; exit 1; }
FAILED=0

check_missing_tools_named_and_nothing_changed() {
	reset; seed
	l=$(stick 64 none)
	out=$(hermes-usb move $l 2>&1); rc=$?
	[ $rc = 2 ] || fail "exit $rc, wanted 2: $out"
	echo "$out" | grep -q 'apk add kmod-usb-storage block-mount kmod-fs-ext4' || fail "the apk add line is missing: $out"
	[ ! -f /etc/config/fstab ] || ! grep -q hermes_data /etc/config/fstab || fail "fstab was changed"
	[ -z "$(uci -q get hermes.main.data_uuid)" ] || fail "data_uuid was set"
	( cd $D && find . -type f ! -name gateway.pid -exec md5sum {} + | sort -k 2 ) | cmp -s - /tmp/seed.sums || fail "the data changed"
}
tools() { apk add kmod-usb-storage block-mount kmod-fs-ext4 e2fsprogs >/dev/null 2>&1 || { echo "FAIL setup: the USB tools would not install"; exit 1; }; }

check_status_names_where_data_lives() {
	reset; seed
	out=$(hermes-usb status 2>&1)
	echo "$out" | grep -q "$D is on the router's own storage, [0-9]* KiB used" || fail "status said: $out"
}

check_move_copies_and_restarts_on_the_stick() {
	reset; seed
	l=$(stick 128 ext4); u=$(block info $l | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
	out=$(hermes-usb move $l 2>&1) || fail "move failed: $out"
	[ "$(awk -v d=$D '$2 == d { print $1 }' /proc/mounts)" = "$l" ] || fail "$D is not on $l"
	( cd $D && find . -type f ! -name gateway.pid -exec md5sum {} + | sort -k 2 ) | cmp -s - /tmp/seed.sums || fail "the data on the stick differs"
	# the gateway's own pid file must not have been copied: the copy began after it went
	grep -q '^gone' /tmp/svc.log || fail "the stand-in never saw the gateway go"
	st=$(sed -n 's/^start \([0-9]*\).*/\1/p' /tmp/svc.log | tail -1); [ -n "$st" ] || fail "the service was not started again"
	grep -q "^start .*data_on=$l" /tmp/svc.log || fail "the service started before the stick was on $D"
	[ "$(uci -q get fstab.hermes_data.uuid)" = "$u" ] && [ "$(uci -q get fstab.hermes_data.target)" = "$D" ] || fail "fstab does not mount $u on $D"
	[ "$(uci -q get hermes.main.data_uuid)" = "$u" ] || fail "hermes.main.data_uuid is not $u"
	rm -f $D/gateway.pid; umount $D
	[ -z "$(ls -A $D)" ] || fail "the copy inside was left: $(ls -A $D | tr '\n' ' ')"
	mount $l $D
}

check_move_refuses_a_device_in_use() {
	reset; seed
	l=$(stick 128 ext4); mkdir -p /mnt/busy && mount $l /mnt/busy
	out=$(hermes-usb move $l 2>&1) && fail "move went ahead: $out"
	echo "$out" | grep -q "is mounted on /mnt/busy" || fail "the reason was not named: $out"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	( cd $D && find . -type f ! -name gateway.pid -exec md5sum {} + | sort -k 2 ) | cmp -s - /tmp/seed.sums || fail "the data changed"
	umount /mnt/busy
}

check_move_refuses_a_stick_without_room() {
	reset; seed
	head -c 9000000 /dev/urandom > $D/big.bin
	( cd $D && find . -type f ! -name gateway.pid -exec md5sum {} + | sort -k 2 ) > /tmp/seed.sums
	l=$(stick 16 ext4)
	out=$(HERMES_USB_MARGIN_KB=4096 hermes-usb move $l 2>&1) && fail "move went ahead: $out"
	echo "$out" | grep -q "KiB free and needs" || fail "the size was not named: $out"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	[ -e /tmp/svc.log ] && grep -q '^stop' /tmp/svc.log && fail "the service was stopped for a move that could not happen"
	( cd $D && find . -type f ! -name gateway.pid -exec md5sum {} + | sort -k 2 ) | cmp -s - /tmp/seed.sums || fail "the data changed"
}

check_format_only_when_asked_and_without_lazy_init() {
	reset; seed
	l=$(stick 128 ext2)
	out=$(hermes-usb move $l 2>&1) && fail "an ext2 stick was used without --format: $out"
	echo "$out" | grep -q -- "--format would erase it" || fail "the refusal does not name --format: $out"
	[ "$(block info $l | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')" = ext2 ] || fail "the stick was changed without --format"
	out=$(hermes-usb move $l --format 2>&1) || fail "--format failed: $out"
	[ "$(block info $l | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')" = ext4 ] || fail "not ext4 after --format"
	groups=$(dumpe2fs $l 2>/dev/null | grep -c '^Group [0-9]')
	zeroed=$(dumpe2fs $l 2>/dev/null | grep '^Group [0-9]' | grep -c 'ITABLE_ZEROED')
	[ "$groups" -gt 0 ] || fail "measured nothing: dumpe2fs listed no block groups"
	[ "$groups" = "$zeroed" ] || fail "$zeroed of $groups inode tables written at format time: the filesystem would go on writing by itself"
}

check_missing_stick_stops_the_start() {
	reset; seed
	rm -rf $D; mkdir -p $D; chmod 0700 $D
	mkdir -p /etc/hermes-agent && printf '%s' sk-test-NotReal > /etc/hermes-agent/provider.key && chmod 600 /etc/hermes-agent/provider.key
	uci set hermes.main.enabled=1; uci set hermes.main.base_url=http://127.0.0.1:9/v1; uci set hermes.main.model=m
	uci set hermes.main.data_uuid=00000000-1111-2222-3333-444444444444; uci commit hermes
	out=$(/etc/init.d/hermes-agent start 2>&1)
	echo "$out" | grep -q "that stick is not" || fail "the start did not say the stick is missing: $out"
	[ -z "$(ls -A $D)" ] || fail "something was written inside: $(ls -A $D | tr '\n' ' ')"
	pgrep -f 'hermes_cli/main.py gateway' >/dev/null && fail "a gateway runs"
	uci -q delete hermes.main.data_uuid; uci set hermes.main.enabled=0; uci commit hermes
}

check_back_returns_the_data_inside() {
	reset; seed
	l=$(stick 128 ext4)
	hermes-usb move $l >/dev/null 2>&1 || fail "the move before it failed"
	rm -f /tmp/svc.log
	out=$(hermes-usb back 2>&1) || fail "back failed: $out"
	[ -z "$(awk -v d=$D '$2 == d { print $1 }' /proc/mounts)" ] || fail "$D is still a mount point"
	( cd $D && find . -type f ! -name gateway.pid -exec md5sum {} + | sort -k 2 ) | cmp -s - /tmp/seed.sums || fail "the data inside differs"
	grep -q hermes_data /etc/config/fstab && fail "the fstab entry is still there"
	[ -z "$(uci -q get hermes.main.data_uuid)" ] || fail "data_uuid is still set"
	grep -q '^start' /tmp/svc.log || fail "the service was not started again"
}

run check_missing_tools_named_and_nothing_changed
tools
for c in $CHECKS; do [ "$c" = check_missing_tools_named_and_nothing_changed ] || run "$c"; done
reset
[ $FAILED = 0 ] && echo "gate-usb: all checks passed" || { echo "gate-usb: FAILED"; exit 1; }
CONTAINER
