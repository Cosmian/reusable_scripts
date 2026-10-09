#!/usr/bin/env bash
set -euo pipefail

AZURE_CLOUD_HSM_SDK_VERSION="${AZURE_CLOUD_HSM_SDK_VERSION:-2.0.2.5}"
AZURE_CLOUD_HSM_SDK_DEB_URL="${AZURE_CLOUD_HSM_SDK_DEB_URL:-https://github.com/microsoft/MicrosoftAzureCloudHSM/releases/download/AzureCloudHSM-ClientSDK-${AZURE_CLOUD_HSM_SDK_VERSION}/AzureCloudHSM-ClientSDK-OpenSSL3-${AZURE_CLOUD_HSM_SDK_VERSION}.deb}"
AZURE_CLOUD_HSM_BIN_DIR="${AZURE_CLOUD_HSM_BIN_DIR:-/opt/azurecloudhsm/bin}"
AZURE_CLOUD_HSM_PKCS11_LIB="${AZURE_CLOUD_HSM_PKCS11_LIB:-/opt/azurecloudhsm/lib64/libazcloudhsm_pkcs11.so}"

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: required command '${command_name}' not found" >&2
    exit 1
  fi
}

# Installs the Azure Cloud HSM Client SDK (.deb) under /opt/azurecloudhsm.
install_azure_cloud_hsm_client() {
  if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: Azure Cloud HSM client is supported only on Linux" >&2
    exit 1
  fi
  if [ -x "${AZURE_CLOUD_HSM_BIN_DIR}/azcloudhsm_client" ]; then
    return 0
  fi

  require_command curl
  require_command sudo

  local package_path
  package_path="$(mktemp --suffix=.deb)"
  curl -fsSL "${AZURE_CLOUD_HSM_SDK_DEB_URL}" -o "${package_path}"
  sudo dpkg --install "${package_path}" || sudo apt-get install -y -f
  rm -f "${package_path}"
}

# PO.crt is how the PKCS#11 library locates the client configuration (see the
# Azure Cloud HSM PKCS#11 Integration Guide, "How does the PKCS#11 library know
# how to find the client configuration").
write_po_certificate() {
  : "${AZURE_CLOUD_HSM_PO_CERT:?AZURE_CLOUD_HSM_PO_CERT is required}"
  require_command sudo
  printf '%s\n' "${AZURE_CLOUD_HSM_PO_CERT}" | sudo tee "${AZURE_CLOUD_HSM_BIN_DIR}/PO.crt" >/dev/null
  sudo chmod 0644 "${AZURE_CLOUD_HSM_BIN_DIR}/PO.crt"
}

# azcloudhsm_resource.cfg must point at the partition's Private Link FQDN
# (hsm1.chsm-<resourcename>-<uniquestring>.privatelink.cloudhsm.azure.net), but
# that zone only resolves through Azure's VNet-linked private DNS: an external
# VPN client has no route to that resolver, and the azcloudhsm_client's own
# lookup bypasses /etc/hosts. When AZURE_CLOUD_HSM_HSM_IP is known, write the
# literal IP instead — getaddrinfo() short-circuits on a numeric address, so
# this sidesteps DNS resolution entirely.
write_resource_config() {
  : "${AZURE_CLOUD_HSM_HOSTNAME:?AZURE_CLOUD_HSM_HOSTNAME is required}"
  require_command sudo
  local server_address="${AZURE_CLOUD_HSM_HSM_IP:-${AZURE_CLOUD_HSM_HOSTNAME}}"
  printf '{\n    "servers": [\n    {\n        "hostname" : "%s"\n    }]\n}\n' "${server_address}" |
    sudo tee "${AZURE_CLOUD_HSM_BIN_DIR}/azcloudhsm_resource.cfg" >/dev/null
}

AZURE_CLOUD_HSM_OPENVPN_PID_FILE="${AZURE_CLOUD_HSM_OPENVPN_PID_FILE:-/tmp/azure-cloudhsm-openvpn.pid}"
AZURE_CLOUD_HSM_OPENVPN_CONF_FILE="${AZURE_CLOUD_HSM_OPENVPN_CONF_FILE:-/tmp/azure-cloudhsm-openvpn.conf}"
AZURE_CLOUD_HSM_OPENVPN_LOG_FILE="${AZURE_CLOUD_HSM_OPENVPN_LOG_FILE:-/tmp/azure-cloudhsm-openvpn.log}"

