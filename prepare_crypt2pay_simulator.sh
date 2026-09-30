#!/bin/bash
set -ex

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CRYPT2PAY_SIM_INSTANCE="${CRYPT2PAY_SIM_INSTANCE:-1}"
CRYPT2PAY_SIM_GROUP="${CRYPT2PAY_SIM_GROUP:-bnt}"
CRYPT2PAY_SIM_GID="${CRYPT2PAY_SIM_GID:-402}"
CRYPT2PAY_SIM_PID_FILE="${CRYPT2PAY_SIM_PID_FILE:-/tmp/crypt2pay-sim.pid}"

# bnt is a 32-bit ELF dynamically linked against ld-linux.so.2; install multiarch runtime if missing.
if [[ ! -e /lib/ld-linux.so.2 ]]; then
  sudo dpkg --add-architecture i386
  sudo apt-get update -qq
  sudo apt-get install -y libc6:i386
fi

# The simulator refuses to run unless launched by a user in group "c2p"/"bnt", or gid 402.
getent group "$CRYPT2PAY_SIM_GROUP" >/dev/null 2>&1 || sudo groupadd -g "$CRYPT2PAY_SIM_GID" "$CRYPT2PAY_SIM_GROUP"

CRYPT2PAY_SIM_BIN="$(find "$SCRIPT_DIR/simulator" -type f -name bnt | sort -V | tail -1)"
chmod +x "$CRYPT2PAY_SIM_BIN"

killall -9 bnt || true

# "-nX" selects instance X, whose crypto TLS interface listens on port 3000+X.
# Instance 1 (the default) behaves exactly like a Crypt2pay HSM in TEST mode.
sudo -g "$CRYPT2PAY_SIM_GROUP" "$CRYPT2PAY_SIM_BIN" -n"$CRYPT2PAY_SIM_INSTANCE" &
echo $! > "$CRYPT2PAY_SIM_PID_FILE"

CRYPT2PAY_SIM_TLS_PORT=$((3000 + CRYPT2PAY_SIM_INSTANCE))

# Wait for the crypto TLS interface to come up
for i in $(seq 1 30); do
  timeout 1 openssl s_client -connect "127.0.0.1:${CRYPT2PAY_SIM_TLS_PORT}" </dev/null >/dev/null 2>&1 && break
  if [[ "$i" -eq 30 ]]; then
    echo "crypt2pay simulator did not come up on port ${CRYPT2PAY_SIM_TLS_PORT}" >&2
    exit 1
  fi
  sleep 1
done

# Reuse the real HSM client setup, pointed at the local simulator instance instead of the VPN endpoint.
CRYPT2PAY_HOST=127.0.0.1 CRYPT2PAY_PORT="$CRYPT2PAY_SIM_TLS_PORT" "$SCRIPT_DIR/prepare_crypt2pay.sh"
