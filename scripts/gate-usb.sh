#!/bin/sh
# gate-usb.sh -- hermes-usb, the stick check the init, the gateway wrapper and hermes-login share,
# and the block hotplug script, in OpenWrt's own rootfs with the built hermes-agent installed.
# A "stick" is an image file with a partition table on a loop device (partitions loopNp1, p2)
# inside a privileged, disposable container; mkfs, mount, block and the fstab are the real ones.
# Loop devices are not on USB, so the command's USB test is lifted by a file no package ships
# (/etc/hermes-usb.gate-any-device), removed for the one check that proves the test refuses.
#
# The service is stood in for (there is no procd here) by a gateway shaped like the real one's
# shutdown as a Flint 2 showed it on 2026-10-04: its pid file is a JSON record as upstream
# writes it, and told to stop it removes that file after a second and makes its last write
# three seconds later. In "pid" mode its own process makes that write; in "cgroup" mode the pid
# in the record is already gone and a second process, listed in a stand-in cgroup.procs, makes
# it. So the wait on the process and the wait on the group are each needed by one check.
# The init's start, the wrapper and hermes-login are the installed ones.
#
#   gate-usb.sh                 every check
#   ONLY="check_a" gate-usb.sh  just those (the teeth use this)
#   USB_BIN=/path gate-usb.sh   another hermes-usb over the installed one (teeth)
#   USB_INIT=/path gate-usb.sh  another init over the installed one (teeth)
#   USB_LIB=/path gate-usb.sh   another hermes-usb-check over the installed one (teeth)
#   USB_PLUG=/path gate-usb.sh  another hotplug script over the installed one (teeth)
#   USB_GW=/path gate-usb.sh    another gateway wrapper (teeth)
#   USB_LOGIN=/path gate-usb.sh another hermes-login (teeth)
#   USB_LAUNCHER=/path          another /usr/bin/hermes launcher (teeth)
#   gate-usb.sh --selftest      the check names, for gate-scenarios-bound.sh
set -u
CHECKS='check_missing_tools_named_and_nothing_changed check_status_names_where_data_lives check_move_copies_and_restarts_on_the_stick check_move_refuses_a_device_in_use check_move_refuses_a_data_dir_set_up_by_hand check_copy_that_differs_switches_nothing check_move_refuses_a_stick_without_room check_format_only_when_asked_and_without_lazy_init check_missing_stick_stops_the_start check_stick_coming_and_going check_back_returns_the_data_inside check_failed_mount_puts_everything_back check_failed_back_puts_the_stick_back check_interrupted_or_running_move_starts_nothing check_lost_stick_forgotten check_stick_record_proven_on_flash check_move_refuses_while_another_process_uses_the_data'
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
[ -n "${USB_BIN:-}" ] && EXTRA="$EXTRA -v $USB_BIN:/override/usr/sbin/hermes-usb:ro"
[ -n "${USB_INIT:-}" ] && EXTRA="$EXTRA -v $USB_INIT:/override/etc/init.d/hermes-agent:ro"
[ -n "${USB_LIB:-}" ] && EXTRA="$EXTRA -v $USB_LIB:/override/usr/lib/hermes-agent/hermes-usb-check:ro"
[ -n "${USB_PLUG:-}" ] && EXTRA="$EXTRA -v $USB_PLUG:/override/etc/hotplug.d/block/90-hermes-usb:ro"
[ -n "${USB_GW:-}" ] && EXTRA="$EXTRA -v $USB_GW:/override/usr/sbin/hermes-gateway:ro"
[ -n "${USB_LOGIN:-}" ] && EXTRA="$EXTRA -v $USB_LOGIN:/override/usr/sbin/hermes-login:ro"
[ -n "${USB_LAUNCHER:-}" ] && EXTRA="$EXTRA -v $USB_LAUNCHER:/override/usr/bin/hermes:ro"
echo "PASS: artefacts $(basename "$APK"), $(basename "$MCP")"

# shellcheck disable=SC2086
docker run --rm -i --platform "$PLATFORM" --privileged -e ONLY="${ONLY:-}" -e CHECKS="$CHECKS" \
	-v "$APK:/pkg.apk:ro" -v "$MCP:/mcp.apk:ro" $EXTRA "$IMAGE" /bin/sh -s <<'CONTAINER'
set -u
mkdir -p /var/lock /var/run /var/state /stub /tmp/cg
apk add --allow-untrusted /pkg.apk /mcp.apk >/tmp/install.log 2>&1 || { tail -5 /tmp/install.log; echo "FAIL setup: the package would not install"; exit 1; }
if [ -d /override ]; then (cd /override && find . -type f) | while read -r f; do mkdir -p "$(dirname "/${f#./}")"; cp "/override/$f" "/${f#./}"; done; fi
chmod 0755 /usr/sbin/hermes-usb /etc/init.d/hermes-agent /usr/sbin/hermes-gateway /usr/sbin/hermes-login /usr/bin/hermes 2>/dev/null
for f in /usr/sbin/hermes-usb /usr/lib/hermes-agent/hermes-usb-check /etc/hotplug.d/block/90-hermes-usb; do
	[ -f $f ] || { echo "FAIL: measured nothing: $f is not installed"; exit 1; }
done
apk add losetup dumpe2fs sfdisk >/dev/null 2>&1 || { echo "FAIL setup: losetup, dumpe2fs and sfdisk would not install"; exit 1; }
touch /etc/hermes-usb.gate-any-device

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
# The stand-in's command line holds "hermes" (as the real gateway's does), for the pid check.
ln -sf /stub/gw /stub/hermes-gw
cat > /stub/svc <<'SVC'
#!/bin/sh
D=$(uci -q get hermes.main.data_dir); [ -n "$D" ] || D=/srv/hermes
case "$1" in
	stop)    echo "stop $(date +%s)" >> /tmp/svc.log; touch /tmp/svc.stop ;;
	start)   rm -f /tmp/svc.stop; echo "start $(date +%s) data_on=$(df -P "$D" | awk 'NR == 2 { print $1 }')" >> /tmp/svc.log
	         sh /stub/hermes-gw "$D" "$(cat /tmp/stub.mode 2>/dev/null || echo pid)" </dev/null >/dev/null 2>&1 &
	         sleep 2 ;;
	enabled) [ -e /tmp/stub.enabled ] ;;
	running) pgrep -f /stub/hermes-gw >/dev/null ;;
