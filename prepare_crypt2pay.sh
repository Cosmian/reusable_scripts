#!/bin/bash
set -ex

wget -q https://package.cosmian.com/ci/hsm-crypt2pay.tar.gz
tar -xzf hsm-crypt2pay.tar.gz
rm hsm-crypt2pay.tar.gz

sudo mkdir -p /etc/c2p/
sudo cp -R c2p/etc/* /etc/
sudo cp c2p/lib/* /lib/

rm -rf c2p

# install the CA certificate
cd /etc/c2p/
./installca -i ./ca.der ssl

# check that the CA certificate is installed correctly
./installca -l ./ssl/


# Update c2p.xml cert path
CA_PATH="/etc/c2p/ssl"
sed -i "s|<Authorities>.*</Authorities>|<Authorities>$CA_PATH</Authorities>|" c2p.xml

# Logging configuration
LOG_DIR="/etc/c2p/logs"
sed -i "s|<TraceLevel>.*</TraceLevel>|<TraceLevel>debug functions parameters pkcs hsm</TraceLevel>|" c2p.xml
sed -i "s|<TraceFile>.*</TraceFile>|<TraceFile>+$LOG_DIR/c2p.trc</TraceFile>|" c2p.xml

export C2P_CONF=/etc/c2p/c2p.xml

# Force fixed HSM IP
export C2P_HSM_IP="193.251.82.208"
C2P_XML_FILE="/etc/c2p/c2p.xml"
sed -i "s#<IP>.*</IP>#<IP>${C2P_HSM_IP}</IP>#" "$C2P_XML_FILE"

# Create a new 256-bit AES key
./p11tool -genkey -keyalg aes -keysize 256 -shared /lib/libpkcs11c2p.so -slot 1 -verbose