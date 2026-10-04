#!/bin/sh
# Build the hermes-agent package inside the OpenWrt release it targets, then package it.
#
# Two containers, each doing the one thing it is right for:
#
#   openwrt/rootfs:<arch>-<release>   assembles the tree. It has the exact CPython and
#                                     the exact musl the router has, so pip resolves the
#                                     same wheels the router would.
#   alpine:edge                       runs `apk mkpkg`. apk v3 is the only writer of the
#                                     package format, and OpenWrt's own rootfs ships
#                                     apk-tools without mkpkg, so the writer has to come
#                                     from somewhere. alpine:edge is 8 MB; the OpenWrt
#                                     SDK, the other way to get it, is 241 MB.
#
# OpenWrt publishes its OCI platform string as the package architecture, so the images
# need --platform linux/<apk-arch>. Plain linux/arm64 finds no manifest at all.
set -eu

ARCH=${1:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
# 25.12 only (2026-09-25). The 24.10 line, its opkg packages and its feed were dropped;
# the last build that could make them is in git history before that date.
case "$RELEASE" in
	25.*) ;;
	*) echo "$0: RELEASE=$RELEASE is not built any more; this package is for OpenWrt 25.12" >&2; exit 1 ;;
esac
# The upstream version, commit and exclusions come from one file; see package/upstream/.
. "$(cd "$(dirname "$0")/../upstream" && pwd)/upstream.env"
# r2: the init script learned to read the telegram section, refuse the four ways a
# Telegram setup cannot work, and hand the token over as an environment variable.
#
# r3: and then it learned to start at all. r1 and r2 both passed `--toolsets` to
# `hermes gateway run`, which does not accept it, so the service died at argument
# parsing on every router. r2 reached the published feed, so this is a new revision
# rather than a rebuild of that one: apk and opkg decide what to upgrade by version,
# and a router already holding a broken r2 would never be offered a fixed one.
#
# r4: the two defects the first hardware run found (#1): bash is a dependency, and the
# key is read by /usr/sbin/hermes-gateway at exec time instead of sitting in procd's
# environment, where `ubus call service list` printed it. Both landed on main on
# 2026-09-13 as r3 and the feed was never republished, so the feed kept serving the
# r3 built on 2026-09-08, without either fix. Found on 2026-09-15 on a fresh install
# from the feed: the key in the service table, the wrapper absent. Same lesson as r3:
# a fix that keeps the version string is a fix nobody is offered.
#
# r5: r4 declared bash on aarch64_generic and x86_64 but NOT on aarch64_cortex-a53,
# the one label every GL.iNet MediaTek box actually installs. The relabelled copy below
# was a second mkpkg call carrying its own copy of the depends string, and the r3 fix
# edited only the first. CI installs the generic and x86_64 packages and never the
# relabelled one, so nothing could notice. Measured on a cortex-a53 router on 2026-09-15: r4
# installed, `bash` absent. Now one string feeds both calls, and the relabelled package
# is diffed against the primary before it is accepted.
#
# r7: the init learned a profile option (assistant/admin) that governs
# agent.disabled_toolsets; set-toolsets.py, hermes-agent.init and hermes-gateway all
# changed. See CLAUDE.md's profiles invariant.
#
# r8: admin became the default profile; assistant tells the agent it has no shell;
# max_turns caps the model calls with tools in one turn at 20 (UCI); upstream adds one
# call without tools to sum up when a turn reaches it.
#
# r9: further providers from UCI `provider` sections, offered by /model per chat;
# the anthropic extra for upstream's native Anthropic provider; hermes-login chatgpt.
#
# r10: hermes-login chatgpt --logout, for the settings page's sign-out.
#
# 0.21.5-r1: upstream Hermes 0.21.5 (tag v2026.9.24), built from the pinned commit's
# archive rather than PyPI, which stops at 0.19.0; dependency versions from upstream's
# uv.lock; nemo-relay and pillow-heif left out; skills, locales and the MCP catalogue
# under /usr/share/hermes-agent. The revision restarts at 1 with the new version.
#
# 0.21.5-r2: the main model is written as a named `uci` entry in `providers`, not as
# upstream's bare `custom`, so a model picked with /model's buttons keeps the main key.
#
# 0.21.5-r3: the agent no longer runs as root unless its profile says so. A user and group
# hermes are created at install; the gateway and every tool it starts run as that user,
# dropped to by /usr/libexec/hermes-drop after the wrapper (still root) has applied the
# memory ceiling and read the key files; profile owner is the new default, and it reaches
# the router only through openwrt-mcp, which this package now depends on and wires up
# (client hermes-main, its policies, the second factor from hermes.security). root is the
# old admin, kept as an explicit, warned choice.
#
# 0.21.5-r4: the Hermes-side half of the unlock. A plugin, openwrt-unlock, ships in
# site-packages (so it is root's and the agent cannot rewrite it), is enabled in the owner
# profile by the same bridge that writes the rest of config.yaml, and takes /unlock and /lock
# in Telegram: it deletes the message, asks openwrt-mcp, answers only the outcome, and keeps
# the PIN or code from the model, the conversation and the logs. A scheduled job cannot
# change the router even while an unlock is open.
#
# 0.21.5-r5: what a QEMU OpenWrt with no /srv and a Brume 2 on Telegram showed on 2026-10-02.
# The init made a missing /srv closed to everyone but root (a boot's umask is 077), so the
# agent's user could not enter it and the start was refused as "cannot write"; parents are now
# made 0755 and the data directory 0700, an existing parent is left alone, and one the agent
# cannot enter is named. The plugin remembers the window the daemon said it opened and, through
# pre_llm_call, adds one line to the owner's next message while it is open, so an agent that
# asked for /unlock does not go on asking after it was given; the line goes again on /lock, a
# lockout or the end of the window, in the history the request replays too. The config file's
# enrolment commands are the two-step form the README gives.
#
# 0.21.5-r6: hermes-usb moves the data directory to a USB stick and back (status, move
# <partition> [--format], back), and the init will not start when the data belongs on a stick
# that is not mounted, rather than start empty on the router's own storage.
PKGREL=${PKGREL:-6}

