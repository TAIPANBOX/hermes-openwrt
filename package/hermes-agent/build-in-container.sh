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
# 25.12.x uses apk; 24.10.x is the older maintained line and still uses opkg. The payload
# is identical either way, but the container format, the index and the signature scheme
# all differ, and so does Python: 3.13 on 25.12 against 3.11 on 24.10. That last one is
# why the tree cannot be built once and reused across the two: the wheel set differs.
RELEASE=${RELEASE:-25.12.4}
case "$RELEASE" in
	24.10*) FORMAT=ipk ;;
	*)      FORMAT=apk ;;
esac
HERMES_VERSION=${HERMES_VERSION:-0.19.0}
PKGREL=${PKGREL:-1}

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

echo "==> assembling the tree inside $IMAGE"
docker run --rm -i --platform "linux/$ARCH" \
	-v "$SRC:/src:ro" -v "$WORK:/work" \
	"$IMAGE" /bin/sh -s <<CONTAINER
set -eu
# python3 is the meta package; python3-pip brings the resolver. Both are in the release
# feed on either line, so this needs no third-party repository. Which tool installs them
# depends on the release: 25.12 has apk, 24.10 has opkg, and neither image carries the
# other. opkg also refuses to do anything at all without /var/lock, which a bare rootfs
# image does not have.
mkdir -p /var/lock /var/run /var/state
if command -v apk >/dev/null 2>&1; then
	apk update -q
	apk add -q python3 python3-pip
else
	opkg update >/dev/null
	opkg install python3 python3-pip >/dev/null
fi
HERMES_VERSION=$HERMES_VERSION EXTRAS="${EXTRAS:-cron,mcp}" \\
	/src/build.sh "$ARCH" /work/tree
CONTAINER

# The tree is written by root inside the container. On Docker Desktop the host sees it
# as the invoking user and nothing more is needed; on a Linux CI runner it stays
# root-owned, and anything that later edits the tree (teeth.sh, a local experiment)
# fails with "Permission denied" only there. Hand it back before leaving the container.
docker run --rm -i --platform "linux/$ARCH" -v "$WORK:/work" "$IMAGE" \
	chown -R "$(id -u):$(id -g)" /work 2>/dev/null || true

if [ "$FORMAT" = ipk ]; then
	echo "==> packaging with mkipk.sh (opkg, $RELEASE)"
	# In a container, because mkipk.sh needs GNU tar for --sort and --mtime and macOS
	# ships BSD tar, which fails with "Option --sort=name is not supported". Those flags
	# are what make the package reproducible, so dropping them is not the answer.
	docker run --rm -i -v "$SRC:/src:ro" -v "$WORK:/work" -v "$ROOT:/out" \
		-e HERMES_VERSION="$HERMES_VERSION" -e PKGREL="$PKGREL" -e DEST=/out \
		"$ALPINE" sh -c "apk add -q --no-cache tar >/dev/null 2>&1; /src/mkipk.sh /work/tree '$ARCH' '$HERMES_VERSION'"
	# Keep a per-architecture copy too, so a feed build can tell the two apart: unlike
	# apk, an .ipk filename does carry the architecture, but the feed layout wants them
	# separated anyway.
	cp "$ROOT"/hermes-agent_*_"$ARCH".ipk "$WORK/" 2>/dev/null || true

	# The same relabelling the apk path does, and for the same reason: a Flint 2 asks
	# opkg for aarch64_cortex-a53 and will not take a package whose Architecture says
	# otherwise, while OpenWrt publishes no aarch64_cortex-a53 rootfs to build inside.
	for extra in ${EXTRA_ARCHES:-}; do
		docker run --rm -i -v "$SRC:/src:ro" -v "$WORK:/work" -v "$ROOT:/out" \
			-e HERMES_VERSION="$HERMES_VERSION" -e PKGREL="$PKGREL" -e DEST=/out \
			"$ALPINE" sh -c "apk add -q --no-cache tar >/dev/null 2>&1; /src/mkipk.sh /work/tree '$extra' '$HERMES_VERSION'"
		echo "==> also $extra"
	done
	exit 0
fi

echo "==> packaging with apk mkpkg"
# The scripts are written here rather than shipped as files because they are three lines
# each and belong next to the metadata that references them.
cat > "$WORK/post-install" <<'POST'
#!/bin/sh
mkdir -p /etc/hermes-agent
chmod 0700 /etc/hermes-agent
/etc/init.d/hermes-agent enable
# Deliberately not started: the package ships disabled with no key and no model, and a
# service that cannot work should not spend the first boot logging that it cannot.
exit 0
POST
cat > "$WORK/pre-deinstall" <<'PRE'
#!/bin/sh
/etc/init.d/hermes-agent stop
/etc/init.d/hermes-agent disable
exit 0
PRE
chmod 0755 "$WORK/post-install" "$WORK/pre-deinstall"

docker run --rm -i -v "$WORK:/work" -w /work "$ALPINE" apk mkpkg \
	--info "name:hermes-agent" \
	--info "version:$HERMES_VERSION-r$PKGREL" \
	--info "arch:$ARCH" \
	--info "license:MIT" \
	--info "origin:hermes-agent" \
	--info "url:https://github.com/NousResearch/hermes-agent" \
	--info "description:Hermes Agent, the self-hosted AI agent, packaged for OpenWrt. Runs as a procd service against any OpenAI-compatible endpoint." \
	--info "depends:python3 python3-pip ca-bundle ffmpeg ffprobe ripgrep" \
	--script "post-install:/work/post-install" \
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
	xout="hermes-agent-$HERMES_VERSION-r$PKGREL.apk"
	xdir="$ROOT/build/$LINE/$extra"
	rm -rf "$xdir"; mkdir -p "$xdir"
	docker run --rm -i -v "$WORK:/work" -v "$xdir:/out" -w /work "$ALPINE" apk mkpkg \
		--info "name:hermes-agent" \
		--info "version:$HERMES_VERSION-r$PKGREL" \
		--info "arch:$extra" \
		--info "license:MIT" \
		--info "origin:hermes-agent" \
		--info "url:https://github.com/NousResearch/hermes-agent" \
		--info "description:Hermes Agent, the self-hosted AI agent, packaged for OpenWrt. Runs as a procd service against any OpenAI-compatible endpoint." \
		--info "depends:python3 python3-pip ca-bundle ffmpeg ffprobe ripgrep" \
		--script "post-install:/work/post-install" \
		--script "pre-deinstall:/work/pre-deinstall" \
		--files /work/tree \
		--output "/out/$xout"
	echo "==> also $extra: $xout"
done
