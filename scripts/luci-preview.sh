#!/bin/sh
# luci-preview.sh -- bring the LuCI pages up on a real OpenWrt, for looking at.
#
# This exists because the screenshots in the README are the only part of this repository
# that cannot be checked by a gate: a page can install, register on ubus, answer every
# call and still be laid out wrong, and the only way to know is to look. It was done by
# hand once and the recipe was lost, so it is a script now.
#
# Four things that each cost an afternoon the first time:
#
#   1. LuCI needs procd as PID 1. The rootfs images run a shell by default and nothing
#      brings rpcd, uhttpd or ubus up, so the pages 404 or hang. The container is
#      therefore prepared in one pass, committed, and started again with /sbin/init.
#   2. netifd takes eth0 into br-lan and gives it 192.168.1.1, which kills the port
#      Docker published a second after boot. /etc/init.d/network is stubbed out after
#      the packages are installed and before init ever runs.
#   3. --privileged is NOT the fix for anything here. It breaks outbound networking in
#      this image entirely, so apk cannot reach the feed.
#   4. A headless browser cannot log into LuCI by submitting the form: the session is
#      not persisted and the page bounces back. So the login happens with curl INSIDE
#      the container, and the resulting sysauth cookie is handed to the browser by a
#      page served from the router itself, which makes it same-origin and makes the
#      cookie stick.
set -eu

ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
PORT=${PORT:-8080}
PASS=${PASS:-hermes-preview}
NAME=${NAME:-hermes-luci-preview}
case "$ARCH" in
	x86_64) IMAGE="openwrt/rootfs:x86-64-$RELEASE" ;;
	*)      IMAGE="openwrt/rootfs:$ARCH-$RELEASE" ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINE=${LINE:-${RELEASE%%.*}.$(echo "$RELEASE" | cut -d. -f2)}
BUILD_DIR="$ROOT/build/$LINE/$ARCH"

