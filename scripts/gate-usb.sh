#!/bin/sh
# gate-usb.sh -- hermes-usb, and the init's refusal to start without the stick, in OpenWrt's
# own rootfs with the built hermes-agent installed. A "stick" is an image file on a loop device
# inside a privileged, disposable container; mkfs, mount, block and the fstab are the real ones.
# Loop devices are not on USB, so the command's USB test is lifted with HERMES_USB_ANY_DEVICE=1
# everywhere but the one check that proves the test refuses them.
#
# The service is stood in for (there is no procd here) by a gateway shaped like the real one's
# shutdown as a Flint 2 showed it on 2026-10-04: its pid file is a JSON record as upstream
# writes it, and told to stop it removes that file after a second and makes its last write
# three seconds later. In "pid" mode its own process makes that write; in "cgroup" mode the pid
# in the record is already gone and a second process, listed in a stand-in cgroup.procs, makes
# it. So the wait on the process and the wait on the group are each needed by one check.
# The refusal without the stick, and the start with it, are the installed init's own.
#
#   gate-usb.sh                 every check
#   ONLY="check_a" gate-usb.sh  just those (the teeth use this)
#   USB_BIN=/path gate-usb.sh   another hermes-usb over the installed one (teeth)
#   USB_INIT=/path gate-usb.sh  another init over the installed one (teeth)
#   gate-usb.sh --selftest      the check names, for gate-scenarios-bound.sh
set -u
CHECKS='check_missing_tools_named_and_nothing_changed check_status_names_where_data_lives check_move_copies_and_restarts_on_the_stick check_move_refuses_a_device_in_use check_move_refuses_a_data_dir_set_up_by_hand check_copy_that_differs_switches_nothing check_move_refuses_a_stick_without_room check_format_only_when_asked_and_without_lazy_init check_missing_stick_stops_the_start check_back_returns_the_data_inside'
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
mkdir -p /var/lock /var/run /var/state /stub /tmp/cg
apk add --allow-untrusted /pkg.apk /mcp.apk >/tmp/install.log 2>&1 || { tail -5 /tmp/install.log; echo "FAIL setup: the package would not install"; exit 1; }
[ -f /override/hermes-usb ] && cp /override/hermes-usb /usr/sbin/hermes-usb && chmod 0755 /usr/sbin/hermes-usb
[ -f /override/hermes-agent.init ] && cp /override/hermes-agent.init /etc/init.d/hermes-agent && chmod 0755 /etc/init.d/hermes-agent
[ -x /usr/sbin/hermes-usb ] || { echo "FAIL: measured nothing: /usr/sbin/hermes-usb is not installed"; exit 1; }
apk add losetup dumpe2fs >/dev/null 2>&1 || { echo "FAIL setup: losetup and dumpe2fs would not install"; exit 1; }

# The stand-in gateway. $1 data dir, $2 mode (pid | cgroup).
cat > /stub/gw <<'GW'
#!/bin/sh
D=$1; MODE=$2
echo wal > "$D/state.db-wal"
if [ "$MODE" = cgroup ]; then
	# the recorded pid exits at once; the one that writes last is only in the group
	sh -c 'sleep 1' & dead=$!; wait $dead
	printf '{"pid": %s, "kind": "hermes-gateway", "argv": ["gateway", "run"]}' "$dead" > "$D/gateway.pid"
	echo $$ > /tmp/cg/cgroup.procs
else
	printf '{"pid": %s, "kind": "hermes-gateway", "argv": ["gateway", "run"]}' "$$" > "$D/gateway.pid"
	: > /tmp/cg/cgroup.procs
fi
while [ ! -e /tmp/svc.stop ]; do sleep 1; done
sleep 1; rm -f "$D/gateway.pid" "$D/gateway.sock"
sleep 3; n=$(cut -d" " -f2 "$D/state.db.closed" 2>/dev/null); echo "closed $(( ${n:-0} + 1 ))" > "$D/state.db.closed"
rm -f "$D/state.db-wal"; : > /tmp/cg/cgroup.procs; echo "gone $(date +%s)" >> /tmp/svc.log
GW
cat > /stub/svc <<'SVC'
#!/bin/sh
D=$(uci -q get hermes.main.data_dir); [ -n "$D" ] || D=/srv/hermes
case "$1" in
	stop)  echo "stop $(date +%s)" >> /tmp/svc.log; touch /tmp/svc.stop ;;
	start) rm -f /tmp/svc.stop; echo "start $(date +%s) data_on=$(awk -v d="$D" '$2 == d { print $1 }' /proc/mounts)" >> /tmp/svc.log
	       sh /stub/gw "$D" "$(cat /tmp/stub.mode 2>/dev/null || echo pid)" </dev/null >/dev/null 2>&1 &
	       sleep 2 ;;