# What the package needs from the OpenWrt feed. Declared once, used by every mkpkg call
# in this file: two copies of this list is how r4 shipped without bash on one arch.
# bash is not optional: Hermes runs its terminal tool through bash builtins
# (tools/environments/local.py), and on busybox ash every command fails with
# "builtin: not found" while the model reports the box as broken.
#
# openwrt-mcp is the router-side half of the owner profile: the agent reads and changes the
# router only through it. It is not in OpenWrt's feed. Ours is built from the companion
# branch with that repository's own mkapk.sh (scripts/build-openwrt-mcp.sh) and the feed
# carries it beside this package. It has no version floor yet, because the branch still
# says 0.5.0, the number the release without the second factor carries too; set one when
# the companion is tagged.
DEPENDS="python3 python3-pip ca-bundle bash ffmpeg ffprobe ripgrep openwrt-mcp"

SRC=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SRC/../.." && pwd)
# Keyed by release line as well as architecture. Both lines build an x86_64 tree and
# they are NOT interchangeable (Python 3.11 against 3.13), so a shared directory means
# the second build silently destroys the first and the feed then ships whichever ran
# last under both names.
LINE=${RELEASE%%.*}.$(echo "$RELEASE" | cut -d. -f2)
WORK="$ROOT/build/$LINE/$ARCH"

case "$ARCH" in
	x86_64) IMAGE="openwrt/rootfs:x86-64-$RELEASE" ;;
	*)      IMAGE="openwrt/rootfs:$ARCH-$RELEASE" ;;
esac

ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}
OUT="hermes-agent-$HERMES_VERSION-r$PKGREL.apk"

rm -rf "$WORK"
mkdir -p "$WORK"

# On the host: the rootfs has no curl, and the checksum is checked before any byte of
# the archive reaches the build.
ARCHIVE=$("$ROOT/package/upstream/fetch.sh")

