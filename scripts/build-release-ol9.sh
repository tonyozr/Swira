#!/usr/bin/env bash
# build-release-ol9.sh
#
# Builds swira-web as a portable Linux binary compatible with Oracle Linux 9
# (and any RHEL9-based distro). Produces a self-contained executable with
# Swift stdlib, libcurl, and OpenSSL statically linked — only libc/libm/libz/
# libstdc++/libgcc_s remain dynamic, which are present on every Linux system.
#
# Requirements: Docker
# Output:       .build/release/swira-web
#
# Usage:
#   ./scripts/build-release-ol9.sh
#   ./scripts/build-release-ol9.sh --no-cache   # force full rebuild inside container

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_IMAGE="swift:6.3.3-rhel-ubi9"
OPENSSL_VER="3.0.16"
CURL_VER="8.9.1"

NO_CACHE_FLAG=""
if [[ "${1:-}" == "--no-cache" ]]; then
  NO_CACHE_FLAG="--no-cache"
fi

echo "==> Building swira-web (OL9-compatible, static curl+ssl)"
echo "    Swift image : $SWIFT_IMAGE"
echo "    OpenSSL     : $OPENSSL_VER"
echo "    curl        : $CURL_VER"
echo "    Output      : $REPO_ROOT/.build/release/swira-web"
echo ""

docker run --rm $NO_CACHE_FLAG \
  -v "$REPO_ROOT":/workspace \
  -w /workspace \
  "$SWIFT_IMAGE" \
  bash -c "
set -euo pipefail

echo '--- [1/4] Installing build tools ---'
dnf install -y gcc make perl openssl-devel zlib-devel tar gzip 2>&1 | tail -4

echo '--- [2/4] Building static OpenSSL ${OPENSSL_VER} ---'
curl -fsSL https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz \
  -o /tmp/openssl.tar.gz
cd /tmp && tar xf openssl.tar.gz && cd openssl-${OPENSSL_VER}
./Configure --prefix=/usr/local/ssl --openssldir=/usr/local/ssl \
  no-shared no-tests linux-x86_64 2>&1 | tail -3
make -j\$(nproc) 2>&1 | tail -2
make install_sw 2>&1 | tail -2
echo \"  libssl.a    \$(du -sh /usr/local/ssl/lib64/libssl.a   | cut -f1)\"
echo \"  libcrypto.a \$(du -sh /usr/local/ssl/lib64/libcrypto.a | cut -f1)\"

echo '--- [3/4] Building static curl ${CURL_VER} ---'
curl -fsSL https://curl.se/download/curl-${CURL_VER}.tar.gz -o /tmp/curl.tar.gz
cd /tmp && tar xf curl.tar.gz && cd curl-${CURL_VER}
./configure \
  --disable-shared --enable-static \
  --with-openssl=/usr/local/ssl \
  --without-nghttp2 \
  --disable-ldap --disable-rtsp --disable-dict --disable-telnet \
  --disable-tftp --disable-pop3 --disable-imap --disable-smtp \
  --disable-gopher \
  --prefix=/usr/local 2>&1 | tail -4
make -j\$(nproc) 2>&1 | tail -2
make install    2>&1 | tail -2
echo \"  libcurl.a   \$(du -sh /usr/local/lib/libcurl.a | cut -f1)\"

echo '--- [4/4] Building swira-web ---'
cd /workspace
rm -rf .build
swift build -c release --product swira-web \
  --static-swift-stdlib \
  -Xlinker -L/usr/local/lib \
  -Xlinker -L/usr/local/ssl/lib64 \
  -Xlinker -Bstatic \
  -Xlinker -lcurl \
  -Xlinker -lssl \
  -Xlinker -lcrypto \
  -Xlinker -Bdynamic \
  -Xlinker -lz
"

echo ""
echo "==> Build complete"
ls -lh "$REPO_ROOT/.build/release/swira-web"
echo ""
echo "==> Dynamic dependencies (should be only libc/libm/libz/libstdc++/libgcc_s):"
ldd "$REPO_ROOT/.build/release/swira-web" 2>/dev/null || echo "  (ldd not available on this host)"
