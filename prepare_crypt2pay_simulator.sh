#!/bin/bash
set -ex

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CRYPT2PAY_SIM_INSTANCE="${CRYPT2PAY_SIM_INSTANCE:-1}"
CRYPT2PAY_SIM_GROUP="${CRYPT2PAY_SIM_GROUP:-bnt}"
CRYPT2PAY_SIM_GID="${CRYPT2PAY_SIM_GID:-402}"
CRYPT2PAY_SIM_PID_FILE="${CRYPT2PAY_SIM_PID_FILE:-/tmp/crypt2pay-sim.pid}"
CRYPT2PAY_SIM_ADMIN_LOGIN="${CRYPT2PAY_SIM_ADMIN_LOGIN:-admin}"
CRYPT2PAY_SIM_ADMIN_PASSWORD="${CRYPT2PAY_SIM_ADMIN_PASSWORD:-root}"
CRYPT2PAY_SIM_CLIENT_P12_PASSWORD="${CRYPT2PAY_SIM_CLIENT_P12_PASSWORD:-Test20250128}"
# Appliance default is 1 concurrent crypto connection; raise it so p11tool checks
# and the KMS process don't get refused once they overlap.
CRYPT2PAY_SIM_MAXCON="${CRYPT2PAY_SIM_MAXCON:-8}"

killall -9 bnt || true

wget -q https://package.cosmian.com/ci/hsm-crypt2pay-simulator.tar.xz
tar -xJf hsm-crypt2pay-simulator.tar.xz
rm hsm-crypt2pay-simulator.tar.xz
chmod +x crypt2pay-simulator/bnt

# bnt is a 32-bit ELF dynamically linked against ld-linux.so.2; install multiarch runtime if missing.
if [[ ! -e /lib/ld-linux.so.2 ]]; then
  sudo dpkg --add-architecture i386
  sudo apt-get update -qq
  sudo apt-get install -y libc6:i386
fi

# The simulator refuses to run unless launched by a user in group "c2p"/"bnt", or gid 402.
getent group "$CRYPT2PAY_SIM_GROUP" >/dev/null 2>&1 || sudo groupadd -g "$CRYPT2PAY_SIM_GID" "$CRYPT2PAY_SIM_GROUP"

# "-nX" selects instance X: crypto TLS listens on port 3000+X, admin HTTP on 8180+X.
sudo -g "$CRYPT2PAY_SIM_GROUP" ./crypt2pay-simulator/bnt -n"$CRYPT2PAY_SIM_INSTANCE" &
echo $! > "$CRYPT2PAY_SIM_PID_FILE"

CRYPT2PAY_SIM_TLS_PORT=$((3000 + CRYPT2PAY_SIM_INSTANCE))
CRYPT2PAY_SIM_ADMIN_PORT=$((8180 + CRYPT2PAY_SIM_INSTANCE))
CRYPT2PAY_SIM_ADMIN_URL="http://127.0.0.1:${CRYPT2PAY_SIM_ADMIN_PORT}"

# Plain TCP check: openssl exits non-zero on bnt's TLS port even once it's up.
wait_for_port() {
  local port="$1"
  for i in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      exec 3<&- 3>&-
      return 0
    fi
    sleep 1
  done
  echo "crypt2pay simulator did not come up on port ${port}" >&2
  exit 1
}

wait_for_port "$CRYPT2PAY_SIM_ADMIN_PORT"

# ── Personalize the fresh instance ──────────────────────────────────────────
# Out of the box only one generic option is active and every PKCS#11 key
# generation mechanism is rejected (CKERR_MECHANISM_INVALID). Activate the
# crypto options, select test master key 3210, and load its KDK.
CRYPT2PAY_SIM_COOKIES="$(mktemp)"
curl -sf -c "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/login.cgi" \
  -d "referer=/" -d "do=yes" -d "login=${CRYPT2PAY_SIM_ADMIN_LOGIN}" -d "passwd=${CRYPT2PAY_SIM_ADMIN_PASSWORD}" -o /dev/null

# Crypto connection parameters default to maxcon=1; a second concurrent
# connection is refused at the application layer ("refused secure connection").
# This form rejects a partial submission (e.g. "Cannot change SSL/TLS protocol
# setting" if tls13/tls12 are omitted), so fetch the current values and
# resubmit every field unchanged except maxcon.
CRYPT2PAY_SIM_TCPIP_HTML="$(curl -sf -b "$CRYPT2PAY_SIM_COOKIES" "${CRYPT2PAY_SIM_ADMIN_URL}/en/syst_tcpip")"
tcpip_value() { grep -oP "name=\"$1\"[^>]*value=\"\K[^\"]*" <<<"$CRYPT2PAY_SIM_TCPIP_HTML" | head -1; }
tcpip_checked() { printf '%s' "$CRYPT2PAY_SIM_TCPIP_HTML" | grep -Pzoq "name=\"$1\"[\s\S]*?checked"; }
CRYPT2PAY_SIM_TCPIP_ARGS=(-d do=yes)
for f in addr0_0 addr0_1 addr0_2 addr0_3 mask0_0 mask0_1 mask0_2 mask0_3 dgw_0 dgw_1 dgw_2 dgw_3; do
  CRYPT2PAY_SIM_TCPIP_ARGS+=(-d "${f}=$(tcpip_value "$f")")
