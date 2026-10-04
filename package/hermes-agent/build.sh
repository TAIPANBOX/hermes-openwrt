#!/bin/sh
# Assemble the file tree for the hermes-agent OpenWrt package.
#
# Why this is not an OpenWrt SDK package
#
# Hermes is Python with 69 dependencies, 13 of which carry compiled Rust or C
# extensions. Building those from source inside the SDK means a Rust toolchain per
# target and hours per build, for a result identical to the wheels their authors
# already publish. Every one of those wheels exists for musllinux aarch64 and x86_64,
# which is exactly what OpenWrt is, so the honest build step is to fetch them.
#
# Checked on OpenWrt 25.12.4 aarch64 on 2026-09-08: pip's top tag there is
# cp313-cp313-musllinux_1_2_aarch64, a pydantic-core wheel (Rust) installs and runs, and
# the whole set installs in 22 seconds with nothing compiled.
#
# That choice is also why this package cannot go to the official feed: openwrt/packages
# requires building from source. It lives in its own feed instead, and that is a
# deliberate trade, not an oversight.
#
# Where this runs
#
# pip resolves wheels for the interpreter it is running under. Cross-downloading with
# --platform looked simpler and does not work: pydantic-core ships stable-ABI wheels
# tagged cp39-abi3, so pinning --implementation cp --python-version 3.13 narrows the tag
# set until pip reports "no matching distribution" for a wheel that plainly exists.
#
# So this script does not cross-build. It runs INSIDE the target: an OpenWrt rootfs
# image of the same release and architecture as the router. That removes the entire
# class of "assembled against the wrong libc" bugs, because the libc doing the
# resolving is the one the router has. build-in-container.sh is the wrapper that puts
# it there; running this script directly on a glibc machine is refused below.
set -eu

usage() {
	echo "usage: build.sh <apk-arch> <staging-dir>" >&2
	echo "  apk-arch: aarch64_generic, aarch64_cortex-a53, x86_64" >&2
	exit 2
}

ARCH=${1:?$(usage)}
OUT=${2:?$(usage)}

# The upstream release this package carries, the commit it is built from and what it
# leaves out: one file, read by the build and by the gates. See package/upstream/.
UPSTREAM_SRC=${UPSTREAM_SRC:-/upstream-src}
. "$UPSTREAM_SRC/upstream.env"
# The verified archive of that commit, fetched on the host by package/upstream/fetch.sh.
UPSTREAM_ARCHIVE=${UPSTREAM_ARCHIVE:?build.sh: UPSTREAM_ARCHIVE (the verified upstream archive) is required}
export HERMES_VERSION HERMES_EXCLUDE

# Refuse to produce a package against the wrong libc. Silent success here would mean a
# tree that only fails on the router, at import time, in front of a user.
python3 - <<'GUARD' || exit 1
import sys, sysconfig
tags = sysconfig.get_config_var("SOABI") or ""
if "musl" not in (sysconfig.get_platform() + tags + sys.version):
    try:
        from packaging.tags import sys_tags
        if not any("musl" in str(t) for t in sys_tags()):
            raise SystemExit("build.sh: this interpreter is not musl; run build-in-container.sh")
    except ImportError:
        import subprocess
        out = subprocess.run(["ldd", sys.executable], capture_output=True, text=True).stdout
        if "musl" not in out:
            raise SystemExit("build.sh: this interpreter is not musl; run build-in-container.sh")
GUARD

# The extras. Deliberately not "all": vision, image generation, browser automation and
# the wake-word stack pull heavy dependencies for capabilities a router does not have.
# cron and mcp are what make it useful here - scheduled work, and the ability to reach
# openwrt-mcp for the router's own ubus.
# anthropic: upstream's native Anthropic provider, which /model picks for api.anthropic.com
# whatever transport a provider entry names, so without it that chat would fail.
EXTRAS=${EXTRAS:-cron,mcp,anthropic}

SRC=$(cd "$(dirname "$0")" && pwd)
SITE="$OUT/usr/lib/hermes-agent/site-packages"

echo "build.sh: hermes-agent $HERMES_VERSION for $ARCH on $(python3 -V 2>&1)"
rm -rf "$OUT"
mkdir -p "$SITE" "$OUT/usr/bin" "$OUT/usr/sbin" "$OUT/etc/init.d" "$OUT/etc/config" \
         "$OUT/etc/hermes-agent" "$OUT/lib/upgrade/keep.d"

