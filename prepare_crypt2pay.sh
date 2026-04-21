#!/bin/bash
set -ex

wget -q https://package.cosmian.com/ci/hsm-crypt2pay.tar.gz
tar -xzf hsm-crypt2pay.tar.gz
rm hsm-crypt2pay.tar.gz

sudo mkdir -p /etc/c2p/
sudo cp -R c2p/etc/c2p/* /etc/c2p/
sudo cp c2p/lib/* /lib/

rm -rf c2p

# Fix permissions
# /etc/c2p must be world-writable: the C2P library creates subdirectories
# (e.g. QuickStart_*) at runtime as the non-root user running the KMS process.
sudo chown -R root:root /etc/c2p
sudo chmod -R 777 /etc/c2p

#Create logs directory
sudo mkdir -p /etc/c2p/logs

# install CA
sudo /etc/c2p/installca -i /etc/c2p/ca.der ssl
sudo /etc/c2p/installca -l /etc/c2p/ssl/

# Logging config
sudo sed -i "s|<TraceLevel>.*</TraceLevel>|<TraceLevel>debug functions parameters pkcs hsm</TraceLevel>|" /etc/c2p/c2p.xml
sudo sed -i "s|<TraceFile>.*</TraceFile>|<TraceFile>+/etc/c2p/logs/c2p.trc</TraceFile>|" /etc/c2p/c2p.xml