esac
SVC
chmod 0755 /stub/svc
export HERMES_USB_SERVICE=/stub/svc HERMES_USB_CGROUP=/tmp/cg HERMES_USB_ANY_DEVICE=1

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

D=/srv/hermes
sums() { ( cd $1 && find . -type f ! -name gateway.pid ! -name state.db-wal ! -name state.db.closed -exec md5sum {} + | sort -k 2 ); }
fstype() { block info $1 | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p'; }
uuid() { block info $1 | sed -n 's/.*UUID="\([^"]*\)".*/\1/p'; }
owner() { ls -ld $1 | awk '{print $3}'; }
reset() {
	touch /tmp/svc.stop; sleep 1; kill $(pgrep -f /stub/gw) 2>/dev/null; rm -f /tmp/svc.stop
	umount $D 2>/dev/null; umount $D 2>/dev/null; umount /mnt/busy 2>/dev/null; rm -f /srv/link; detach
	for s in hermes_data byhand; do uci -q delete fstab.$s; done; uci commit fstab 2>/dev/null
	uci -q delete hermes.main.data_uuid; uci -q delete hermes.main.data_dir; uci commit hermes
	rm -f /tmp/svc.log /tmp/stub.mode; : > /tmp/cg/cgroup.procs
}
seed() {  # a data directory like the agent's, with the stand-in gateway running on it
	rm -rf $D; mkdir -p $D/sessions $D/logs; chmod 0700 $D; rm -f $D/state.db.closed
	head -c 300000 /dev/urandom > $D/state.db; echo '{"a":1}' > $D/config.yaml
	for i in 1 2 3 4 5; do head -c 20000 /dev/urandom > $D/sessions/s$i.json; done
	echo log > $D/logs/agent.log
	sums $D > /tmp/seed.sums
	/stub/svc start; rm -f /tmp/svc.log
}
untouched() { sums $D | cmp -s - /tmp/seed.sums; }
SELECTED=" ${ONLY:-} "
run() { if [ -n "${ONLY:-}" ]; then case "$SELECTED" in *" $1 "*) ;; *) return 0 ;; esac; fi; CUR=$1; ( set -u; "$1" ) && echo "PASS $1" || { echo "FAIL $1"; FAILED=1; }; }
fail() { echo "  $CUR: $*"; exit 1; }
FAILED=0

check_missing_tools_named_and_nothing_changed() {
	reset; seed
	l=$(stick 128 none)
	out=$(hermes-usb move $l 2>&1); rc=$?
	[ $rc = 2 ] || fail "exit $rc, wanted 2: $out"
	echo "$out" | grep -q 'apk add kmod-usb-storage block-mount kmod-fs-ext4' || fail "the apk add line is missing: $out"
	[ ! -f /etc/config/fstab ] || ! grep -q hermes_data /etc/config/fstab || fail "fstab was changed"
	[ -z "$(uci -q get hermes.main.data_uuid)" ] || fail "data_uuid was set"
	untouched || fail "the data changed"
}
tools() { apk add kmod-usb-storage block-mount kmod-fs-ext4 e2fsprogs >/dev/null 2>&1 || { echo "FAIL setup: the USB tools would not install"; exit 1; }; }

check_status_names_where_data_lives() {
	reset; seed
	out=$(hermes-usb status 2>&1)
	echo "$out" | grep -q "$D is on the router's own storage, [0-9][0-9]* KiB used" || fail "status said: $out"
}

check_move_copies_and_restarts_on_the_stick() {
	reset; seed   # pid mode: only the gateway's own process makes the last write
	l=$(stick 128 ext4); u=$(uuid $l)
	out=$(hermes-usb move $l 2>&1) || fail "move failed: $out"
	[ "$(awk -v d=$D '$2 == d { print $1 }' /proc/mounts)" = "$l" ] || fail "$D is not on $l"
	untouched || fail "the data on the stick differs"
	[ "$(cat $D/state.db.closed 2>/dev/null)" = "closed 1" ] || fail "the copy was made before the gateway's last write (the stick holds '$(cat $D/state.db.closed 2>/dev/null)')"
	grep -q "^start .*data_on=$l" /tmp/svc.log || fail "the agent was not started again on the stick"
	[ "$(uci -q get fstab.hermes_data.uuid)" = "$u" ] && [ "$(uci -q get fstab.hermes_data.target)" = "$D" ] || fail "fstab does not mount $u on $D"
	[ "$(uci -q get hermes.main.data_uuid)" = "$u" ] || fail "hermes.main.data_uuid is not $u"
	touch /tmp/svc.stop; sleep 6; umount $D
	[ -z "$(ls -A $D)" ] || fail "the copy inside was left: $(ls -A $D | tr '\n' ' ')"
	block mount >/dev/null 2>&1
	[ "$(awk -v d=$D '$2 == d { print $1 }' /proc/mounts)" = "$l" ] || fail "block mount did not put the stick back on $D from the fstab"
}