# $1 unquoted, so the shell expands the glob. Quoting it makes ls look for a file whose
# name contains a literal asterisk, find nothing, and the function then returns non-zero
# into a `set -e` assignment: the first version of this script exited 1 having printed
# not one character, before even reaching the message that says what is missing.
# `|| true` keeps an empty result from being an error in its own right.
pick() { f=$(ls -t $1 2>/dev/null | head -1); [ -n "$f" ] && echo "$f"; true; }
AGENT=${AGENT:-$(pick "$BUILD_DIR/hermes-agent-[0-9]*.apk")}
ADDON=${ADDON:-$(pick "$BUILD_DIR-telegram/hermes-agent-telegram-*.apk")}
LUCI=${LUCI:-$(pick "$ROOT/build/luci-app-hermes-apk/luci-app-hermes-*.apk")}
for pair in "agent:$AGENT" "telegram:$ADDON" "luci:$LUCI"; do
	v=${pair#*:}
	[ -n "$v" ] && [ -f "$v" ] || {
		echo "luci-preview: no ${pair%%:*} package for $ARCH on $RELEASE. Build them:" >&2
		echo "  ./package/hermes-agent/build-in-container.sh $ARCH" >&2
		echo "  ./package/hermes-agent-telegram/build-in-container.sh $ARCH" >&2
		echo "  ./package/luci-app-hermes/build.sh" >&2
		exit 1; }
done
echo "==> $(basename "$AGENT"), $(basename "$ADDON"), $(basename "$LUCI")"

docker rm -f "$NAME" "$NAME-prep" >/dev/null 2>&1 || true
# The image from the previous run too. `docker commit` below re-tags $NAME:latest, and a
# re-tag leaves the previous image behind with no tag at all: invisible to `docker
# images`, 394 MB each, one per run. Two of them were found on 2026-09-08 only because
# `docker system df` disagreed with the listing by exactly their size.
docker rmi -f "$NAME:latest" >/dev/null 2>&1 || true

echo "==> preparing the rootfs"
docker run --name "$NAME-prep" -i --platform "linux/$ARCH" \
	-v "$AGENT:/a.apk:ro" -v "$ADDON:/t.apk:ro" -v "$LUCI:/l.apk:ro" \
	"$IMAGE" /bin/sh -s <<PREP
set -eu
mkdir -p /var/lock /var/run /var/state
apk update -q
apk add -q luci luci-base uhttpd uhttpd-mod-ubus rpcd rpcd-mod-file rpcd-mod-luci curl
apk add -q --allow-untrusted /a.apk /t.apk /l.apk

# A password, because LuCI refuses to log in against an empty one and then says nothing
# useful about why.
printf '%s\n%s\n' '$PASS' '$PASS' | passwd root >/dev/null 2>&1

# Settings a reader should see on the page: a configured agent with Telegram on, a
# stored key and a stored token, and one allowed user. No real secret goes near this.
uci set hermes.main.enabled=1
uci set hermes.main.base_url='https://openrouter.ai/api/v1'
uci set hermes.main.model='anthropic/claude-haiku-4.5'
uci set hermes.main.data_dir='/srv/hermes'
uci set hermes.main.mem_max_mb='512'
uci set hermes.telegram.enabled=1
uci add_list hermes.telegram.allow_user_id='123456789'
uci set hermes.telegram.home_channel='123456789'
uci commit hermes
mkdir -p /etc/hermes-agent /srv/hermes && chmod 0700 /etc/hermes-agent
printf 'sk-preview-not-a-real-key' > /etc/hermes-agent/provider.key
printf '123456789:AAHpreviewTokenNotRealAAHpreviewToken' > /etc/hermes-agent/telegram.token
printf 'preview-not-a-real-token' > /etc/hermes-agent/router-mcp.token
chmod 600 /etc/hermes-agent/provider.key /etc/hermes-agent/telegram.token /etc/hermes-agent/router-mcp.token

# See the header. netifd would take eth0 into br-lan and the published port would die
# about a second after init starts.
cat > /etc/init.d/network <<'STUB'
#!/bin/sh /etc/rc.common
START=19
start() { return 0; }
stop() { return 0; }
reload() { return 0; }
STUB
chmod 0755 /etc/init.d/network
PREP

docker commit "$NAME-prep" "$NAME:latest" >/dev/null
docker rm -f "$NAME-prep" >/dev/null

echo "==> booting it with procd as PID 1"
# --tmpfs, sized like the reference device's storage.
#
# Without it df inside the container reports the HOST's disk, and the overview page says
# something like "855.5 GB free" where a GL.iNet Flint 2 has 8 GB of eMMC in total. That
# number is the one on the page a router owner reads to decide whether to move the data
# directory to a stick, so a screenshot of it has to be the router's number. Mounting
# from inside needs CAP_SYS_ADMIN, and --privileged breaks outbound networking in this
# image, so it is a run flag.
docker run -d --name "$NAME" --platform "linux/$ARCH" -p "$PORT:80" \
	--tmpfs "/srv/hermes:size=${DATA_MB:-6400}m,mode=0700" \
	"$NAME:latest" /sbin/init >/dev/null
i=0
while [ "$i" -lt 40 ]; do
	if docker exec "$NAME" /bin/sh -c 'ubus list >/dev/null 2>&1 && pgrep uhttpd >/dev/null'; then break; fi
	i=$((i + 1)); sleep 1
done
[ "$i" -lt 40 ] || { echo "luci-preview: ubus or uhttpd never came up"; docker logs "$NAME" | tail -20; exit 1; }

echo "==> logging in inside the container and serving the cookie from the router"
SID=$(docker exec "$NAME" /bin/sh -c "
	curl -s -i -o /tmp/login.out -X POST \
	  -d 'luci_username=root&luci_password=$PASS' \
	  http://127.0.0.1/cgi-bin/luci >/dev/null 2>&1
	sed -n 's/.*sysauth_http=\([a-f0-9]*\).*/\1/p' /tmp/login.out | head -1")
[ -n "$SID" ] || { echo "luci-preview: no session cookie came back from the login"; exit 1; }

docker exec "$NAME" /bin/sh -c "cat > /www/enter.html <<HTML
<!doctype html><meta charset=utf-8><title>entering</title>
<script>
document.cookie = 'sysauth_http=$SID; path=/';
document.cookie = 'sysauth=$SID; path=/';
location.replace(new URLSearchParams(location.search).get('to') || '/cgi-bin/luci/admin/services/hermes');
</script>
HTML"

echo
echo "==> ready. Open, in this order:"
echo "     http://127.0.0.1:$PORT/enter.html?to=/cgi-bin/luci/admin/services/hermes"
echo "     http://127.0.0.1:$PORT/cgi-bin/luci/admin/services/hermes/settings"
echo "   session $SID"
echo "   stop it with: docker rm -f $NAME && docker rmi $NAME:latest"
