#!/usr/bin/env bash

# Download OpenSSL 3.1.2 tarball and checksum from package.cosmian.com and install it.
#
# Usage:
#   OPENSSL_DIR=/usr/local/openssl \
#   bash .github/reusable_scripts/import_openssl_from_package.sh linux x86_64
#
# This script:
#   - Downloads tarball and .sha256 from https://package.cosmian.com/openssl/3.1.2/
#   - Verifies checksum
#   - Extracts into OPENSSL_DIR (sudo fallback if needed)

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: OPENSSL_DIR=/path bash $0 <os: linux|darwin|windows?> <arch: x86_64|aarch64>" >&2
  exit 1
fi

OS=$1
ARCH=$2
VERSION=3.1.2
BASE_URL=${BASE_URL:-https://package.cosmian.com/openssl/$VERSION}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

TARBALL="openssl-${VERSION}-${OS}-${ARCH}-glibc2.27.tar.gz"
URL_TARBALL="$BASE_URL/$TARBALL"
URL_SHA="$BASE_URL/$TARBALL.sha256"

echo "Fetching $URL_TARBALL"
curl -fsSL "$URL_TARBALL" -o "$TMP_DIR/$TARBALL"
echo "Fetching $URL_SHA"
curl -fsSL "$URL_SHA" -o "$TMP_DIR/$TARBALL.sha256"

pushd "$TMP_DIR" >/dev/null
sha256sum -c "$TARBALL.sha256"
popd >/dev/null

OPENSSL_DIR=${OPENSSL_DIR:-/usr/local/openssl}
mkdir -p "$OPENSSL_DIR" || sudo mkdir -p "$OPENSSL_DIR"
if [ ! -w "$OPENSSL_DIR" ]; then
  echo "Installing with sudo into $OPENSSL_DIR" >&2
  sudo tar -C "$OPENSSL_DIR" -xzf "$TMP_DIR/$TARBALL"
else
  tar -C "$OPENSSL_DIR" -xzf "$TMP_DIR/$TARBALL"
fi

if [ -x "$OPENSSL_DIR/bin/openssl" ]; then
  "$OPENSSL_DIR/bin/openssl" version -a || true
fi

echo "Installed OpenSSL into: $OPENSSL_DIR (source: $URL_TARBALL)"
echo
echo "To use outside nix:"
echo "  export OPENSSL_DIR=$OPENSSL_DIR"
echo "  export OPENSSL_STATIC=1 OPENSSL_NO_VENDOR=1"
echo "  export PKG_CONFIG_PATH=\"$OPENSSL_DIR/lib/pkgconfig:\$PKG_CONFIG_PATH\""
