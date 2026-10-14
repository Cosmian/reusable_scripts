#!/usr/bin/env bash
# Install the Thales Luna Client runtime and its NTLS configuration for the KMS (hsm_model = "luna").
#
# The Thales Luna Client is proprietary and is not downloaded: pass the Thales tarball and the
# configuration delivered by the HSM administrator. Works on a host (uses sudo when not root) and
# in a container image build (run as root). Without LUNA_CONFIG, only the client runtime is
# installed (container image whose configuration is mounted at runtime, e.g. from a Secret).
#
# Required environment:
#   LUNA_CLIENT_TAR   Thales Luna Client tarball (610-000397-*_SW_Linux_Luna_Client_*.tar)
# Configuration (all required when LUNA_CONFIG is set):
#   LUNA_CONFIG       configuration from the HSM administrator: a .zip, or a directory, containing
#                     cert/server/, configData/ and data/ (partition and client identities)
#   LUNA_CLIENT_CERT  client certificate registered on the appliance (`vtl createCert` output)
#   LUNA_CLIENT_KEY   private key of LUNA_CLIENT_CERT
#   LUNA_SERVER       address of the Luna appliance (Chrystoki.conf ServerName00)
# Optional environment:
#   LUNA_SERVER_CERT  server certificate file name in cert/server/ (default: ${LUNA_SERVER}.pem)
#   LUNA_ROOT         installation directory (default: /usr/safenet/lunaclient)
#   LUNA_CONF_DIR     directory receiving Chrystoki.conf (default: /etc); for another directory,
#                     start the KMS with ChrystokiConfigurationPath=<LUNA_CONF_DIR>
#   LUNA_OWNER        user running the KMS, owner of the files (default: invoking user)
#   LUNA_SKIP_VERIFY  1 to skip `vtl verify` (e.g. image build without access to the appliance)
set -euo pipefail

: "${LUNA_CLIENT_TAR:?Thales Luna Client tarball path is required}"
if [ -n "${LUNA_CONFIG:-}" ]; then
  : "${LUNA_CLIENT_CERT:?registered client certificate path is required}"
  : "${LUNA_CLIENT_KEY:?client private key path is required}"
  : "${LUNA_SERVER:?Luna appliance address is required}"
  LUNA_SERVER_CERT="${LUNA_SERVER_CERT:-${LUNA_SERVER}.pem}"
fi
LUNA_ROOT="${LUNA_ROOT:-/usr/safenet/lunaclient}"
LUNA_CONF_DIR="${LUNA_CONF_DIR:-/etc}"
LUNA_OWNER="${LUNA_OWNER:-${SUDO_USER:-$(id -un)}}"
# Runtime packages: PKCS#11 library, STC soft token, vtl (+ openssl.cnf), lunacm
LUNA_PACKAGES=(libcryptoki safenet-softtoken_client vtl lunacm)

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

for cmd in rpm2cpio cpio tar; do
  command -v "${cmd}" >/dev/null || {
    echo "ERROR: ${cmd} is required (Debian/Ubuntu: apt-get install rpm2cpio cpio)" >&2
    exit 1
  }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Extract the runtime RPMs of the Thales tarball into LUNA_ROOT.
install_client() {
  local rpm_dir pkg rpm
  tar -xf "${LUNA_CLIENT_TAR}" -C "${TMP_DIR}"
  rpm_dir="$(dirname "$(find "${TMP_DIR}" -name 'libcryptoki-*.x86_64.rpm' | head -n 1)")"
  [ -d "${rpm_dir}" ] || {
    echo "ERROR: no libcryptoki RPM in ${LUNA_CLIENT_TAR}" >&2
    exit 1
  }
  mkdir -p "${TMP_DIR}/root"
  for pkg in "${LUNA_PACKAGES[@]}"; do
    rpm="$(find "${rpm_dir}" -maxdepth 1 -name "${pkg}-[0-9]*.x86_64.rpm" | head -n 1)"
    [ -n "${rpm}" ] || {
      echo "ERROR: ${pkg} RPM not found in ${rpm_dir}" >&2
      exit 1
    }
    (cd "${TMP_DIR}/root" && rpm2cpio "${rpm}" | cpio -idm --quiet)
  done
  ${SUDO} mkdir -p "${LUNA_ROOT}"
  ${SUDO} cp -a "${TMP_DIR}/root/usr/safenet/lunaclient/." "${LUNA_ROOT}/"
  # The RPMs restrict libSoftToken.so to root and the hsmusers group created by the Thales
  # installer: libraries and tools hold no secret, make them usable by the KMS user.
  ${SUDO} chmod -R a+rX "${LUNA_ROOT}/lib" "${LUNA_ROOT}/bin"
}