# Upstream publishes no wheel after 0.19.0 and refuses to build one outside its Nix
# derivation, so resolve.py builds it the way that derivation does, from the pinned
# archive, and works out the exact dependency set: upstream's uv.lock versions, minus
# HERMES_EXCLUDE and whatever only those needed. See resolve.py's own header.
UP=/tmp/hermes-upstream
rm -rf "$UP"
WHEEL=$(python3 "$UPSTREAM_SRC/resolve.py" build "$UPSTREAM_ARCHIVE" "$UP")
python3 "$UPSTREAM_SRC/resolve.py" closure "$UP" "$EXTRAS" > "$UP/closure.txt"

# --only-binary=:all: turns "no wheel for this target" into a build failure rather than
# a source build that would need a compiler the router image does not have. --no-deps
# because closure.txt IS the dependency set; letting pip resolve again would bring the
# excluded packages straight back, since Hermes declares them.
python3 -m pip install \
	--quiet --no-cache-dir --disable-pip-version-check --root-user-action=ignore \
	--target "$SITE" \
	--only-binary=:all: --no-deps \
	-r "$UP/closure.txt" "$WHEEL"

# What upstream ships beside the wheel, laid out as its Nix derivation lays it out and
# found through the same variables (files/hermes-env). Without them the agent finds no
# bundled skills and prints raw i18n keys instead of messages. web_dist and the TUI are
# Node builds for the dashboard and the terminal UI, neither of which a router runs.
SHARE="$OUT/usr/share/hermes-agent"
mkdir -p "$SHARE"
for d in skills optional-skills locales optional-mcps; do
	[ -d "$UP/src/$d" ] || { echo "build.sh: upstream archive has no $d/" >&2; exit 1; }
	cp -R "$UP/src/$d" "$SHARE/$d"
done
find "$SHARE" -type d \( -name __pycache__ -o -name index-cache \) -exec rm -rf {} + 2>/dev/null || true
cp "$SRC/files/hermes-env" "$OUT/usr/lib/hermes-agent/hermes-env" && chmod 0644 "$OUT/usr/lib/hermes-agent/hermes-env"

# Which upstream this package carries, for anyone on the router and for gate-upstream.
cat > "$OUT/usr/lib/hermes-agent/upstream" <<UPSTREAM
version=$HERMES_VERSION
tag=$HERMES_TAG
commit=$HERMES_COMMIT
archive_sha256=$HERMES_TARBALL_SHA256
excluded=$HERMES_EXCLUDE
UPSTREAM
chmod 0644 "$OUT/usr/lib/hermes-agent/upstream"

# cp and chmod rather than install(1): the OpenWrt rootfs is busybox without the
# install applet, and this script runs inside it.
#
# OpenWrt splits the standard library into apk packages and ships no webbrowser at all,
# so the CLI cannot even print its version without this. See the file's own header.
cp "$SRC/files/shims/webbrowser.py" "$SITE/webbrowser.py" && chmod 0644 "$SITE/webbrowser.py"

# The toolset writer. See its own header: the gateway reads toolsets from config.yaml,
# and the flag the init script used to pass does not exist on that subcommand.
mkdir -p "$OUT/usr/libexec"
cp "$SRC/files/set-toolsets.py" "$OUT/usr/libexec/hermes-set-toolsets"
chmod 0755 "$OUT/usr/libexec/hermes-set-toolsets"
cp "$SRC/files/memory-limit.py" "$OUT/usr/libexec/hermes-memory"
chmod 0755 "$OUT/usr/libexec/hermes-memory"
cp "$SRC/files/runtime-check.py" "$OUT/usr/libexec/hermes-runtime-check"
chmod 0755 "$OUT/usr/libexec/hermes-runtime-check"
# Gives up root for good and runs a command as another user: the exec wrapper's last line,
# its two helpers, and the launcher's re-exec all go through it (see its own header).
cp "$SRC/files/hermes-drop.py" "$OUT/usr/libexec/hermes-drop"
chmod 0755 "$OUT/usr/libexec/hermes-drop"
# Which profile is which account; sourced by the init and the wrapper, so it is said once.
cp "$SRC/files/hermes-profile" "$OUT/usr/lib/hermes-agent/hermes-profile" && chmod 0644 "$OUT/usr/lib/hermes-agent/hermes-profile"
cp "$SRC/files/hermes-usb-check" "$OUT/usr/lib/hermes-agent/hermes-usb-check" && chmod 0644 "$OUT/usr/lib/hermes-agent/hermes-usb-check"
mkdir -p "$OUT/etc/hotplug.d/block"
cp "$SRC/files/hermes-usb.hotplug" "$OUT/etc/hotplug.d/block/90-hermes-usb" && chmod 0644 "$OUT/etc/hotplug.d/block/90-hermes-usb"

