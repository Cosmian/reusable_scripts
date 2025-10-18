#!/usr/bin/env bash

# Build OpenSSL 3.1.2 via Nix and export it as a tarball that can be reused
# on other machines without rebuilding. The tarball layout matches
# OPENSSL_DIR expectations: include/, lib/, ssl/, bin/, lib/ossl-modules/.
#
# Output:
#   Linux:  artifacts/openssl-3.1.2-${OS}-${ARCH}-glibc2.27.tar.gz
#   Darwin: artifacts/openssl-3.1.2-${OS}-${ARCH}-static-fips.tar.gz
#
# Usage:
#   bash .github/reusable_scripts/export_openssl_tarball.sh
#   # then scp artifacts/openssl-3.1.2-*.tar.gz user@host:/path

set -euo pipefail

HERE_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE_DIR/../.." && pwd)

cd "$REPO_ROOT"

if ! command -v nix-build >/dev/null 2>&1; then
  echo "Error: nix-build not found in PATH. Please install Nix and try again." >&2
  exit 1
fi

# Use current nixpkgs - the derivation will handle glibc compatibility
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(uname -m)

# Build the OpenSSL derivation using the same approach as shell.nix
# On macOS ARM64, import nixpkgs for aarch64-darwin so we get a native toolchain
if [ "$OS" = "darwin" ] && [ "$HOST_ARCH" = "arm64" ]; then
  echo "Using aarch64-darwin nixpkgs for native ARM64 build..."
  EXPR="let pkgs = import <nixpkgs> { system = \"aarch64-darwin\"; }; in pkgs.callPackage \"$REPO_ROOT/nix/openssl-3_1_2-fips.nix\" {}"
else
  EXPR="let pkgs = import <nixpkgs> {}; in pkgs.callPackage \"$REPO_ROOT/nix/openssl-3_1_2-fips.nix\" {}"
fi

STORE_PATH=$(nix-build -E "$EXPR" --no-out-link)
echo "Built OpenSSL at: $STORE_PATH"

# Detect the actual architecture of the built OpenSSL binary
# This is more reliable than uname -m since Nix might cross-compile
if [ "$OS" = "darwin" ]; then
  # On macOS, use lipo to detect the actual architecture
  if command -v lipo >/dev/null 2>&1 && [ -f "$STORE_PATH/lib/libcrypto.a" ]; then
    DETECTED_ARCH=$(lipo -info "$STORE_PATH/lib/libcrypto.a" 2>/dev/null | sed -n 's/^Non-fat file: .* is architecture: //p')
    if [ -n "$DETECTED_ARCH" ]; then
      # Map architecture names to match naming convention
      case "$DETECTED_ARCH" in
      x86_64) ARCH="x86_64" ;;
      arm64) ARCH="arm64" ;;
      *) ARCH="$DETECTED_ARCH" ;;
      esac
    else
      # Fallback to uname if lipo fails
      ARCH=$(uname -m)
    fi
  else
    ARCH=$(uname -m)
  fi
else
  # On Linux, check the ELF architecture
  if command -v file >/dev/null 2>&1 && [ -f "$STORE_PATH/lib/libcrypto.a" ]; then
    # Extract the first object file from the archive to check its architecture
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT
    cd "$TEMP_DIR"
    ar x "$STORE_PATH/lib/libcrypto.a" 2>/dev/null || true
    FIRST_OBJ=$(find . -name "*.o" | head -1)
    if [ -n "$FIRST_OBJ" ]; then
      FILE_OUTPUT=$(file "$FIRST_OBJ")
      if echo "$FILE_OUTPUT" | grep -q "x86-64"; then
        ARCH="x86_64"
      elif echo "$FILE_OUTPUT" | grep -q "aarch64"; then
        ARCH="aarch64"
      else
        # Fallback to uname if file detection fails
        ARCH=$(uname -m)
      fi
    else
      ARCH=$(uname -m)
    fi
    cd "$REPO_ROOT"
  else
    ARCH=$(uname -m)
  fi
fi

echo "Detected OpenSSL architecture: $ARCH"

mkdir -p "$REPO_ROOT/artifacts"

# Use platform-appropriate naming convention
if [ "$OS" = "linux" ]; then
  # For Linux, use glibc2.27 naming to match existing package server convention
  TARBALL="$REPO_ROOT/artifacts/openssl-3.1.2-${OS}-${ARCH}-glibc2.27.tar.gz"
else
  # For other platforms (darwin), use static-fips naming
  TARBALL="$REPO_ROOT/artifacts/openssl-3.1.2-${OS}-${ARCH}-static-fips.tar.gz"
fi

# Pack the output tree as-is to preserve layout expected by OPENSSL_DIR
tar -C "$STORE_PATH" -czf "$TARBALL" .

sha256sum "$TARBALL" >"$TARBALL.sha256"
SUM=$(cut -d' ' -f1 "$TARBALL.sha256")
echo "Created: $TARBALL"
echo "SHA256:  $SUM"

# Optional: upload to package server via scp
SCP_UPLOAD=${SCP_UPLOAD:-0}
SCP_USER_HOST=${SCP_USER_HOST:-cosmian@package.cosmian.com}
SCP_DEST_DIR=${SCP_DEST_DIR:-/mnt/package/openssl/3.1.2}
PUBLIC_BASE_URL=${PUBLIC_BASE_URL:-https://package.cosmian.com/openssl/3.1.2}

if [ "$SCP_UPLOAD" = "1" ]; then
  echo "Uploading artifacts to $SCP_USER_HOST:$SCP_DEST_DIR ..."
  ssh -o StrictHostKeyChecking=accept-new "$SCP_USER_HOST" "mkdir -p '$SCP_DEST_DIR'"
  scp "$TARBALL" "$TARBALL.sha256" "$SCP_USER_HOST:$SCP_DEST_DIR/"
  BASENAME=$(basename "$TARBALL")
  echo "Uploaded:"
  echo "  $SCP_USER_HOST:$SCP_DEST_DIR/$BASENAME"
  echo "  $SCP_USER_HOST:$SCP_DEST_DIR/$BASENAME.sha256"
  echo "Public URLs (if mapped):"
  echo "  $PUBLIC_BASE_URL/$BASENAME"
  echo "  $PUBLIC_BASE_URL/$BASENAME.sha256"
else
  echo "To upload, run (example):"
  echo "  SCP_UPLOAD=1 bash .github/reusable_scripts/export_openssl_tarball.sh"
  echo "or manually:"
  echo "  scp $TARBALL $TARBALL.sha256 cosmian@package.cosmian.com:/mnt/package/openssl/3.1.2/"
  echo "Then fetch from: https://package.cosmian.com/openssl/3.1.2/$(basename "$TARBALL")"
fi