esac
SVC
chmod 0755 /stub/svc
export HERMES_USB_SERVICE=/stub/svc HERMES_USB_CGROUP=/tmp/cg

# Loop devices are the kernel's, shared with whatever else the Docker host runs, so only the
# ones this gate attached are ever detached, and spare device nodes are made up front.
i=0; while [ $i -lt 64 ]; do [ -e /dev/loop$i ] || mknod -m 0600 /dev/loop$i b 7 $i; i=$((i + 1)); done
: > /tmp/ours
# disk $1 MiB, $2 partitions ("1" or "2"): prints the loop device; partition nodes are made
disk() {
	f=/tmp/stick.$$.$RANDOM.img; dd if=/dev/zero of=$f bs=1M count=$1 2>/dev/null
	if [ "$2" = 2 ]; then printf ',%sM,83\n,,83\n' $(( $1 / 2 )) | sfdisk -q $f >/dev/null 2>&1; else printf ',,83\n' | sfdisk -q $f >/dev/null 2>&1; fi
	l=$(losetup -f --show -P $f); echo "$l $f" >> /tmp/ours
	for p in /sys/class/block/${l#/dev/}p*; do
		[ -e "$p/dev" ] || continue; n=/dev/$(basename $p); [ -e $n ] || mknod -m 0600 $n b $(cut -d: -f1 $p/dev) $(cut -d: -f2 $p/dev)
	done
	chmod 0600 $l ${l}p* 2>/dev/null   # as a router's block devices are: root's alone
	echo $l
}
stick() {  # $1 MiB, $2 mkfs type or "none": prints the first partition of a one-partition disk
	l=$(disk $1 1); p=${l}p1
	case "$2" in ext4) mkfs.ext4 -q -F $p ;; ext2) mke2fs -q -F -t ext2 $p ;; none) ;; esac
	echo $p
}
detach() { while read -r l f; do umount ${l}p1 2>/dev/null; umount ${l}p2 2>/dev/null; losetup -d $l 2>/dev/null; rm -f $f; done < /tmp/ours; : > /tmp/ours; }