# The Hermes-side unlock plugin. It goes in the private site-packages, beside the libraries and
# owned by root like them, so the agent (which runs as hermes) cannot rewrite the code that
# stands between the owner's PIN and the model; and it is found the way upstream finds any
# pip-installed plugin, through a hermes_agent.plugins entry point in a dist-info. It is
# enabled by the bridge (set-toolsets), in the owner profile only. See its own header.
cp "$SRC/files/openwrt_unlock.py" "$SITE/openwrt_unlock.py" && chmod 0644 "$SITE/openwrt_unlock.py"
PLUGIN_DIST="$SITE/openwrt_unlock-$HERMES_VERSION.dist-info"
mkdir -p "$PLUGIN_DIST"
cat > "$PLUGIN_DIST/METADATA" <<METADATA
Metadata-Version: 2.1
Name: openwrt-unlock
Version: $HERMES_VERSION
Summary: The owner's /unlock and /lock in Telegram, and the walls that keep the PIN from the model
METADATA
printf '[hermes_agent.plugins]\nopenwrt-unlock = openwrt_unlock\n' > "$PLUGIN_DIST/entry_points.txt"
printf 'pip\n' > "$PLUGIN_DIST/INSTALLER"
printf 'openwrt_unlock.py,,\nopenwrt_unlock-%s.dist-info/METADATA,,\nopenwrt_unlock-%s.dist-info/entry_points.txt,,\nopenwrt_unlock-%s.dist-info/INSTALLER,,\nopenwrt_unlock-%s.dist-info/RECORD,,\n' \
	"$HERMES_VERSION" "$HERMES_VERSION" "$HERMES_VERSION" "$HERMES_VERSION" > "$PLUGIN_DIST/RECORD"

# pip writes a console script whose shebang points at the machine that ran pip. On the
# router that path does not exist. Write our own, and put the private site-packages on
# the path explicitly rather than relying on the caller's environment.
cat > "$OUT/usr/bin/hermes" <<'LAUNCHER'
#!/bin/sh
# Launcher for the packaged Hermes. The site-packages below is private to this package:
# it is not on the system python path, so nothing else on the router can be broken by
# what Hermes depends on, and Hermes cannot be broken by what the router installs.
SITE=/usr/lib/hermes-agent/site-packages
# Where upstream's skills, locales and MCP catalogue live; see the file itself.
. /usr/lib/hermes-agent/hermes-env
# Hermes's data on a USB stick (hermes-usb): a command pointed at the data directory from a root
# shell, as the README's `HERMES_HOME=/srv/hermes hermes cron create ...` is, refuses rather than
# write under the empty mount point of a stick that is not there, or into a directory hermes-usb
# is moving right now. The path is compared as the kernel resolves it, so /srv//hermes or
# /srv/hermes/ is the same directory. Only root asks: the user hermes cannot read a device's UUID,
# and the gateway, which runs this as hermes, was asked by its wrapper, as root, a moment before
# (a Brume 2 showed it on 2026-10-04, when the gateway refused its own stick).
. /usr/lib/hermes-agent/hermes-usb-check
if [ "$(id -u)" = 0 ] && [ -n "${HERMES_HOME:-}" ]; then
	h=$(readlink -f "$HERMES_HOME" 2>/dev/null) || h=""
	[ -n "$h" ] || { h=$HERMES_HOME; while case "$h" in */) true ;; *) false ;; esac; do h=${h%/}; done; }
	d=$(uci -q get hermes.main.data_dir 2>/dev/null); [ -n "$d" ] || d=/srv/hermes
	if [ "$h" = "${d%/}" ] || [ "$h" = "$(uci -q get fstab.hermes_data.target 2>/dev/null)" ]; then
		why=$(hermes_data_ok "$h") || { echo "hermes: $why" >&2; exit 1; }
	fi