done
CRYPT2PAY_SIM_SSL_AUTH="$(grep -Pzo '(?s)<select name="ssl_tls_auth">.*?</select>' <<<"$CRYPT2PAY_SIM_TCPIP_HTML" | tr -d '\0' | grep -oP 'value="\K[0-9]+(?=" selected)')" || true
CRYPT2PAY_SIM_TCPIP_ARGS+=(-d "ssl_tls_auth=${CRYPT2PAY_SIM_SSL_AUTH}")
if tcpip_checked tls13; then CRYPT2PAY_SIM_TCPIP_ARGS+=(-d tls13=on); fi
if tcpip_checked tls12; then CRYPT2PAY_SIM_TCPIP_ARGS+=(-d tls12=on); fi
CRYPT2PAY_SIM_TCPIP_ARGS+=(-d "maxcon=${CRYPT2PAY_SIM_MAXCON}" -d "Valider= Submit ")
curl -sf -b "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/en/syst_tcpip.cgi" \
  "${CRYPT2PAY_SIM_TCPIP_ARGS[@]}" -o /dev/null

curl -sf -b "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/en/appli_option.cgi" \
  -d "do=yes" -d "basic=on" -d "encrypt=on" -d "multi_c=on" -d "pkcs11=on" -d "test=on" \
  -d "no_bnt_tst=on" -d "km2bntx_aes=on" -d "ValiderOption=Submit" -o /dev/null

curl -sf -b "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/en/tool_load_keys.cgi" \
  -F "file_name=@crypt2pay-simulator/certs/Equipement_3210_20231114.kdk" -o /dev/null

# Box's own mutual-TLS identity, signed by the new CA (replaces the self-signed
# CN=C2P_TEMP cert the box boots with).
curl -sf -b "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/en/netsec_key.cgi" \
  -F "do=yes" -F "file_name=@crypt2pay-simulator/certs/C2P-Equip_3210_TLS.user" -o /dev/null
curl -sf -b "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/en/netsec_cert.cgi" \
  -F "do=yes" -F "file_name=@crypt2pay-simulator/certs/C2P-Equip_3210_TLS.cert" -o /dev/null
curl -sf -b "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/en/netsec_cert.cgi" \
  -d "do=yes" -d "activate=s" -o /dev/null
curl -sf -b "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/en/netsec_cert.cgi" \
  -d "do=yes" -d "activate=c" -o /dev/null

# Reboot (process restart only; confirmed non-destructive, does not wipe keys)
# so the new options/master key/certificate take effect.
curl -sf -b "$CRYPT2PAY_SIM_COOKIES" -X POST "${CRYPT2PAY_SIM_ADMIN_URL}/en/appli_boot.cgi" \
  -d "do=yes" -d "part=A" -o /dev/null
rm -f "$CRYPT2PAY_SIM_COOKIES"

wait_for_port "$CRYPT2PAY_SIM_TLS_PORT"

# Reuse the real HSM client setup, pointed at the local simulator instance instead of the VPN endpoint.
CRYPT2PAY_HOST=127.0.0.1 CRYPT2PAY_PORT="$CRYPT2PAY_SIM_TLS_PORT" "$SCRIPT_DIR/prepare_crypt2pay.sh"

# prepare_crypt2pay.sh only installs the original CA via its bridge-CA workaround.
# Without the new CA and the client's own mutual-TLS certificate, every PKCS#11
# key-generation mechanism is rejected (CKERR_MECHANISM_INVALID) even though the
# session itself logs in fine.
sudo cp crypt2pay-simulator/certs/CertificatAC.der /etc/c2p/
sudo cp crypt2pay-simulator/certs/USER_API-TEST_modern.p12 /etc/c2p/
(cd /etc/c2p && sudo ./installca -i CertificatAC.der ssl/authorities)
sudo sed -i "s|<Authorities>\(.*\)</Authorities>|<Authorities>\1</Authorities>\n    <privateKey format=\"pkcs12\" password=\"${CRYPT2PAY_SIM_CLIENT_P12_PASSWORD}\">USER_API-TEST_modern.p12</privateKey>|" /etc/c2p/c2p.xml

rm -rf crypt2pay-simulator