D=/srv/hermes
sums() { ( cd $1 && find . -type f ! -name gateway.pid ! -name state.db-wal ! -name state.db.closed -exec md5sum {} + | sort -k 2 ); }
fstype() { block info $1 | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p'; }
uuid() { block info $1 | sed -n 's/.*UUID="\([^"]*\)".*/\1/p'; }
owner() { ls -ld $1 | awk '{print $3}'; }
on() { df -P $1 | awk 'NR == 2 { print $1 }'; }
hermes_src() { awk -v d="$1" '{ for (i = 7; i <= NF; i++) if ($i == "-") { src = $(i + 2); break } if ($5 == d) last = src } END { print last }' /proc/self/mountinfo; }
reset() {
	touch /tmp/svc.stop; sleep 1; kill $(pgrep -f /stub/hermes-gw) 2>/dev/null; rm -f /tmp/svc.stop
	umount $D 2>/dev/null; umount $D 2>/dev/null; umount /mnt/busy 2>/dev/null; umount /srv/other 2>/dev/null
	umount /srv 2>/dev/null; rm -rf /srv/link /srv/real /srv/hermes.hermes-usb-inside /srv/hermes.underneath.* /srv/.hermes-usb-back /var/lock/hermes-usb.lock; detach
	for s in hermes_data byhand; do uci -q delete fstab.$s; done; uci commit fstab 2>/dev/null
	uci -q delete hermes.main.data_dir; uci set hermes.main.enabled=0; uci commit hermes
	rm -f /tmp/svc.log /tmp/stub.mode /tmp/stub.enabled; : > /tmp/cg/cgroup.procs; rmdir /var/lock/hermes-usb.lock 2>/dev/null
	touch /etc/hermes-usb.gate-any-device
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
key() { mkdir -p /etc/hermes-agent && printf '%s' sk-test-NotReal > /etc/hermes-agent/provider.key && chmod 600 /etc/hermes-agent/provider.key; }
init_start() {
	key; uci set hermes.main.enabled=1; uci set hermes.main.base_url=http://127.0.0.1:9/v1; uci set hermes.main.model=m; uci commit hermes
	/etc/init.d/hermes-agent start 2>&1
}
stick_of_record() { uci set fstab.hermes_data=mount; uci set fstab.hermes_data.uuid=$1; uci set fstab.hermes_data.target=$D; uci set fstab.hermes_data.fstype=ext4; uci set fstab.hermes_data.options=rw,noatime; uci set fstab.hermes_data.enabled=1; uci commit fstab; }
# a hermes-usb that is running (its command line names it), holding the lock: prints its pid
running_move() {
	mkdir -p /tmp/fake; printf '#!/bin/sh\nsleep 120\n' > /tmp/fake/hermes-usb; sh /tmp/fake/hermes-usb </dev/null >/dev/null 2>&1 &
	mkdir -p /var/lock/hermes-usb.lock; echo $! > /var/lock/hermes-usb.lock/pid; echo $!
}
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
	p=$(stick 128 ext4); u=$(uuid $p)
	out=$(hermes-usb move $p 2>&1) || fail "move failed: $out"
	[ "$(on $D)" = "$p" ] || fail "$D is not on $p"
	untouched || fail "the data on the stick differs"
	[ "$(cat $D/state.db.closed 2>/dev/null)" = "closed 1" ] || fail "the copy was made before the gateway's last write (the stick holds '$(cat $D/state.db.closed 2>/dev/null)')"
	grep -q "^start .*data_on=$p" /tmp/svc.log || fail "the agent was not started again on the stick"
	[ "$(uci -q get fstab.hermes_data.uuid)" = "$u" ] && [ "$(uci -q get fstab.hermes_data.target)" = "$D" ] || fail "fstab does not mount $u on $D"
	[ ! -e /srv/hermes.hermes-usb-inside ] || fail "the copy set aside inside was left"
	touch /tmp/svc.stop; sleep 6; umount $D
	[ -z "$(ls -A $D)" ] || fail "something was left inside under the mount point: $(ls -A $D | tr '\n' ' ')"
	block mount >/dev/null 2>&1
	[ "$(on $D)" = "$p" ] || fail "block mount did not put the stick back on $D from the fstab"
	out=$(init_start)
	echo "$out" | grep -q "Not starting" && fail "the init refused the stick hermes-usb set up: $out"
	[ "$(owner $D)" = hermes ] || fail "the init did not go on to give $D to hermes: $out"
	# the gateway runs the hermes launcher as the user hermes, who cannot read a device's UUID
	# (seen on a Brume 2 on 2026-10-04: the gateway refused its own stick); it must go on
	out=$(HERMES_HOME=$D /usr/bin/python3 -I -B /usr/libexec/hermes-drop hermes /usr/bin/hermes --version 2>&1)
	echo "$out" | grep -q "Hermes Agent" || fail "the launcher, run as hermes the way the gateway runs it, refused the stick: $out"
	# and run from a root shell, it asks and takes the stick of record
	out=$(HERMES_HOME=$D hermes --version 2>&1)
	echo "$out" | grep -q "Hermes Agent" || fail "the launcher, run as root, refused the stick of record: $out"
}

check_move_refuses_a_device_in_use() {
	reset; seed
	l=$(disk 256 2); mkfs.ext4 -q -F ${l}p1; mkfs.ext4 -q -F ${l}p2
	mkdir -p /mnt/busy && mount ${l}p2 /mnt/busy
	out=$(hermes-usb move ${l}p1 2>&1) && fail "move went ahead on a disk with a partition mounted: $out"
	echo "$out" | grep -q "${l}p2 is mounted on /mnt/busy" || fail "the mounted partition was not named: $out"
	umount /mnt/busy
	out=$(hermes-usb move $l --format 2>&1) && fail "move went ahead on a whole disk: $out"
	echo "$out" | grep -q "is a whole disk" || fail "a whole disk was not refused as such: $out"
	rm -f /etc/hermes-usb.gate-any-device
	out=$(hermes-usb move ${l}p1 2>&1) && fail "move went ahead on a device that is not on USB: $out"
	echo "$out" | grep -q "is not on USB" || fail "a device not on USB was not refused as such: $out"
	touch /etc/hermes-usb.gate-any-device
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	untouched || fail "the data changed"
}

check_move_refuses_a_data_dir_set_up_by_hand() {
	reset; seed
	p=$(stick 128 ext4); other=$(stick 128 ext4)
	touch /tmp/svc.stop; sleep 6; rm -f /tmp/svc.stop
	# a stick mounted on the data directory by hand, as the README's earlier recipe did
	mount $other $D; echo byhand > $D/marker
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead over a mount point: $out"
	echo "$out" | grep -q "not on the router's own root filesystem" || fail "the mount point was not named: $out"
	[ -f $D/marker ] || fail "the stick mounted by hand was touched"
	umount $D
	# named in the fstab
	uci set fstab.byhand=mount; uci set fstab.byhand.target=$D; uci set fstab.byhand.uuid=$(uuid $other); uci commit fstab
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead with an fstab section on $D: $out"
	echo "$out" | grep -q "section 'byhand'" || fail "the fstab section was not named: $out"
	uci -q delete fstab.byhand; uci commit fstab
	# a symbolic link, at the end and in a parent
	ln -s $D /srv/link; uci set hermes.main.data_dir=/srv/link; uci commit hermes
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead through a symbolic link: $out"
	echo "$out" | grep -q "symbolic link" || fail "the link was not named: $out"
	mkdir -p /srv/real/hermes; rm -f /srv/link; ln -s /srv/real /srv/link; uci set hermes.main.data_dir=/srv/link/hermes; uci commit hermes
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead through a symbolic link in a parent: $out"
	echo "$out" | grep -q "symbolic link" || fail "the parent link was not named: $out"
	# a data directory on another filesystem
	mkdir -p /srv/other && mount $other /srv/other && mkdir -p /srv/other/hermes
	uci set hermes.main.data_dir=/srv/other/hermes; uci commit hermes
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead from another filesystem: $out"
	echo "$out" | grep -q "not on the router's own root filesystem" || fail "the other filesystem was not named: $out"
	umount /srv/other
	# a system tree
	uci set hermes.main.data_dir=/etc/hermes; uci commit hermes
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead on a system tree: $out"
	echo "$out" | grep -q "system tree" || fail "the system tree was not named: $out"
	uci -q delete hermes.main.data_dir; uci commit hermes
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	untouched || fail "the data changed"
}

check_copy_that_differs_switches_nothing() {
	reset; seed
	p=$(stick 128 ext4)
	# a cp that copies, then spoils one byte of one file on the destination
	mkdir -p /tmp/badcp; cat > /tmp/badcp/cp <<'CP'
#!/bin/sh
/bin/cp "$@" || exit $?
for last; do :; done
f=$(find "$last" -name s3.json | head -n 1); [ -n "$f" ] && printf X | dd of="$f" bs=1 seek=100 conv=notrunc 2>/dev/null
exit 0
CP
	chmod 0755 /tmp/badcp/cp
	out=$(PATH=/tmp/badcp:$PATH hermes-usb move $p 2>&1) && fail "move switched to a copy that differs: $out"
	echo "$out" | grep -q "does not match" || fail "the mismatch was not named: $out"
	[ "$(on $D)" != "$p" ] || fail "$D was switched to the stick"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	untouched || fail "the data inside changed"
	grep -q '^start' /tmp/svc.log || fail "the agent was not started again where it was"
}

check_move_refuses_a_stick_without_room() {
	reset; seed
	head -c 9000000 /dev/urandom > $D/big.bin; sums $D > /tmp/seed.sums
	p=$(stick 16 ext4)
	out=$(HERMES_USB_MARGIN_KB=4096 hermes-usb move $p 2>&1) && fail "move went ahead: $out"
	echo "$out" | grep -q "needs" || fail "the size was not named: $out"
	small=$(stick 14 ext2)
	out=$(HERMES_USB_MARGIN_KB=4096 hermes-usb move $small --format 2>&1) && fail "--format went ahead on a stick too small: $out"
	[ "$(fstype $small)" = ext2 ] || fail "--format erased a stick that could not hold the data"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	[ -e /tmp/svc.log ] && grep -q '^stop' /tmp/svc.log && fail "the agent was stopped for a move that could not happen"
	untouched || fail "the data changed"
}

check_format_only_when_asked_and_without_lazy_init() {
	reset; seed
	p=$(stick 128 ext2)
	out=$(hermes-usb move $p 2>&1) && fail "an ext2 stick was used without --format: $out"
	echo "$out" | grep -q -- "--format would erase it" || fail "the refusal does not name --format: $out"
	[ "$(fstype $p)" = ext2 ] || fail "the stick was changed without --format"
	# A partition of a loop device can zero inode tables at once whatever mkfs is told, which a
	# USB stick cannot, so what mkfs was asked for is recorded as well as what it made.
	real=$(command -v mkfs.ext4); mkdir -p /tmp/mkfsrec
	printf '#!/bin/sh\necho "$*" > /tmp/mkfs.args\nexec %s "$@"\n' "$real" > /tmp/mkfsrec/mkfs.ext4; chmod 0755 /tmp/mkfsrec/mkfs.ext4
	out=$(PATH=/tmp/mkfsrec:$PATH hermes-usb move $p --format 2>&1) || fail "--format failed: $out"
	[ "$(fstype $p)" = ext4 ] || fail "not ext4 after --format"
	args=$(cat /tmp/mkfs.args 2>/dev/null)
	[ -n "$args" ] || fail "measured nothing: mkfs.ext4 was not seen"
	case " $args " in *lazy_itable_init=0*) ;; *) fail "mkfs.ext4 was not told to write the inode tables at once: $args" ;; esac
	case " $args " in *lazy_journal_init=0*) ;; *) fail "mkfs.ext4 was not told to write the journal at once: $args" ;; esac
	case " $args " in *" -m 0 "*) ;; *) fail "mkfs.ext4 was not told to reserve no blocks: $args" ;; esac
	groups=$(dumpe2fs $p 2>/dev/null | grep -c '^Group [0-9]')
	zeroed=$(dumpe2fs $p 2>/dev/null | grep '^Group [0-9]' | grep -c 'ITABLE_ZEROED')
	[ "$groups" -gt 0 ] || fail "measured nothing: dumpe2fs listed no block groups"
	[ "$groups" = "$zeroed" ] || fail "$zeroed of $groups inode tables written at format time: the filesystem would go on writing by itself"
	[ "$(dumpe2fs -h $p 2>/dev/null | sed -n 's/^Reserved block count: *//p')" = 0 ] || fail "blocks are reserved for root on a stick the agent writes as hermes"
}

