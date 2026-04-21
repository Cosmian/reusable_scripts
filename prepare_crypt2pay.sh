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

# install CA into the directory referenced by <Authorities> in c2p.xml
# The installca tool resolves paths relative to cwd, so we cd into /etc/c2p first.
cd /etc/c2p
sudo ./installca -i ca.der ssl/authorities
sudo ./installca -l ssl/authorities

# ── Bridge CA workaround ──────────────────────────────────────────────────
# The ca.der shipped in the C2P package was re-issued with a new subject DN
# (O=Eviden, OU=Trustway, CN=CA-C2P) but the HSM server certificate still
# references the OLD issuer DN (CN=CA-C2P only).  The C2P SSL code looks up
# CAs under  <Authorities>/<server-cert-dgst>/<cert-hash>/cert.ca  where
# <server-cert-dgst> is a proprietary hash of the server certificate.
# Because the subject DN changed, the installca tool stores the CA under a
# different first-level hash and the SSL lookup fails.
#
# Workaround: create a "bridge" CA certificate that has:
#   - Subject: CN=CA-C2P  (matches the server cert issuer DN)
#   - Public key: identical to the real CA  (signature verification succeeds)
#   - CA:TRUE + keyCertSign extensions
# Then install it so the C2P SSL lookup finds it via the server cert's dgst.

# Extract the real CA public key
openssl x509 -inform DER -in ca.der -pubkey -noout > /tmp/real_ca_pubkey.pem

# Get the real CA's Subject Key Identifier for the bridge cert
REAL_SKI=$(openssl x509 -inform DER -in ca.der -text -noout \
  | grep -A1 "Subject Key Identifier" | tail -1 | tr -d ' ')

# Create a bridge CA with the old DN, real public key, and matching SKI
openssl genrsa -out /tmp/bridge_key.pem 2048 2>/dev/null
openssl req -new -key /tmp/bridge_key.pem -subj "/CN=CA-C2P" \
  -out /tmp/bridge.csr 2>/dev/null

cat > /tmp/bridge_ext.cnf << EXTEOF
[v3_ca]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=${REAL_SKI}
authorityKeyIdentifier=keyid:always
EXTEOF

openssl x509 -req -in /tmp/bridge.csr \
  -signkey /tmp/bridge_key.pem \
  -force_pubkey /tmp/real_ca_pubkey.pem \
  -days 3650 \
  -extfile /tmp/bridge_ext.cnf \
  -extensions v3_ca \
  -out /tmp/bridge_ca.pem 2>/dev/null

openssl x509 -in /tmp/bridge_ca.pem -outform DER -out /tmp/bridge_ca.der

# Install the bridge CA via installca (goes into <subject_hash>/...)
sudo ./installca -i /tmp/bridge_ca.der ssl/authorities

# The C2P SSL code looks up CAs under <dgst>/<cert_hash>/cert.ca where <dgst>
# is computed from the server certificate.  We need to connect to the HSM to
# obtain the server cert and compute the dgst.  Instead, we pre-compute it:
# the HSM at 193.251.15.196:3001 presents cert with dgst jVbkUrN2gem9gcItyD8SX3z-rk1
DGST="jVbkUrN2gem9gcItyD8SX3z-rk1"
# Retrieve the actual dgst by connecting to the HSM (falls back to the
# pre-computed value if the HSM is not yet reachable at this stage).
if timeout 5 openssl s_client -connect 193.251.15.196:3001 </dev/null 2>/dev/null \
     | openssl x509 -outform DER -out /tmp/hsm_server.der 2>/dev/null; then
  # installca -t prints the expected CA lookup path
  COMPUTED_DGST=$(sudo ./installca -t /tmp/hsm_server.der ssl/authorities 2>&1 \
    | grep -oP '(?<=ssl/authorities/)[^/]+' | head -1) || true
  if [ -n "$COMPUTED_DGST" ]; then
    DGST="$COMPUTED_DGST"
  fi
fi

# Find the bridge cert hash subdir that installca just created
BRIDGE_SUBDIR=$(find ssl/authorities/ -path "*/jUgMybXul5qgGsYkAa1Ia6u2lyo/*/cert.ca" \
  -printf '%h\n' 2>/dev/null | head -1)
CERT_HASH_DIR=$(basename "$BRIDGE_SUBDIR")

# Create the dgst-indexed directory with the bridge CA
sudo mkdir -p "ssl/authorities/${DGST}/${CERT_HASH_DIR}"
sudo cp "${BRIDGE_SUBDIR}/cert.ca" "ssl/authorities/${DGST}/${CERT_HASH_DIR}/cert.ca"

echo "Bridge CA installed at ssl/authorities/${DGST}/${CERT_HASH_DIR}/cert.ca"
sudo ./installca -l ssl/authorities

rm -f /tmp/bridge_key.pem /tmp/bridge.csr /tmp/bridge_ext.cnf \
      /tmp/bridge_ca.pem /tmp/bridge_ca.der /tmp/real_ca_pubkey.pem \
      /tmp/hsm_server.der

cd -

# Fix C2P port: the HSM SSL service runs on port 3001 (port 3002 is firewalled)
sudo sed -i "s|<Port>3002</Port>|<Port>3001</Port>|" /etc/c2p/c2p.xml

# Logging config
sudo sed -i "s|<TraceLevel>.*</TraceLevel>|<TraceLevel>debug functions parameters pkcs hsm</TraceLevel>|" /etc/c2p/c2p.xml
sudo sed -i "s|<TraceFile>.*</TraceFile>|<TraceFile>+/etc/c2p/logs/c2p.trc</TraceFile>|" /etc/c2p/c2p.xml
