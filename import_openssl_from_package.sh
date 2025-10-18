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
  echo "Usage: OPENSSL_DIR=/path bash $0 <os: linux|darwin|windows?> <arch: x86_64|arm64>" >&2
  echo "" >&2
  echo "Note: Use 'arm64' for Apple Silicon macOS (not 'aarch64')" >&2
  echo "      Use 'x86_64' for Intel/AMD64 architectures" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  bash $0 linux x86_64     # Linux on Intel/AMD" >&2
  echo "  bash $0 darwin arm64     # macOS on Apple Silicon" >&2
  echo "  bash $0 darwin x86_64    # macOS on Intel" >&2
  exit 1
fi

OS=$1
ARCH=$2
VERSION=3.1.2
BASE_URL=${BASE_URL:-https://package.cosmian.com/openssl/$VERSION}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Try new naming convention first (static-fips), fall back to old convention (glibc2.27) for Linux
if [ "$OS" = "linux" ]; then
  # For Linux, try the old glibc2.27 naming first as it's more likely to exist
  TARBALL="openssl-${VERSION}-${OS}-${ARCH}-glibc2.27.tar.gz"
  TARBALL_ALT="openssl-${VERSION}-${OS}-${ARCH}-static-fips.tar.gz"
else
  # For other platforms (darwin), use the new static-fips naming
  TARBALL="openssl-${VERSION}-${OS}-${ARCH}-static-fips.tar.gz"
  TARBALL_ALT="openssl-${VERSION}-${OS}-${ARCH}-glibc2.27.tar.gz"
fi

URL_TARBALL="$BASE_URL/$TARBALL"
URL_SHA="$BASE_URL/$TARBALL.sha256"

echo "Fetching $URL_TARBALL"
if ! curl -fsSL "$URL_TARBALL" -o "$TMP_DIR/$TARBALL"; then
  echo "Primary tarball not found, trying alternative naming..." >&2
  # Try alternative naming convention
  URL_TARBALL_ALT="$BASE_URL/$TARBALL_ALT"
  URL_SHA_ALT="$BASE_URL/$TARBALL_ALT.sha256"
  
  if ! curl -fsSL "$URL_TARBALL_ALT" -o "$TMP_DIR/$TARBALL_ALT"; then
    echo "Error: Failed to download both $URL_TARBALL and $URL_TARBALL_ALT" >&2
    echo "This may be due to incorrect OS/arch combination or the tarball not being available." >&2
    echo "" >&2
    echo "For macOS Apple Silicon, use: bash $0 darwin arm64" >&2
    echo "For macOS Intel, use: bash $0 darwin x86_64" >&2
    echo "For Linux AMD64, use: bash $0 linux x86_64" >&2
    exit 1
  fi
  
  # Use the alternative tarball that was found
  TARBALL="$TARBALL_ALT"
  URL_TARBALL="$URL_TARBALL_ALT"
  URL_SHA="$URL_SHA_ALT"
  echo "Found alternative tarball: $URL_TARBALL"
fi
echo "Fetching $URL_SHA"
curl -fsSL "$URL_SHA" -o "$TMP_DIR/$TARBALL.sha256"

pushd "$TMP_DIR" >/dev/null
# Extract just the hash from the downloaded .sha256 file and verify against our local file
EXPECTED_HASH=$(cut -d' ' -f1 "$TARBALL.sha256")
ACTUAL_HASH=$(sha256sum "$TARBALL" | cut -d' ' -f1)
if [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ]; then
  echo "$TARBALL: OK"
else
  echo "$TARBALL: FAILED" >&2
  echo "Expected: $EXPECTED_HASH" >&2
  echo "Actual:   $ACTUAL_HASH" >&2
  exit 1
fi
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