check_move_refuses_a_device_in_use() {
	reset; seed
	l=$(stick 128 ext4); mkdir -p /mnt/busy && mount $l /mnt/busy
	out=$(hermes-usb move $l 2>&1) && fail "move went ahead on a mounted partition: $out"
	echo "$out" | grep -q "is mounted on /mnt/busy" || fail "the reason was not named: $out"
	umount /mnt/busy
	out=$(HERMES_USB_ANY_DEVICE= hermes-usb move $l 2>&1) && fail "move went ahead on a device that is not on USB: $out"
	echo "$out" | grep -q "is not on USB" || fail "a device not on USB was not refused as such: $out"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	untouched || fail "the data changed"
}

check_move_refuses_a_data_dir_set_up_by_hand() {
	reset; seed
	l=$(stick 128 ext4); other=$(stick 128 ext4)
	# a stick mounted on the data directory by hand, as the README's earlier recipe did
	touch /tmp/svc.stop; sleep 6; rm -f /tmp/svc.stop
	mount $other $D; echo byhand > $D/marker
	out=$(hermes-usb move $l 2>&1) && fail "move went ahead over a mount point: $out"
	echo "$out" | grep -q "already has $other mounted" || fail "the mount point was not named: $out"
	[ -f $D/marker ] || fail "the stick mounted by hand was touched"
	umount $D
	# named in the fstab
	uci set fstab.byhand=mount; uci set fstab.byhand.target=$D; uci set fstab.byhand.uuid=$(uuid $other); uci commit fstab
	out=$(hermes-usb move $l 2>&1) && fail "move went ahead with an fstab section on $D: $out"
	echo "$out" | grep -q "section 'byhand'" || fail "the fstab section was not named: $out"
	uci -q delete fstab.byhand; uci commit fstab
	# a symbolic link
	ln -s $D /srv/link; uci set hermes.main.data_dir=/srv/link; uci commit hermes
	out=$(hermes-usb move $l 2>&1) && fail "move went ahead through a symbolic link: $out"
	echo "$out" | grep -q "symbolic link" || fail "the link was not named: $out"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	[ -z "$(uci -q get hermes.main.data_uuid)" ] || fail "data_uuid was set"
	untouched || fail "the data changed"
}

check_copy_that_differs_switches_nothing() {
	reset; seed
	l=$(stick 128 ext4)
	# a cp that copies, then spoils one byte of one file on the destination
	mkdir -p /tmp/badcp; cat > /tmp/badcp/cp <<'CP'
#!/bin/sh
/bin/cp "$@" || exit $?
for last; do :; done
f=$(find "$last" -name s3.json | head -n 1); [ -n "$f" ] && printf X | dd of="$f" bs=1 seek=100 conv=notrunc 2>/dev/null
exit 0
CP
	chmod 0755 /tmp/badcp/cp
	out=$(PATH=/tmp/badcp:$PATH hermes-usb move $l 2>&1) && fail "move switched to a copy that differs: $out"
	echo "$out" | grep -q "does not match" || fail "the mismatch was not named: $out"
	[ -z "$(awk -v d=$D '$2 == d { print $1 }' /proc/mounts)" ] || fail "$D was switched to the stick"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	[ -z "$(uci -q get hermes.main.data_uuid)" ] || fail "data_uuid was set"
	untouched || fail "the data inside changed"
	grep -q '^start' /tmp/svc.log || fail "the agent was not started again where it was"
}

check_move_refuses_a_stick_without_room() {
	reset; seed
	head -c 9000000 /dev/urandom > $D/big.bin; sums $D > /tmp/seed.sums
	l=$(stick 16 ext4)
	out=$(HERMES_USB_MARGIN_KB=4096 hermes-usb move $l 2>&1) && fail "move went ahead: $out"
	echo "$out" | grep -q "needs" || fail "the size was not named: $out"
	small=$(stick 12 ext2)
	out=$(HERMES_USB_MARGIN_KB=4096 hermes-usb move $small --format 2>&1) && fail "--format went ahead on a stick too small: $out"
	[ "$(fstype $small)" = ext2 ] || fail "--format erased a stick that could not hold the data"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	[ -e /tmp/svc.log ] && grep -q '^stop' /tmp/svc.log && fail "the agent was stopped for a move that could not happen"
	untouched || fail "the data changed"
}