fi
# The gateway runs as the user hermes (the owner and assistant profiles), so what it keeps in
# its data directory belongs to that user. A command run from a root shell against that
# directory, `HERMES_HOME=/srv/hermes hermes cron create ...` over SSH, would leave files
# the gateway then cannot update. So root becomes hermes first, when the directory in
# question is hermes's. HERMES_OPENWRT_AS_ROOT=1 turns that off (the exec wrapper sets it
# for the root profile). Anything not root, or a directory that is not hermes's, runs as
# the caller as before.
if [ "$(id -u)" = 0 ] && [ -z "${HERMES_OPENWRT_AS_ROOT:-}" ]; then
	dir=${HERMES_HOME:-${HOME:-/root}/.hermes}
	if [ -d "$dir" ] && [ "$(ls -ldn "$dir" | awk '{print $3}')" = "$(id -u hermes 2>/dev/null)" ]; then
		PYTHONPATH="$SITE${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1 \
		exec /usr/bin/python3 -I -B /usr/libexec/hermes-drop hermes /usr/bin/python3 "$SITE/hermes_cli/main.py" "$@"
	fi
fi
# Bytecode is shipped with the package, so writing more of it at runtime can only put
# unowned files inside the package directory and leave litter behind on removal.
PYTHONPATH="$SITE${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1 \
exec /usr/bin/python3 "$SITE/hermes_cli/main.py" "$@"
LAUNCHER
chmod 0755 "$OUT/usr/bin/hermes"

cp "$SRC/files/hermes-agent.init"   "$OUT/etc/init.d/hermes-agent" && chmod 0755 "$OUT/etc/init.d/hermes-agent"
# The gateway wrapper reads the key at exec time so procd never holds it; see the file
# itself and check_key_not_in_procd_env.
cp "$SRC/files/hermes-gateway"      "$OUT/usr/sbin/hermes-gateway"    && chmod 0755 "$OUT/usr/sbin/hermes-gateway"
cp "$SRC/files/hermes-login"        "$OUT/usr/sbin/hermes-login"      && chmod 0755 "$OUT/usr/sbin/hermes-login"
cp "$SRC/files/hermes-usb"          "$OUT/usr/sbin/hermes-usb"        && chmod 0755 "$OUT/usr/sbin/hermes-usb"
cp "$SRC/files/hermes-agent.config" "$OUT/etc/config/hermes" && chmod 0644 "$OUT/etc/config/hermes"

# Survive a firmware upgrade: sysupgrade keeps what is listed here, and losing the key
# files would leave a configured agent that silently cannot authenticate.
cat > "$OUT/lib/upgrade/keep.d/hermes-agent" <<'KEEP'
/etc/config/hermes
/etc/hermes-agent/
KEEP
chmod 0644 "$OUT/lib/upgrade/keep.d/hermes-agent"

# Trim what a router will never read. This is worth less than it looks (about 1 MB of
# 198), and the number is stated here so nobody spends an afternoon chasing it: the size
# is real library code, not packaging slack.
find "$SITE" -type d \( -name tests -o -name test -o -name docs -o -name examples \) \
	-exec rm -rf {} + 2>/dev/null || true
# -exec rm, not -delete: the rootfs busybox find has no -delete, and until 0.21.5 this
# line failed there quietly behind 2>/dev/null and removed nothing.
find "$SITE" -name '*.pyi' -exec rm -f {} + 2>/dev/null || true

# Precompile. Upstream's container sets PYTHONDONTWRITEBYTECODE=1, which is right for a
# container that is rebuilt constantly and wrong for a router that boots the same tree
# for a year on a slow core. Compiling here means the device never pays to parse.
python3 -m compileall -q -j 0 "$SITE" >/dev/null 2>&1 || true

echo "build.sh: tree assembled at $OUT ($(du -sh "$OUT" | cut -f1))"
echo "build.sh: $(find "$SITE" -maxdepth 1 -name '*.dist-info' | wc -l | tr -d ' ') python packages, hermes-agent $HERMES_VERSION from $HERMES_COMMIT"