check_missing_stick_stops_the_start() {
	reset; touch /tmp/svc.stop; rm -rf $D; mkdir -p $D; chmod 0700 $D
	right=$(stick 128 ext4); wrong=$(stick 128 ext4)
	stick_of_record $(uuid $right)
	out=$(init_start)
	echo "$out" | grep -q "that stick is not mounted" || fail "the start without the stick did not say so: $out"
	out=$(HERMES_HOME=$D /usr/sbin/hermes-gateway /etc/hermes-agent/provider.key 2>&1) && fail "the gateway wrapper (what procd respawns) went ahead without the stick: $out"
	echo "$out" | grep -q "that stick is not mounted" || fail "the gateway wrapper did not say the stick is missing: $out"
	out=$(hermes-login chatgpt 2>&1) && fail "hermes-login went ahead without the stick: $out"
	echo "$out" | grep -q "that stick is not mounted" || fail "hermes-login did not say the stick is missing: $out"
	out=$(HERMES_HOME=$D hermes cron list 2>&1) && fail "the hermes launcher went ahead on $D without the stick: $out"
	echo "$out" | grep -q "that stick is not mounted" || fail "the hermes launcher did not say the stick is missing: $out"
	# the right stick on a parent of the data directory is not the stick on it
	mount $right /srv; mkdir -p $D 2>/dev/null
	out=$(init_start)
	echo "$out" | grep -q "that stick is not mounted" || fail "the stick on a parent of $D was taken for the stick on it: $out"
	umount /srv
	# a section disabled, or stripped of its UUID, is never read as "the data is inside"
	uci set fstab.hermes_data.enabled=0; uci commit fstab
	out=$(init_start)
	echo "$out" | grep -q "section is disabled" || fail "a disabled section was read as the data being inside: $out"
	uci set fstab.hermes_data.enabled=1; uci -q delete fstab.hermes_data.uuid; uci commit fstab
	out=$(init_start)
	echo "$out" | grep -q "names no UUID" || fail "a section without a UUID was read as the data being inside: $out"
	stick_of_record $(uuid $right)
	[ -z "$(ls -A $D)" ] || fail "something was written inside: $(ls -A $D | tr '\n' ' ')"
	mount $wrong $D
	out=$(init_start)
	echo "$out" | grep -q "not the USB stick with Hermes's data" || fail "a different stick was taken for Hermes's: $out"
	umount $D; mount $right $D
	out=$(init_start)
	echo "$out" | grep -q "Not starting" && fail "the start refused with the right stick mounted: $out"
	[ "$(owner $D)" = hermes ] || fail "the start did not go on to give $D to hermes: $out"
}

