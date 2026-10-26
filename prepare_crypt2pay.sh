#!/bin/bash
set -e

CRYPT2PAY_HOST="${CRYPT2PAY_HOST:-193.251.15.196}"
CRYPT2PAY_PORT="${CRYPT2PAY_PORT:-3001}"
CRYPT2PAY_OPENVPN_PID_FILE="${CRYPT2PAY_OPENVPN_PID_FILE:-/tmp/crypt2pay-openvpn.pid}"
CRYPT2PAY_OPENVPN_CONF_FILE="${CRYPT2PAY_OPENVPN_CONF_FILE:-/tmp/crypt2pay-openvpn.conf}"

# Validate optional mTLS/extra-CA inputs before anything is downloaded or overwritten.
if [[ -n "${CRYPT2PAY_EXTRA_CA_DER:-}" && ! -r "$CRYPT2PAY_EXTRA_CA_DER" ]]; then
  echo "CRYPT2PAY_EXTRA_CA_DER is not a readable file: $CRYPT2PAY_EXTRA_CA_DER" >&2
  exit 1
fi
if [[ -n "${CRYPT2PAY_CLIENT_P12:-}" ]]; then
  : "${CRYPT2PAY_CLIENT_P12_PASSWORD:?CRYPT2PAY_CLIENT_P12_PASSWORD must be set with CRYPT2PAY_CLIENT_P12}"
  if [[ ! -r "$CRYPT2PAY_CLIENT_P12" ]]; then
    echo "CRYPT2PAY_CLIENT_P12 is not a readable file: $CRYPT2PAY_CLIENT_P12" >&2
    exit 1
  fi
  # The password is spliced into a sed replacement and an XML attribute.
  if [[ "$CRYPT2PAY_CLIENT_P12_PASSWORD" == *[\&\|\\\"\<\>]* ]]; then
    echo "CRYPT2PAY_CLIENT_P12_PASSWORD must not contain any of: & | \\ \" < >" >&2
    exit 1
  fi
fi

if [[ -n "${OVPN_CONF:-}" ]] && ! timeout 5 openssl s_client -connect "${CRYPT2PAY_HOST}:${CRYPT2PAY_PORT}" </dev/null >/dev/null 2>&1; then
  OPENVPN_BIN="$(command -v openvpn)"
  printf "%s\n" "$OVPN_CONF" > "$CRYPT2PAY_OPENVPN_CONF_FILE"
  sudo "$OPENVPN_BIN" --config "$CRYPT2PAY_OPENVPN_CONF_FILE" --daemon --writepid "$CRYPT2PAY_OPENVPN_PID_FILE"
  # The daemon returns before the tunnel is up: wait until the HSM answers, or the tests race the VPN.
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/${CRYPT2PAY_HOST}/${CRYPT2PAY_PORT}") 2>/dev/null && break
    sleep 1
  done
  (exec 3<>"/dev/tcp/${CRYPT2PAY_HOST}/${CRYPT2PAY_PORT}") 2>/dev/null || {
    echo "Crypt2Pay HSM ${CRYPT2PAY_HOST}:${CRYPT2PAY_PORT} unreachable after starting the VPN" >&2
    exit 1
  }
fi
set -x

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
# the HSM at ${CRYPT2PAY_HOST}:${CRYPT2PAY_PORT} presents cert with dgst jVbkUrN2gem9gcItyD8SX3z-rk1
DGST="jVbkUrN2gem9gcItyD8SX3z-rk1"
# Retrieve the actual dgst by connecting to the HSM (falls back to the
# pre-computed value if the HSM is not yet reachable at this stage).
if timeout 5 openssl s_client -connect "${CRYPT2PAY_HOST}:${CRYPT2PAY_PORT}" </dev/null 2>/dev/null \
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

# Fix C2P target: packaged config defaults to port 3002, but test endpoint can
# be reached through VPN or another forwarded address.
sudo sed -i "s|<IP>.*</IP>|<IP>${CRYPT2PAY_HOST}</IP>|" /etc/c2p/c2p.xml
sudo sed -i "s|<Port>.*</Port>|<Port>${CRYPT2PAY_PORT}</Port>|" /etc/c2p/c2p.xml

# Optional: HSM whose TLS cert is signed by another CA (e.g. KMC-AC_Root),
# and which requires mutual TLS with a PKCS#12 client identity.
if [[ -n "${CRYPT2PAY_EXTRA_CA_DER:-}" ]]; then
  sudo cp "$CRYPT2PAY_EXTRA_CA_DER" /etc/c2p/extra_ca.der
  (cd /etc/c2p && sudo ./installca -i extra_ca.der ssl/authorities && sudo ./installca -l ssl/authorities)
fi
if [[ -n "${CRYPT2PAY_CLIENT_P12:-}" ]]; then
  CRYPT2PAY_CLIENT_P12_NAME="$(basename "$CRYPT2PAY_CLIENT_P12")"
  sudo cp "$CRYPT2PAY_CLIENT_P12" "/etc/c2p/${CRYPT2PAY_CLIENT_P12_NAME}"
  # The KMS runs as a non-root user; sudo cp keeps the source's 0600 mode otherwise.
  sudo chmod 644 "/etc/c2p/${CRYPT2PAY_CLIENT_P12_NAME}"
  sudo sed -i "s|<Authorities>\(.*\)</Authorities>|<Authorities>\1</Authorities>\n    <privateKey format=\"pkcs12\" password=\"${CRYPT2PAY_CLIENT_P12_PASSWORD}\">${CRYPT2PAY_CLIENT_P12_NAME}</privateKey>|" /etc/c2p/c2p.xml
fi

# Logging config
sudo sed -i "s|<TraceLevel>.*</TraceLevel>|<TraceLevel>debug functions parameters pkcs hsm</TraceLevel>|" /etc/c2p/c2p.xml
sudo sed -i "s|<TraceFile>.*</TraceFile>|<TraceFile>+/etc/c2p/logs/c2p.trc</TraceFile>|" /etc/c2p/c2p.xml
