#!/bin/bash
set -ex

wget -q https://package.cosmian.com/ci/hsm-proteccio.tar.gz

mkdir -p /etc/proteccio/
cp proteccio/etc/proteccio/* /etc/proteccio/
cp proteccio/lib/* /lib/
cp proteccio/usr/local/bin/* /usr/local/bin/

rm -rf proteccio

/usr/local/bin/nethsmstatus