# The *.privatelink.cloudhsm.azure.net name only resolves inside the Azure VNet;
# map it to the known private IP so the client daemon can dial it by hostname.
maybe_map_hostname_to_ip() {
  if [ -z "${AZURE_CLOUD_HSM_HSM_IP:-}" ]; then
    return 0
  fi
  require_command sudo
  if ! grep -q "${AZURE_CLOUD_HSM_HOSTNAME}" /etc/hosts 2>/dev/null; then
    printf '%s %s\n' "${AZURE_CLOUD_HSM_HSM_IP}" "${AZURE_CLOUD_HSM_HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
  fi
}

# The Azure Cloud HSM client/management protocol listens on 2225 (confirmed via
# azcloudhsm_mgmt_util: "Connecting to 'server 0': hostname '<ip>', port 2225");
# it is not an HTTPS endpoint, so 443 is never open on the HSM nodes.
AZURE_CLOUD_HSM_PORT="${AZURE_CLOUD_HSM_PORT:-2225}"

# GitHub-hosted runners have no route to the HSM's private VNet IP; start a VPN
# tunnel when direct reachability fails, mirroring AWS CloudHSM's
# maybe_start_cloudhsm_vpn in prepare_aws_cloudhsm.sh.
maybe_start_azure_cloud_hsm_vpn() {
  if [ -z "${AZURE_CLOUD_HSM_HSM_IP:-}" ]; then
    return 0
  fi

  if timeout 5 bash -c "echo >/dev/tcp/${AZURE_CLOUD_HSM_HSM_IP}/${AZURE_CLOUD_HSM_PORT}" 2>/dev/null; then
    return 0
  fi

  if [ -z "${AZURE_CLOUD_HSM_OVPN_CONF:-}" ]; then
    echo "ERROR: HSM ${AZURE_CLOUD_HSM_HSM_IP}:${AZURE_CLOUD_HSM_PORT} is not reachable and AZURE_CLOUD_HSM_OVPN_CONF is not set" >&2
    exit 1
  fi

  require_command openvpn
  require_command sudo
  local openvpn_bin
  openvpn_bin="$(command -v openvpn)"
  printf '%s\n' "${AZURE_CLOUD_HSM_OVPN_CONF}" >"${AZURE_CLOUD_HSM_OPENVPN_CONF_FILE}"
  sudo "${openvpn_bin}" --config "${AZURE_CLOUD_HSM_OPENVPN_CONF_FILE}" \
    --daemon --writepid "${AZURE_CLOUD_HSM_OPENVPN_PID_FILE}" --log "${AZURE_CLOUD_HSM_OPENVPN_LOG_FILE}"

  for _ in $(seq 1 60); do
    if timeout 5 bash -c "echo >/dev/tcp/${AZURE_CLOUD_HSM_HSM_IP}/${AZURE_CLOUD_HSM_PORT}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "ERROR: HSM ${AZURE_CLOUD_HSM_HSM_IP}:${AZURE_CLOUD_HSM_PORT} still unreachable after starting the VPN tunnel" >&2
  sudo cat "${AZURE_CLOUD_HSM_OPENVPN_LOG_FILE}" >&2 ||
    echo "(no openvpn log found at ${AZURE_CLOUD_HSM_OPENVPN_LOG_FILE})" >&2
  exit 1
}

# The PKCS#11 library talks to azcloudhsm_client over a local socket; without
# this daemon running, C_Initialize fails with a connection error.
start_azure_cloud_hsm_client_daemon() {
  require_command sudo
  if pgrep -f "azcloudhsm_client" >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck disable=SC2024 # redirect intentionally runs as the invoking user, not root,
  # so the log file stays readable without sudo on failure.
  (cd "${AZURE_CLOUD_HSM_BIN_DIR}" && sudo ./azcloudhsm_client azcloudhsm_resource.cfg >/tmp/azcloudhsm_client.log 2>&1 &)
  for _ in $(seq 1 20); do
    if pgrep -f "azcloudhsm_client" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: azcloudhsm_client daemon did not start" >&2
  cat /tmp/azcloudhsm_client.log >&2 2>/dev/null || true
  exit 1
}

: "${HSM_USER_PASSWORD:?HSM_USER_PASSWORD is required (format <user>:<password>)}"

install_azure_cloud_hsm_client
write_po_certificate
write_resource_config
maybe_map_hostname_to_ip
maybe_start_azure_cloud_hsm_vpn
start_azure_cloud_hsm_client_daemon

export AZURE_CLOUD_HSM_PKCS11_LIB
