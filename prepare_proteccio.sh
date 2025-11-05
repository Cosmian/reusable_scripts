#!/bin/bash
set -ex

wget -q https://package.cosmian.com/ci/hsm-proteccio.tar.gz
tar -xzf hsm-proteccio.tar.gz
rm hsm-proteccio.tar.gz

mkdir -p /etc/proteccio/
sudo cp proteccio/etc/proteccio/* /etc/proteccio/
sudo cp proteccio/lib/* /lib/
sudo cp proteccio/usr/local/bin/* /usr/local/bin/

rm -rf proteccio

/usr/local/bin/nethsmstatus