check_stick_coming_and_going() {
	reset; touch /tmp/svc.stop; rm -rf $D; mkdir -p $D; chmod 0700 $D
	p=$(stick 128 ext4); stick_of_record $(uuid $p); touch /tmp/stub.enabled; rm -f /tmp/svc.stop
	# the stick appears: block's own hotplug has mounted it, then ours runs
	mount $p $D
	( ACTION=add DEVNAME=${p#/dev/}; . /etc/hotplug.d/block/90-hermes-usb )
	grep -q "^start .*data_on=$p" /tmp/svc.log || fail "the stick was mounted and Hermes was not started: $(cat /tmp/svc.log 2>/dev/null)"
	# a disabled service is not started by a stick
	touch /tmp/svc.stop; sleep 6; rm -f /tmp/svc.log /tmp/stub.enabled /tmp/svc.stop
	( ACTION=add DEVNAME=${p#/dev/}; . /etc/hotplug.d/block/90-hermes-usb )
	grep -q '^start' /tmp/svc.log 2>/dev/null && fail "a disabled service was started by the stick"
	# another device arriving while Hermes is stopped starts nothing; another one going while it
	# runs on its stick stops nothing
	touch /tmp/stub.enabled; rm -f /tmp/svc.log; stranger=$(stick 128 ext4)
	( ACTION=add DEVNAME=${stranger#/dev/}; . /etc/hotplug.d/block/90-hermes-usb )
	grep -q '^start' /tmp/svc.log 2>/dev/null && fail "another device arriving started Hermes"
	/stub/svc start; rm -f /tmp/svc.log
	( ACTION=remove DEVNAME=${stranger#/dev/}; . /etc/hotplug.d/block/90-hermes-usb )
	grep -q '^stop' /tmp/svc.log 2>/dev/null && fail "another device going stopped Hermes"
	touch /tmp/svc.stop; sleep 6; rm -f /tmp/svc.stop /tmp/svc.log
	# the stick goes: block's hotplug has unmounted it, then ours stops Hermes
	touch /tmp/stub.enabled; /stub/svc start; rm -f /tmp/svc.log
	umount $D
	( ACTION=remove DEVNAME=${p#/dev/}; . /etc/hotplug.d/block/90-hermes-usb )
	grep -q '^stop' /tmp/svc.log || fail "the stick went and Hermes was not stopped"
}

check_back_returns_the_data_inside() {
	reset; echo cgroup > /tmp/stub.mode; seed   # cgroup mode: the last write is made by a process only the group shows
	p=$(stick 128 ext4); stranger=$(stick 128 ext4)
	out=$(hermes-usb move $p 2>&1) || fail "the move before it failed: $out"
	[ "$(cat $D/state.db.closed 2>/dev/null)" = "closed 1" ] || fail "the move copied before the group's last write (the stick holds '$(cat $D/state.db.closed 2>/dev/null)')"
	# back refuses a stick that is not the one the data belongs on
	touch /tmp/svc.stop; sleep 6; umount $D; mount $stranger $D
	out=$(hermes-usb back 2>&1) && fail "back went ahead from a stick that is not Hermes's: $out"
	echo "$out" | grep -q "not the USB stick with Hermes's data" || fail "the wrong stick was not named: $out"
	# something left underneath the mount point is kept, not deleted
	umount $D; echo under > $D/left-underneath; mount $p $D; echo recovered > "$D/lost+found/#12"; /stub/svc start; rm -f /tmp/svc.log
	out=$(hermes-usb back 2>&1) || fail "back failed: $out"
	[ "$(on $D)" != "$p" ] || fail "$D is still on the stick"
	[ -f "$D/lost+found/#12" ] || fail "what fsck had recovered into the stick's lost+found did not come inside"
	rm -rf $D/lost+found
	untouched || fail "the data inside differs"
	# three shutdowns: the move's, the one above to swap in the stranger, and back's own
	[ "$(cat $D/state.db.closed 2>/dev/null)" = "closed 3" ] || fail "the copy was made before the gateway's last write (inside holds '$(cat $D/state.db.closed 2>/dev/null)')"
	grep -q hermes_data /etc/config/fstab && fail "the fstab entry is still there"
	ls /srv/hermes.underneath.*/left-underneath >/dev/null 2>&1 || fail "what was underneath the mount point was not kept"
	grep -q '^start' /tmp/svc.log || fail "the agent was not started again"
}

check_failed_mount_puts_everything_back() {
	reset; seed
	p=$(stick 128 ext4)
	mkdir -p /tmp/badmount; printf '#!/bin/sh\nfor last; do :; done\n[ "$last" = %s ] && exit 32\nexec /bin/mount "$@"\n' $D > /tmp/badmount/mount; chmod 0755 /tmp/badmount/mount
	out=$(PATH=/tmp/badmount:$PATH hermes-usb move $p 2>&1) && fail "move claimed success with the mount on $D failing: $out"
	echo "$out" | grep -q "the data is still in $D" || fail "the failed mount was not reported as nothing switched: $out"
	[ -z "$(hermes_src $D)" ] || fail "$D was left with something mounted on it"
	untouched || fail "the data inside is not as it was"
	[ ! -e $D.hermes-usb-inside ] || fail "the copy set aside was left beside $D"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "the fstab section was written"
	grep -q '^start' /tmp/svc.log || fail "the agent was not started again where it was"
}

check_failed_back_puts_the_stick_back() {
	reset; seed
	p=$(stick 128 ext4)
	hermes-usb move $p >/dev/null 2>&1 || fail "the move before it failed"
	sums $D > /tmp/stick.sums
	mkdir -p /tmp/badmv; printf '#!/bin/sh\ncase "$1" in */.hermes-usb-back) exit 1 ;; esac\nexec /bin/mv "$@"\n' > /tmp/badmv/mv; chmod 0755 /tmp/badmv/mv
	rm -f /tmp/svc.log
	out=$(PATH=/tmp/badmv:$PATH hermes-usb back 2>&1) && fail "back claimed success with its copy unable to move in: $out"
	echo "$out" | grep -q "nothing was switched" || fail "the failed back was not reported as nothing switched: $out"
	[ "$(on $D)" = "$p" ] || fail "the stick was not mounted on $D again"
	sums $D | cmp -s - /tmp/stick.sums || fail "the data on the stick changed"
	grep -q hermes_data /etc/config/fstab || fail "the fstab section was removed though nothing came back"
	[ ! -e /srv/.hermes-usb-back ] || fail "the half-made copy was left inside"
	grep -q '^start' /tmp/svc.log || fail "the agent was not started again on the stick"
}

check_interrupted_or_running_move_starts_nothing() {
	reset; touch /tmp/svc.stop; rm -rf $D; mkdir -p $D; chmod 0700 $D
	# a move in progress: its lock holds a live pid
	live=$(running_move)
	out=$(init_start)
	echo "$out" | grep -q "is moving Hermes's data right now" || fail "the init started while hermes-usb held its lock: $out"
	out=$(HERMES_HOME=$D /usr/sbin/hermes-gateway /etc/hermes-agent/provider.key 2>&1) && fail "the gateway wrapper started while hermes-usb held its lock"
	kill $live 2>/dev/null; wait $live 2>/dev/null
	# a lock whose pid now belongs to another program (pids are reused) does not block either
	sleep 120 & other=$!; echo $other > /var/lock/hermes-usb.lock/pid
	out=$(init_start)
	echo "$out" | grep -q "is moving Hermes's data" && fail "a lock holding another program's pid blocked the start: $out"
	kill $other 2>/dev/null; wait $other 2>/dev/null
	mkdir -p /var/lock/hermes-usb.lock; echo $live > /var/lock/hermes-usb.lock/pid
	# a lock left by a hermes-usb that is gone does not block
	out=$(init_start)
	echo "$out" | grep -q "is moving Hermes's data" && fail "a stale lock blocked the start: $out"
	rm -rf /var/lock/hermes-usb.lock
	# a copy an interrupted move set aside is named, and nothing starts
	mkdir -p $D.hermes-usb-inside; echo x > $D.hermes-usb-inside/state.db
	out=$(init_start)
	echo "$out" | grep -q "$D.hermes-usb-inside" || fail "the copy left by an interrupted move was not named: $out"
	p=$(stick 128 ext4)
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead beside a copy left by an interrupted move: $out"
	[ -f $D.hermes-usb-inside/state.db ] || fail "the copy left by an interrupted move was touched"
	rm -rf $D.hermes-usb-inside
	# and the copy an interrupted back was making
	mkdir -p /srv/.hermes-usb-back; echo x > /srv/.hermes-usb-back/state.db
	out=$(init_start)
	echo "$out" | grep -q "/srv/.hermes-usb-back" || fail "the copy left by an interrupted back was not named: $out"
	[ -f /srv/.hermes-usb-back/state.db ] || fail "the copy left by an interrupted back was touched"
}

check_lost_stick_forgotten() {
	reset; touch /tmp/svc.stop; rm -rf $D; mkdir -p $D; chmod 0700 $D
	p=$(stick 128 ext4); stick_of_record $(uuid $p)
	out=$(hermes-usb forget 2>&1) && fail "forget went ahead without --yes: $out"
	grep -q hermes_data /etc/config/fstab || fail "forget without --yes removed the record"
	mount $p $D
	out=$(hermes-usb forget --yes 2>&1) && fail "forget gave up a stick that is mounted: $out"
	umount $D
	out=$(hermes-usb forget --yes 2>&1) || fail "forget failed: $out"
	grep -q hermes_data /etc/config/fstab && fail "the record is still there"
	out=$(init_start)
	echo "$out" | grep -q "Not starting" && fail "Hermes did not start inside after the stick was given up: $out"
	return 0
}

check_stick_record_proven_on_flash() {
	reset; seed
	p=$(stick 128 ext4)
	# someone else's change waiting in /tmp/.uci is not committed along with the stick's record
	uci set fstab.pending=mount; uci set fstab.pending.target=/mnt/pending
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead with someone else's fstab changes uncommitted: $out"
	echo "$out" | grep -q "uci changes fstab" || fail "the uncommitted changes were not named: $out"
	grep -q pending /etc/config/fstab 2>/dev/null && fail "someone else's uncommitted change was committed"
	uci revert fstab
	untouched || fail "the data changed"
	# the storage /etc/config lives on is full: refused before the agent is stopped. On a full
	# filesystem `uci commit` returned 0 and left /etc/config/fstab empty (OpenWrt 25.12.4,
	# 2026-10-04), so this is checked first, and every commit is read back from the file.
	mkdir -p /tmp/fullcfg; mount -t tmpfs -o size=256k tmpfs /tmp/fullcfg; cp -a /etc/config/. /tmp/fullcfg/
	dd if=/dev/zero of=/tmp/fullcfg/fill bs=1k count=1024 2>/dev/null; mount --bind /tmp/fullcfg /etc/config
	rm -f /tmp/svc.log
	out=$(hermes-usb move $p 2>&1); rc=$?
	umount /etc/config; umount /tmp/fullcfg
	[ $rc != 0 ] || fail "move went ahead with the storage of /etc/config full: $out"
	echo "$out" | grep -q "KiB free where /etc/config" || fail "the full storage was not named: $out"
	[ -e /tmp/svc.log ] && grep -q '^stop' /tmp/svc.log && fail "the agent was stopped before the room for the record was checked"
	untouched || fail "the data changed"
	# an fstab change someone starts while the copy runs is not committed with the record either
	mkdir -p /tmp/latecp
	printf '#!/bin/sh\n/bin/cp "$@" || exit $?\nuci set fstab.late=mount; uci set fstab.late.target=/mnt/late\n' > /tmp/latecp/cp; chmod 0755 /tmp/latecp/cp
	rm -f /tmp/svc.log
	out=$(PATH=/tmp/latecp:$PATH hermes-usb move $p 2>&1) && fail "move went ahead with an fstab change started during the copy: $out"
	echo "$out" | grep -q "uci changes fstab" || fail "the change started during the copy was not named: $out"
	grep -q late /etc/config/fstab 2>/dev/null && fail "an fstab change started during the copy was committed with the record"
	[ "$(on $D)" != "$p" ] || fail "$D was switched to the stick"
	uci revert fstab; untouched || fail "the data changed"
	mkfs.ext4 -q -F $p
	# a commit that says it worked and leaves nothing on flash
	mkdir -p /tmp/nocommit
	printf '#!/bin/sh\ncase "$*" in *"commit fstab"*) exit 0 ;; esac\nexec /sbin/uci "$@"\n' > /tmp/nocommit/uci; chmod 0755 /tmp/nocommit/uci
	rm -f /tmp/svc.log
	out=$(PATH=/tmp/nocommit:$PATH hermes-usb move $p 2>&1) && fail "move claimed success with the stick's record not on flash: $out"
	echo "$out" | grep -q "the data is still in $D" || fail "the record not reaching flash was not reported as nothing switched: $out"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "measured nothing: the stand-in commit wrote the record"
	[ -z "$(uci -q changes fstab)" ] || fail "the record was left waiting in /tmp/.uci, where every reader takes it for flash: $(uci -q changes fstab | tr '\n' ' ')"
	[ -z "$(hermes_src $D)" ] || fail "$D was left with the stick mounted on it"
	untouched || fail "the data inside is not as it was"
	[ ! -e $D.hermes-usb-inside ] || fail "the copy set aside was left beside $D"
	grep -q '^start' /tmp/svc.log || fail "the agent was not started again where it was"
	# a commit cut off inside a quoted value after the record's target: uci and block-mount cannot
	# read that file, though the uuid and target lines are there
	mkdir -p /tmp/cutcommit
	printf '#!/bin/sh\ncase "$*" in *"commit fstab"*) /sbin/uci "$@"; awk '"'"'/option fstype/ { printf "%%s", substr($0, 1, index($0, "ex") + 1); exit } { print }'"'"' /etc/config/fstab > /tmp/cut; cat /tmp/cut > /etc/config/fstab; exit 0 ;; esac\nexec /sbin/uci "$@"\n' > /tmp/cutcommit/uci; chmod 0755 /tmp/cutcommit/uci
	r=$(stick 128 ext4); cp /etc/config/fstab /tmp/fstab.before; rm -f /tmp/svc.log
	out=$(PATH=/tmp/cutcommit:$PATH hermes-usb move $r 2>&1) && fail "move claimed success with /etc/config/fstab cut off inside a value: $out"
	echo "$out" | grep -q "the data is still in $D" || fail "the cut commit was not reported as nothing switched: $out"
	cmp -s /tmp/fstab.before /etc/config/fstab || fail "/etc/config/fstab was not put back as it was: '$(cat /etc/config/fstab)'"
	[ -z "$(hermes_src $D)" ] || fail "$D was left with the stick mounted on it"
	untouched || fail "the data inside is not as it was"
	[ ! -e $D.hermes-usb-inside ] || fail "the copy set aside was left beside $D"
	# back whose removal of the record does not reach flash: it says so, and every reader agrees
	# with flash that the data belongs on the stick
	q=$(stick 128 ext4)
	out=$(hermes-usb move $q 2>&1) || fail "the move before back failed: $out"
	rm -f /tmp/svc.log
	out=$(PATH=/tmp/nocommit:$PATH hermes-usb back 2>&1) && fail "back claimed success with the stick's record still on flash: $out"
	echo "$out" | grep -q "can be removed" && fail "back told the owner the stick can be removed while flash still expects it: $out"
	[ "$(uci -q get fstab.hermes_data.uuid)" = "$(uuid $q)" ] || fail "uci reads no longer match flash, which still names the stick: $(uci -q changes fstab | tr '\n' ' ')"
	out=$(init_start)
	echo "$out" | grep -q "Not starting" || fail "Hermes started inside while flash still says its data is on the stick: $out"
	# the record given up with forget, beside another section: a commit that empties the file is
	# caught and the file put back whole, and with no copy to put back nothing is written at all
	uci set fstab.other=mount; uci set fstab.other.target=/mnt/other; uci set fstab.other.enabled=0; uci commit fstab
	cp /etc/config/fstab /tmp/fstab.before
	mkdir -p /tmp/trunc
	printf '#!/bin/sh\ncase "$*" in *"commit fstab"*) /sbin/uci "$@"; : > /etc/config/fstab; exit 0 ;; esac\nexec /sbin/uci "$@"\n' > /tmp/trunc/uci; chmod 0755 /tmp/trunc/uci
	out=$(PATH=/tmp/trunc:$PATH hermes-usb forget --yes 2>&1) && fail "forget claimed success with /etc/config/fstab left empty: $out"
	cmp -s /tmp/fstab.before /etc/config/fstab || fail "/etc/config/fstab was not put back as it was: '$(cat /etc/config/fstab)'"
	mkdir -p /tmp/nobackup
	printf '#!/bin/sh\nfor last; do :; done\ncase "$last" in /tmp/hermes-usb.*.fstab) exit 1 ;; esac\nexec /bin/cp "$@"\n' > /tmp/nobackup/cp; chmod 0755 /tmp/nobackup/cp
	out=$(PATH=/tmp/nobackup:$PATH hermes-usb forget --yes 2>&1) && fail "forget went ahead with no copy of /etc/config/fstab to put back: $out"
	cmp -s /tmp/fstab.before /etc/config/fstab || fail "/etc/config/fstab changed though no copy of it could be made: '$(cat /etc/config/fstab)'"
	uci -q delete fstab.other; uci commit fstab
	# a file holding only the record, left by the commit as something uci cannot read at all
	printf "config mount 'hermes_data'\n\toption uuid '%s'\n\toption target '%s'\n" "$(uci -q get fstab.hermes_data.uuid)" $D > /etc/config/fstab
	cp /etc/config/fstab /tmp/fstab.before
	mkdir -p /tmp/garbage
	printf '#!/bin/sh\ncase "$*" in *"commit fstab"*) /sbin/uci "$@"; printf "%%s\\n" "'"'"'" > /etc/config/fstab; exit 0 ;; esac\nexec /sbin/uci "$@"\n' > /tmp/garbage/uci; chmod 0755 /tmp/garbage/uci
	out=$(PATH=/tmp/garbage:$PATH hermes-usb forget --yes 2>&1) && fail "forget claimed success with /etc/config/fstab left unreadable: $out"
	cmp -s /tmp/fstab.before /etc/config/fstab || fail "/etc/config/fstab was not put back as it was: '$(cat /etc/config/fstab)'"
	return 0
}

check_move_refuses_while_another_process_uses_the_data() {
	reset; seed
	p=$(stick 128 ext4)
	# a process with a file open in the data directory, as a root shell's hermes chat would have
	( exec 3>>$D/sessions/s1.json; exec sleep 60 ) & holder=$!; sleep 1
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead with another process holding a file in $D: $out"
	echo "$out" | grep -q "has files open in $D" || fail "the process using $D was not named: $out"
	kill $holder 2>/dev/null; wait $holder 2>/dev/null
	# one whose working directory is in it
	( cd $D/sessions && exec sleep 61 ) & holder=$!; sleep 1
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead with another process working in $D: $out"
	echo "$out" | grep -q "has files open in $D" || fail "the process working in $D was not named: $out"
	kill $holder 2>/dev/null; wait $holder 2>/dev/null
	# a file whose name has a space in it, and one deleted while it is held open
	echo x > "$D/sessions/a b.json"; ( exec 3>>"$D/sessions/a b.json"; exec sleep 62 ) & holder=$!; sleep 1
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead with another process holding a file with a space in its name: $out"
	echo "$out" | grep -q "has files open in $D" || fail "the process holding 'a b.json' was not named: $out"
	kill $holder 2>/dev/null; wait $holder 2>/dev/null; rm -f "$D/sessions/a b.json"
	echo y > $D/gone; ( exec 3<$D/gone; rm -f $D/gone; exec sleep 63 ) & holder=$!; sleep 1
	out=$(hermes-usb move $p 2>&1) && fail "move went ahead with another process holding a deleted file in $D: $out"
	echo "$out" | grep -q "has files open in $D" || fail "the process holding a deleted file was not named: $out"
	kill $holder 2>/dev/null; wait $holder 2>/dev/null
	[ "$(on $D)" != "$p" ] || fail "$D was switched to the stick"
	grep -q hermes_data /etc/config/fstab 2>/dev/null && fail "fstab was changed"
	untouched || fail "the data changed"
	grep -q '^start' /tmp/svc.log || fail "the agent was not started again where it was"
	# hermes run from a root shell while a move holds its lock is refused, inside as well, and
	# however the path is spelled
	touch /tmp/svc.stop; sleep 6
	live=$(running_move)
	for h in $D $D/ /srv//hermes; do
		out=$(HERMES_HOME=$h hermes --version 2>&1) && fail "hermes started on $h from a root shell while hermes-usb held its lock: $out"
		echo "$out" | grep -q "is moving Hermes's data right now" || fail "the lock was not named for $h: $out"
	done
	kill $live 2>/dev/null; wait $live 2>/dev/null; rm -rf /var/lock/hermes-usb.lock
	out=$(HERMES_HOME=$D hermes --version 2>&1)
	echo "$out" | grep -q "Hermes Agent" || fail "with no move running, hermes from a root shell refused the data inside: $out"
}

run check_missing_tools_named_and_nothing_changed
tools
for c in $CHECKS; do [ "$c" = check_missing_tools_named_and_nothing_changed ] || run "$c"; done
reset
[ $FAILED = 0 ] && echo "gate-usb: all checks passed" || { echo "gate-usb: FAILED"; exit 1; }
CONTAINER
