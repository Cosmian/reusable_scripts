#!/usr/bin/env bash

# Build OpenSSL 3.1.2 in the repo's nix-shell (glibc<=2.28) and export it as a tarball
# that can be reused on other machines without rebuilding. The tarball layout matches
# OPENSSL_DIR expectations: include/, lib/, ssl/, bin/, lib/ossl-modules/.
#
# Output: artifacts/openssl-3.1.2-${OS}-${ARCH}-glibc2.27.tar.gz
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

# Pin nixpkgs to match shell.nix glibc (2.27) environment unless overridden
NIXPKGS_PIN_URL=${NIXPKGS_PIN_URL:-https://github.com/NixOS/nixpkgs/archive/refs/heads/nixos-19.03.tar.gz}

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

# Build the OpenSSL derivation via a nix expression that imports the pinned nixpkgs
EXPR="let pkgs = import (fetchTarball \"$NIXPKGS_PIN_URL\") {}; in with pkgs; callPackage \"$REPO_ROOT/nix/openssl-3_1_2-fips.nix\" {}"

STORE_PATH=$(nix-build -E "$EXPR" --no-out-link)
echo "Built OpenSSL at: $STORE_PATH"

mkdir -p "$REPO_ROOT/artifacts"
TARBALL="$REPO_ROOT/artifacts/openssl-3.1.2-${OS}-${ARCH}-glibc2.27.tar.gz"

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
