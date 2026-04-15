#!/bin/bash
set -ex

wget -q https://package.cosmian.com/ci/hsm-proteccio.tar.gz
tar -xzf hsm-proteccio.tar.gz
rm hsm-proteccio.tar.gz

sudo mkdir -p /etc/proteccio/
sudo cp hsm-proteccio/proteccio/etc/proteccio/* /etc/proteccio/
sudo cp hsm-proteccio/proteccio/lib/* /lib/
sudo cp hsm-proteccio/proteccio/usr/local/bin/* /usr/local/bin/

rm -rf hsm-proteccio

# Check HSM connectivity (non-fatal - tests will fail later if HSM is unreachable)
# Temporarily clear Nix OpenSSL environment to use system libraries for Proteccio
env -u LD_PRELOAD -u LD_LIBRARY_PATH -u OPENSSL_CONF -u OPENSSL_MODULES /usr/local/bin/nethsmstatus
