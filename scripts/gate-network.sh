#!/bin/sh
# gate-network.sh -- what the agent's own connections reach, with real nft, real fw4 and real
# sockets. The checks behind features/network.feature.
#
# Invariant:
#
#   "The agent's user reaches the internet, DNS, openwrt-mcp, llm-gateway and the endpoints UCI
#   names, and neither the router's own ports nor the hosts of the house, over IPv4 and IPv6. The
#   rules are a table of their own that a defect cannot take the router's firewall down with."
#
# Nothing here needs a built package, because what is under test is one program, two small scripts
# and the kernel: the files come straight from package/hermes-agent/files and the rest is OpenWrt's
# own rootfs, so this runs in the scenarios job, which every pull request needs. That they are in
# the package, and leave with it, is scripts/gate-package.sh's; that the init and the wrapper run
# them is scripts/gate-runtime.sh's; that an open window cannot lift them is scripts/gate-unlock.sh's.
#
#   gate-network.sh                  all checks, then their teeth (scripts/teeth-network.py)
#   gate-network.sh NetworkTests.test_x   just that one, no teeth
#   RED_FIRST=1 gate-network.sh      every check against the router as it is without hermes-net
#   PRODUCT=/dir                     another copy of package/hermes-agent/files
#   gate-network.sh --selftest       the check names, for gate-scenarios-bound.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = --selftest ]; then
	python3 - "${TESTS:-$ROOT/scripts/test-network.py}" <<'PY'
import ast, sys
methods = [n.name for n in ast.walk(ast.parse(open(sys.argv[1]).read()))
           if isinstance(n, ast.FunctionDef) and n.name.startswith('test_')]
if not methods:
    sys.exit('measured nothing: no network tests')
for name in sorted(methods):
    print('check_' + name[5:])
PY
	exit
fi

ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
case "$ARCH" in x86_64) IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:x86-64-$RELEASE} ;; *) IMAGE=${ROOTFS_IMAGE:-openwrt/rootfs:$ARCH-$RELEASE} ;; esac
PRODUCT=${PRODUCT:-$ROOT/package/hermes-agent/files}
[ -f "$PRODUCT/hermes-agent.init" ] || { echo "measured nothing: no product files in $PRODUCT" >&2; exit 1; }
if [ ! -f "$PRODUCT/hermes-net.py" ] && [ -z "${RED_FIRST:-}" ]; then
	echo "measured nothing: no hermes-net in $PRODUCT" >&2; exit 1
fi

# -i is load-bearing, as in every gate here: without it `sh -s` reads an empty stdin and the
# container exits 0 having run nothing. --privileged for nft, namespaces and the sysctls. The
# container's own network namespace is the router; nothing here touches the host's.
docker run -v "$ROOT/scripts/apk-retry.sh:/apk-retry.sh:ro" ${APK_CACHE:+-v "$APK_CACHE:/apk-cache"} --rm -i --platform "linux/$ARCH" --privileged \
	-e NETWORK_TESTS="$*" -e RED_FIRST="${RED_FIRST:-}" -e TEETH_ONLY="${TEETH_ONLY:-}" \
	-v "$ROOT:/src:ro" -v "$PRODUCT:/product-src:ro" "$IMAGE" sh -s <<'CONTAINER'
. /apk-retry.sh  # apk retries a download the feed cut off; see the file
set -eu
mkdir -p /var/lock /var/run /var/state /var/run/ubus
chmod 1777 /tmp
apk update -q
apk add -q python3 ip-full >/tmp/install.log 2>&1 || { cat /tmp/install.log; exit 1; }
# Everything below happens between the namespaces made here.
ip link set eth0 down 2>/dev/null || true
ubusd >/tmp/ubusd.log 2>&1 &
i=0
until ubus list >/dev/null 2>&1; do
	i=$((i + 1)); [ "$i" -lt 20 ] || { cat /tmp/ubusd.log; echo "ubusd did not start"; exit 1; }
	sleep 1
done
# A copy, so the teeth can plant their faults in it.
mkdir /tmp/product
cp -R /product-src/. /tmp/product/
export PRODUCT_FILES=/tmp/product PYTHONDONTWRITEBYTECODE=1
if [ -n "${NETWORK_TESTS:-}" ]; then
	python3 /src/scripts/test-network.py $NETWORK_TESTS
elif [ -n "${RED_FIRST:-}" ]; then
	python3 /src/scripts/test-network.py
else
	python3 /src/scripts/test-network.py
	python3 /src/scripts/teeth-network.py
fi
CONTAINER