# Copy the administrator configuration (certificates, STC token, identities) and the client cert.
install_config() {
  local config_dir="${LUNA_CONFIG}" server_dir
  if [ -f "${LUNA_CONFIG}" ]; then
    command -v unzip >/dev/null || {
      echo "ERROR: unzip is required to read ${LUNA_CONFIG}" >&2
      exit 1
    }
    unzip -q "${LUNA_CONFIG}" -d "${TMP_DIR}/config"
    config_dir="${TMP_DIR}/config"
  fi
  server_dir="$(find "${config_dir}" -type d -path '*/cert/server' | head -n 1)"
  [ -f "${server_dir}/${LUNA_SERVER_CERT}" ] || {
    echo "ERROR: ${LUNA_SERVER_CERT} not found in the cert/server directory of ${LUNA_CONFIG}" >&2
    exit 1
  }
  config_dir="$(dirname "$(dirname "${server_dir}")")"
  ${SUDO} mkdir -p "${LUNA_ROOT}/cert/server" "${LUNA_ROOT}/cert/client"
  ${SUDO} cp -a "${server_dir}/." "${LUNA_ROOT}/cert/server/"
  ${SUDO} cp -a "${config_dir}/configData" "${config_dir}/data" "${LUNA_ROOT}/"
  ${SUDO} cp "${LUNA_CLIENT_CERT}" "${LUNA_ROOT}/cert/client/ClientNameCert.pem"
  ${SUDO} cp "${LUNA_CLIENT_KEY}" "${LUNA_ROOT}/cert/client/ClientNameKey.pem"
  ${SUDO} chown -R "${LUNA_OWNER}" "${LUNA_ROOT}"
  # The administrator archive may ship read-only directories; the STC token database is updated.
  ${SUDO} chmod -R u+w "${LUNA_ROOT}"
  ${SUDO} chmod 600 "${LUNA_ROOT}/cert/client/ClientNameKey.pem"
}

# Write the Chrystoki.conf used by libCryptoki2_64.so for a single appliance.
write_chrystoki_conf() {
  ${SUDO} mkdir -p "${LUNA_CONF_DIR}"
  ${SUDO} tee "${LUNA_CONF_DIR}/Chrystoki.conf" >/dev/null <<EOF
Chrystoki2 = {
   LibUNIX64 = ${LUNA_ROOT}/lib/libCryptoki2_64.so;
}

Luna = {
  DefaultTimeOut = 500000;
  PEDTimeout1 = 100000;
  PEDTimeout2 = 200000;
  PEDTimeout3 = 20000;
  KeypairGenTimeOut = 2700000;
  CloningCommandTimeOut = 300000;
  CommandTimeOutPedSet = 720000;
}

LunaSA Client = {
   ReceiveTimeout = 20000;
   SSLConfigFile = ${LUNA_ROOT}/bin/openssl.cnf;
   ServerCAFile = ${LUNA_ROOT}/cert/server/${LUNA_SERVER_CERT};
   ClientCertFile = ${LUNA_ROOT}/cert/client/ClientNameCert.pem;
   ClientPrivKeyFile = ${LUNA_ROOT}/cert/client/ClientNameKey.pem;
   NetClient = 1;
   TCPKeepAlive = 1;
   ServerName00 = ${LUNA_SERVER};
   ServerPort00 = 5656;
}

Secure Trusted Channel = {
   ClientTokenLib = ${LUNA_ROOT}/lib/libSoftToken.so;
   SoftTokenDir = ${LUNA_ROOT}/configData/token;
   ClientIdentitiesDir = ${LUNA_ROOT}/data/client_identities;
   PartitionIdentitiesDir = ${LUNA_ROOT}/data/partition_identities;
}
EOF
  ${SUDO} chmod 644 "${LUNA_CONF_DIR}/Chrystoki.conf"
}

install_client
if [ -z "${LUNA_CONFIG:-}" ]; then
  echo "Luna Client runtime installed in ${LUNA_ROOT} (no configuration)"
  exit 0
fi
install_config
write_chrystoki_conf

if [ "${LUNA_SKIP_VERIFY:-0}" != "1" ]; then
  ChrystokiConfigurationPath="${LUNA_CONF_DIR}" "${LUNA_ROOT}/bin/vtl" verify
fi
echo "Luna Client installed in ${LUNA_ROOT}, Chrystoki.conf in ${LUNA_CONF_DIR}"
