#!/bin/sh
# feed-keygen.sh -- make the signing pair for the feed. Run once, ever.
#
# apk-tools v3 signs with an elliptic-curve key on prime256v1, the same shape OpenWrt
# uses for its own release keys: /etc/apk/keys/openwrt-25.12.pem on any 25.12 device is
# a 178-byte PEM public key of exactly this kind. Ed25519, which opkg used through
# usign, is a different mechanism and does not apply here.
#
# What each half is for
#
#   public   Committed, published with the feed, and copied to /etc/apk/keys on every
#            router that installs from it. Nothing about it is secret.
#   private  Signs packages and the index. Whoever holds it can publish a package that
#            every router trusting this feed will install without a warning, so it is
#            the one artefact in this repository that must never be committed and never
#            be pasted anywhere.
#
# Rotation is not a formality here. If the private key leaks, publishing a new public
# key does NOT undo it: every router still carries the old key in /etc/apk/keys and will
# keep trusting anything signed with it until a person logs in and removes the file.
# There is no revocation. So: generate it once, keep it in one place, and if it is ever
# in doubt, say so publicly rather than quietly rotating.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/keys}
NAME=${NAME:-hermes-openwrt}
ALPINE=${ALPINE:-alpine@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000}

mkdir -p "$OUT"

# 24.10 signs with usign, which is Ed25519 and a different mechanism entirely from the
# EC key apk uses. Neither key works for the other line, so a repository serving both
# releases needs both, and both are generated here so nobody discovers the second one
# missing halfway through a release.
if [ ! -f "$OUT/$NAME.usign.pub" ]; then
	docker run --rm -i -v "$OUT:/out" "$ALPINE" /bin/sh -s <<'USIGN'
set -eu
apk add -q --no-cache build-base git >/dev/null 2>&1
# usign is not packaged for Alpine, and it is 400 lines around libsodium's Ed25519.
apk add -q --no-cache libsodium-dev cmake >/dev/null 2>&1
git clone -q --depth 1 https://git.openwrt.org/project/usign.git /tmp/usign 2>/dev/null \
  || git clone -q --depth 1 https://github.com/openwrt/usign.git /tmp/usign
cd /tmp/usign && cmake -DCMAKE_BUILD_TYPE=Release . >/dev/null 2>&1 && make >/dev/null 2>&1
umask 077
./usign -G -s /out/usign.sec -p /out/usign.pub -c "hermes-openwrt feed"
chmod 600 /out/usign.sec; chmod 644 /out/usign.pub
USIGN
	mv "$OUT/usign.pub" "$OUT/$NAME.usign.pub"
	mv "$OUT/usign.sec" "$OUT/$NAME.usign.sec"
	chmod 600 "$OUT/$NAME.usign.sec"
	echo "usign pair created for the 24.10 (opkg) line"
fi

if [ -f "$OUT/$NAME.pem" ]; then
	echo "feed-keygen.sh: $OUT/$NAME.pem already exists." >&2
	echo "feed-keygen.sh: a second key does not replace the first on any router that" >&2
	echo "feed-keygen.sh: already trusts it. Delete it deliberately if you mean to." >&2
	exit 1
fi

# In a container, so the key is made by a pinned openssl rather than whatever the host
# happens to have, and so no key material is written outside the two files below.
docker run --rm -i -v "$OUT:/out" "$ALPINE" /bin/sh -s <<'CONTAINER'
set -eu
apk add -q --no-cache openssl
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out /out/private.tmp
openssl ec -in /out/private.tmp -pubout -out /out/public.tmp 2>/dev/null
chmod 600 /out/private.tmp
chmod 644 /out/public.tmp
CONTAINER

mv "$OUT/public.tmp" "$OUT/$NAME.pem"
mv "$OUT/private.tmp" "$OUT/$NAME.private.pem"
chmod 600 "$OUT/$NAME.private.pem"

cat <<EOF

Public key   $OUT/$NAME.pem          commit this, it is published with the feed
Private key  $OUT/$NAME.private.pem  NEVER commit this

.gitignore excludes *.private.pem and *.usign.sec. Put the private key where CI can reach it:

  gh secret set FEED_SIGNING_KEY --repo TAIPANBOX/hermes-openwrt < "$OUT/$NAME.private.pem"

and keep your own copy somewhere you would keep a password. There is no way to recover
it, and no way to revoke it from a router that has already trusted the public half.
EOF