check_format_only_when_asked_and_without_lazy_init() {
	reset; seed
	l=$(stick 128 ext2)
	out=$(hermes-usb move $l 2>&1) && fail "an ext2 stick was used without --format: $out"
	echo "$out" | grep -q -- "--format would erase it" || fail "the refusal does not name --format: $out"
	[ "$(fstype $l)" = ext2 ] || fail "the stick was changed without --format"
	out=$(hermes-usb move $l --format 2>&1) || fail "--format failed: $out"
	[ "$(fstype $l)" = ext4 ] || fail "not ext4 after --format"
	groups=$(dumpe2fs $l 2>/dev/null | grep -c '^Group [0-9]')
	zeroed=$(dumpe2fs $l 2>/dev/null | grep '^Group [0-9]' | grep -c 'ITABLE_ZEROED')
	[ "$groups" -gt 0 ] || fail "measured nothing: dumpe2fs listed no block groups"
	[ "$groups" = "$zeroed" ] || fail "$zeroed of $groups inode tables written at format time: the filesystem would go on writing by itself"
}

init_start() {
	mkdir -p /etc/hermes-agent && printf '%s' sk-test-NotReal > /etc/hermes-agent/provider.key && chmod 600 /etc/hermes-agent/provider.key
	uci set hermes.main.enabled=1; uci set hermes.main.base_url=http://127.0.0.1:9/v1; uci set hermes.main.model=m; uci commit hermes
	/etc/init.d/hermes-agent start 2>&1
}
check_missing_stick_stops_the_start() {
	reset; touch /tmp/svc.stop; rm -rf $D; mkdir -p $D; chmod 0700 $D
	right=$(stick 128 ext4); wrong=$(stick 128 ext4)
	uci set hermes.main.data_uuid=$(uuid $right); uci commit hermes
	out=$(init_start)
	echo "$out" | grep -q "that stick is not" || fail "the start without the stick did not say so: $out"
	[ -z "$(ls -A $D)" ] || fail "something was written inside: $(ls -A $D | tr '\n' ' ')"
	pgrep -f 'hermes_cli/main.py gateway' >/dev/null && fail "a gateway runs"
	mount $wrong $D
	out=$(init_start)
	echo "$out" | grep -q "that stick is not" || fail "a different stick was taken for Hermes's: $out"
	umount $D; mount $right $D
	out=$(init_start)
	echo "$out" | grep -q "Not starting" && fail "the start refused with the right stick mounted: $out"
	[ "$(owner $D)" = hermes ] || fail "the start did not go on to hand $D to hermes: $out"
	uci -q delete hermes.main.data_uuid; uci set hermes.main.enabled=0; uci commit hermes
}

check_back_returns_the_data_inside() {
	reset; echo cgroup > /tmp/stub.mode; seed   # cgroup mode: the last write is made by a process only the group shows
	l=$(stick 128 ext4); stranger=$(stick 128 ext4)
	out=$(hermes-usb move $l 2>&1) || fail "the move before it failed: $out"
	[ "$(cat $D/state.db.closed 2>/dev/null)" = "closed 1" ] || fail "the move copied before the group's last write (the stick holds '$(cat $D/state.db.closed 2>/dev/null)')"
	# back refuses a stick that is not the one the data belongs on
	touch /tmp/svc.stop; sleep 6; umount $D; mount $stranger $D
	out=$(hermes-usb back 2>&1) && fail "back went ahead from a stick that is not Hermes's: $out"
	echo "$out" | grep -q "not the stick with UUID" || fail "the wrong stick was not named: $out"
	umount $D; mount $l $D; /stub/svc start; rm -f /tmp/svc.log
	out=$(hermes-usb back 2>&1) || fail "back failed: $out"
	[ -z "$(awk -v d=$D '$2 == d { print $1 }' /proc/mounts)" ] || fail "$D is still a mount point"
	untouched || fail "the data inside differs"
	# three shutdowns: the move's, the one above to swap in the stranger, and back's own
	[ "$(cat $D/state.db.closed 2>/dev/null)" = "closed 3" ] || fail "the copy was made before the gateway's last write (inside holds '$(cat $D/state.db.closed 2>/dev/null)')"
	grep -q hermes_data /etc/config/fstab && fail "the fstab entry is still there"
	[ -z "$(uci -q get hermes.main.data_uuid)" ] || fail "data_uuid is still set"
	grep -q '^start' /tmp/svc.log || fail "the agent was not started again"
}

run check_missing_tools_named_and_nothing_changed
tools
for c in $CHECKS; do [ "$c" = check_missing_tools_named_and_nothing_changed ] || run "$c"; done
reset
[ $FAILED = 0 ] && echo "gate-usb: all checks passed" || { echo "gate-usb: FAILED"; exit 1; }
CONTAINER
