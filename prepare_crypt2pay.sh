#!/bin/bash
set -ex

wget -q https://package.cosmian.com/ci/hsm-crypt2pay.tar.gz
tar -xzf hsm-crypt2pay.tar.gz
rm hsm-crypt2pay.tar.gz

sudo mkdir -p /etc/c2p/
sudo cp -R c2p/etc/c2p/* /etc/c2p/
sudo cp c2p/lib/* /usr/lib/

rm -rf c2p

# Fix permissions
sudo chown -R root:root /etc/c2p
sudo chmod -R 755 /etc/c2p

# Create logs dir
sudo mkdir -p /etc/c2p/logs
sudo chmod 777 /etc/c2p/logs

cd /etc/c2p/

# install CA
sudo ./installca -i ./ca.der ssl
sudo ./installca -l ./ssl/

# Logging config
sudo sed -i "s|<TraceLevel>.*</TraceLevel>|<TraceLevel>debug functions parameters pkcs hsm</TraceLevel>|" c2p.xml
sudo sed -i "s|<TraceFile>.*</TraceFile>|<TraceFile>+/etc/c2p/logs/c2p.trc</TraceFile>|" c2p.xml

# Test HSM
sudo ./p11tool -shared libpkcs11c2p.so -genkey -usage sw -keyalg aes -keysize 256

cd -