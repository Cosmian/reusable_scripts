#!/bin/bash
set -ex

wget -q https://package.cosmian.com/ci/hsm-crypt2pay.tar.gz
tar -xzf hsm-crypt2pay.tar.gz
rm hsm-crypt2pay.tar.gz

sudo mkdir -p /etc/c2p/
sudo cp -R c2p/etc/c2p/* /etc/c2p/
sudo cp c2p/lib/* /lib/

rm -rf c2p

# install the CA certificate
cd /etc/c2p/
sudo ./installca -i ./ca.der ssl

# check that the CA certificate is installed correctly
sudo ./installca -l ./ssl/

# Logging configuration
LOG_DIR="/etc/c2p/logs"
sudo sed -i "s|<TraceLevel>.*</TraceLevel>|<TraceLevel>debug functions parameters pkcs hsm</TraceLevel>|" c2p.xml
sudo sed -i "s|<TraceFile>.*</TraceFile>|<TraceFile>+$LOG_DIR/c2p.trc</TraceFile>|" c2p.xml

# Create a new 256-bit AES key
sudo ./p11tool -genkey -keyalg aes -keysize 256 -shared /lib/libpkcs11c2p.so -slot 0 -verbose