echo "==> assembling the tree inside $IMAGE (hermes-agent $HERMES_VERSION, $HERMES_COMMIT)"
docker run --rm -i --platform "linux/$ARCH" \
	-v "$SRC:/src:ro" -v "$WORK:/work" \
	-v "$ROOT/package/upstream:/upstream-src:ro" -v "$ARCHIVE:/upstream/archive.tar.gz:ro" \
	"$IMAGE" /bin/sh -s <<CONTAINER
set -eu
# python3 is the meta package; python3-pip brings the resolver. Both are in the release
# feed, so this needs no third-party repository. A bare rootfs image has no /var/lock.
mkdir -p /var/lock /var/run /var/state
apk update -q
apk add -q python3 python3-pip
UPSTREAM_ARCHIVE=/upstream/archive.tar.gz EXTRAS="${EXTRAS:-cron,mcp,anthropic}" \\
	/src/build.sh "$ARCH" /work/tree
CONTAINER

# The tree is written by root inside the container. On Docker Desktop the host sees it
# as the invoking user and nothing more is needed; on a Linux CI runner it stays
# root-owned, and anything that later edits the tree (teeth.sh, a local experiment)
# fails with "Permission denied" only there. Hand it back before leaving the container.
docker run --rm -i --platform "linux/$ARCH" -v "$WORK:/work" "$IMAGE" \
	chown -R "$(id -u):$(id -g)" /work 2>/dev/null || true


# macOS puts a .DS_Store into any directory Finder or Spotlight touches, and it can
# appear between apk reading the file list and apk writing the contents. The package
# then installs on the router and fails with a bare "file integrity error", which reads
# like a corrupt download rather than a stray 6 kB file. Sweep them before packaging.
find "$WORK/tree" -name .DS_Store -delete 2>/dev/null || true

echo "==> packaging with apk mkpkg"
# The scripts are written here rather than shipped as files because they are three lines
# each and belong next to the metadata that references them.
# One fragment, two scripts. apk runs post-upgrade, not post-install, when it replaces an
# installed version, and runs nothing at all if there is no such script: the r2 -> r3 upgrade
# on 2026-10-01 left a router with the new files and no hermes user. The fragment is
# idempotent, which is what an upgrade needs of it.
cat > "$WORK/account.sh" <<'ACCOUNT'
mkdir -p /etc/hermes-agent
chmod 0700 /etc/hermes-agent
# The account the gateway and its tools run as (profiles owner and assistant). OpenWrt's
# own helpers, so the entries are written the way every other package's are: a group with
# the next free id, a user of the same id when that is free, a locked password field and no
# login shell. Home is the default data directory; UCI can put the data elsewhere, and
# hermes-drop then uses that as HOME. An upgrade and a reinstall find the account and leave
# it. Removal leaves it too (see pre-deinstall).
. /lib/functions.sh
gid=$(group_add_next hermes)
if ! user_exists hermes; then
	uid=$gid
	cut -d: -f3 /etc/passwd | grep -qx "$uid" && uid=""
	home=$(uci -q get hermes.main.data_dir)
	user_add hermes "$uid" "$gid" "Hermes Agent" "${home:-/srv/hermes}" /bin/false
fi
/etc/init.d/hermes-agent enable
ACCOUNT
{
	printf '#!/bin/sh\n'
	cat "$WORK/account.sh"
	printf '# Deliberately not started: the package ships disabled with no key and no model, and a\n'
	printf '# service that cannot work should not spend the first boot logging that it cannot.\n'
	printf 'exit 0\n'
} > "$WORK/post-install"
{
	printf '#!/bin/sh\n'
	cat "$WORK/account.sh"
	# Not restarted here: a restart interrupts a chat in progress, and nothing a build can run
	# proves the restart on a router. So it is said, because until it happens the old gateway
	# keeps running as root and the new profile default has not taken effect.
	printf 'if /etc/init.d/hermes-agent running >/dev/null 2>&1; then\n'
	printf '\techo "hermes-agent: restart it for this release to take effect: service hermes-agent restart"\n'
	printf '\techo "hermes-agent: the gateway then runs as the user hermes, unless the profile in /etc/config/hermes is root."\n'
	printf 'fi\n'
	printf 'exit 0\n'
} > "$WORK/post-upgrade"
cat > "$WORK/pre-deinstall" <<'PRE'
#!/bin/sh
/etc/init.d/hermes-agent stop
/etc/init.d/hermes-agent disable
# The hermes user and group stay, like the data directory and the keys: files that user owns
# are left on disk, and a later user handed the same id would own the agent's sessions. A
# reinstall finds the account and keeps its id. Remove it by hand with the data directory.
exit 0
PRE
chmod 0755 "$WORK/post-install" "$WORK/post-upgrade" "$WORK/pre-deinstall"

