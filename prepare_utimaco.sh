#!/bin/bash
set -ex

# Fallback to wget if nix is not available (CI environments)
wget -q https://package.cosmian.com/ci/hsm-utimaco-simulator.tar.xz

killall -9 bl_sim5 || true
echo -n Extracting compressed archive...
tar -xf hsm-utimaco-simulator.tar.xz
rm hsm-utimaco-simulator.tar.xz
./hsm-simulator/sim5_linux/bin/bl_sim5 -h -o -d ./hsm-simulator/sim5_linux/devices &

sleep 5

# Place PKCS#11 library and config in a user-writable, persistent location
UTIMACO_ETC="$PWD/.utimaco"
mkdir -p "$UTIMACO_ETC"
cp ./hsm-simulator/libcs_pkcs11_R3.so "$UTIMACO_ETC/libcs_pkcs11_R3.so"
export UTIMACO_PKCS11_LIB="$UTIMACO_ETC/libcs_pkcs11_R3.so"
cp ./hsm-simulator/cs_pkcs11_R3.cfg "$UTIMACO_ETC/"
chmod 644 "$UTIMACO_ETC/cs_pkcs11_R3.cfg"
printf "[Global]\nLogpath = /tmp\nLogging = 3\n[CryptoServer]\nDevice = 3001@localhost\n" >"$UTIMACO_ETC/cs_pkcs11_R3.cfg"
export CS_PKCS11_R3_CFG="$UTIMACO_ETC/cs_pkcs11_R3.cfg"

cd ./hsm-simulator/Administration
# set the SO PIN to 11223344
./p11tool2 Slot=0 login=ADMIN,./key/ADMIN_SIM.key InitToken=11223344
# Change the SO PIN to 12345678
./p11tool2 Slot=0 LoginSO=11223344 SetPin=11223344,12345678
# Set the User PIN to 11223344
./p11tool2 Slot=0 LoginSO=12345678 InitPin=11223344
# Change the User PIN to 12345678
./p11tool2 Slot=0 LoginUser=11223344 SetPin=11223344,12345678
./p11tool2 Slot=0 GetSlotInfo
cd ../..

rm -rf hsm-simulator
