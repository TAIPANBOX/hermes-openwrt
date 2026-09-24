#!/bin/sh
# @codex 2026-09-19: actual packaged payload, real procd serialization and kernel OOM.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = --selftest ]; then
    python3 - "$ROOT/scripts/test-runtime.py" <<'PY'
import ast, sys
methods = [n.name for n in ast.walk(ast.parse(open(sys.argv[1]).read()))
           if isinstance(n, ast.FunctionDef) and n.name.startswith('test_')]
if not methods:
    sys.exit('measured nothing: no runtime tests')
for name in sorted(methods):
    print('check_' + name[5:])
PY
    exit
fi
ARCH=${ARCH:-aarch64_generic}
RELEASE=${RELEASE:-25.12.4}
LINE=${RELEASE%.*}
case "$ARCH" in x86_64) IMAGE="openwrt/rootfs:x86-64-$RELEASE";; *) IMAGE="openwrt/rootfs:$ARCH-$RELEASE";; esac
BUILD="$ROOT/build/$LINE/$ARCH"
[ -d "$BUILD/tree" ] || { echo 'measured nothing: no built payload' >&2; exit 1; }
# Convenience for iterating on one test at a time: any arguments name the tests to run
# (e.g. RuntimeTests.test_x), and the mutation tests are skipped. No arguments runs the
# full suite followed by teeth-runtime.py, as before.
RUNTIME_TESTS="$*"
# This privileged container has a PRIVATE cgroup namespace and no writable host
# mounts. Its root cgroup is the disposable container, never the host namespace.
docker run --rm -i --platform "linux/$ARCH" --privileged --cgroupns private --memory 1g \
    -e RUNTIME_TESTS="$RUNTIME_TESTS" \
    -v "$ROOT:/src:ro" -v "$BUILD:/build:ro" -v "$BUILD-telegram:/addon:ro" "$IMAGE" sh -s <<'CONTAINER'
set -eu
mkdir -p /var/lock /var/run /var/state /etc/hermes-agent
if command -v apk >/dev/null; then
    apk update -q
    apk add --allow-untrusted /build/hermes-agent-[0-9]*.apk /addon/hermes-agent-telegram-*.apk >/tmp/install.log 2>&1 || { cat /tmp/install.log; exit 1; }
else
    opkg update >/dev/null
    opkg install /build/hermes-agent_[0-9]*.ipk /addon/hermes-agent-telegram_*.ipk >/tmp/install.log 2>&1 || { cat /tmp/install.log; exit 1; }
fi
# Package installation is complete; runtime proofs may reach loopback only.
ip link set eth0 down
# Move the harness out of the parent before enabling a domain controller.
mkdir /sys/fs/cgroup/harness
echo $$ > /sys/fs/cgroup/harness/cgroup.procs
export PYTHONPATH=/usr/lib/hermes-agent/site-packages PYTHONDONTWRITEBYTECODE=1
# Assert tests use precisely the code installed from the archive.
mkdir /tmp/product
cp /usr/sbin/hermes-gateway /tmp/product/hermes-gateway
cp /etc/init.d/hermes-agent /tmp/product/hermes-agent.init
cp /usr/libexec/hermes-set-toolsets /tmp/product/set-toolsets.py
cp /usr/libexec/hermes-memory /tmp/product/memory-limit.py
cp /usr/libexec/hermes-runtime-check /tmp/product/runtime-check.py
export PRODUCT_FILES=/tmp/product
if [ -n "${RUNTIME_TESTS:-}" ]; then
    python3 /src/scripts/test-runtime.py $RUNTIME_TESTS
else
    python3 /src/scripts/test-runtime.py
    python3 /src/scripts/teeth-runtime.py
fi
CONTAINER