docker run --rm -i -v "$WORK:/work" -v "$ROOT/scripts/mkpkg-root.sh:/mkpkg-root:ro" -e OWN="$(id -u):$(id -g)" -w /work "$ALPINE" sh /mkpkg-root \
	--info "name:hermes-agent" \
	--info "version:$HERMES_VERSION-r$PKGREL" \
	--info "arch:$ARCH" \
	--info "license:MIT" \
	--info "origin:hermes-agent" \
	--info "url:https://github.com/NousResearch/hermes-agent" \
	--info "description:Hermes Agent, the self-hosted AI agent, packaged for OpenWrt. Runs as a procd service against any OpenAI-compatible endpoint." \
	--info "depends:$DEPENDS" \
	--script "post-install:/work/post-install" \
	--script "post-upgrade:/work/post-upgrade" \
	--script "pre-deinstall:/work/pre-deinstall" \
	--files /work/tree \
	--output "/work/$OUT"

cp "$WORK/$OUT" "$ROOT/$OUT"
echo "==> $OUT  ($(du -h "$ROOT/$OUT" | cut -f1))"

# Emit the same tree under other architecture labels.
#
# A router reports one exact string in /etc/apk/arch and apk will not look at a package
# declaring anything else, so a Flint 2 on aarch64_cortex-a53 cannot see an
# aarch64_generic package however identical the bytes are. OpenWrt publishes no
# aarch64_cortex-a53 rootfs image, so there is nothing to build IN for that name, and
# there does not need to be: everything in this package is either architecture-neutral
# or a musllinux aarch64 wheel, and the two names differ only in the compiler tuning of
# code we do not ship. Relabelling is therefore honest here. It would not be for a
# package carrying C compiled with -mcpu=cortex-a53.
for extra in ${EXTRA_ARCHES:-}; do
	# Again: a .DS_Store can appear in the tree between the two mkpkg calls (a Finder window
	# open on build/ is enough), and the relabel would then differ from the primary by a
	# file the primary never had. 2026-10-01: it did, and gate-relabel said so.
	find "$WORK/tree" -name .DS_Store -delete 2>/dev/null || true
	xout="hermes-agent-$HERMES_VERSION-r$PKGREL.apk"
	xdir="$ROOT/build/$LINE/$extra"
	rm -rf "$xdir"; mkdir -p "$xdir"
	docker run --rm -i -v "$WORK:/work" -v "$xdir:/out" -v "$ROOT/scripts/mkpkg-root.sh:/mkpkg-root:ro" -e OWN="$(id -u):$(id -g)" -w /work "$ALPINE" sh /mkpkg-root \
		--info "name:hermes-agent" \
		--info "version:$HERMES_VERSION-r$PKGREL" \
		--info "arch:$extra" \
		--info "license:MIT" \
		--info "origin:hermes-agent" \
		--info "url:https://github.com/NousResearch/hermes-agent" \
		--info "description:Hermes Agent, the self-hosted AI agent, packaged for OpenWrt. Runs as a procd service against any OpenAI-compatible endpoint." \
		--info "depends:$DEPENDS" \
		--script "post-install:/work/post-install" \
		--script "post-upgrade:/work/post-upgrade" \
		--script "pre-deinstall:/work/pre-deinstall" \
		--files /work/tree \
		--output "/out/$xout"
	# The relabelled package must be the primary one with nothing changed but the label;
	# r4 shipped without bash on this label because the two calls had drifted apart.
	"$ROOT/scripts/gate-relabel.sh" "$ROOT/$OUT" "$xdir/$xout" || exit 1
	echo "==> also $extra: $xout (identical to the primary apart from the label)"
done
