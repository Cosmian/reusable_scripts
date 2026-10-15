#!/usr/bin/env bash
set -euo pipefail

AZURE_CLOUD_HSM_SDK_VERSION="${AZURE_CLOUD_HSM_SDK_VERSION:-2.0.2.5}"
AZURE_CLOUD_HSM_SDK_DEB_URL="${AZURE_CLOUD_HSM_SDK_DEB_URL:-https://github.com/microsoft/MicrosoftAzureCloudHSM/releases/download/AzureCloudHSM-ClientSDK-${AZURE_CLOUD_HSM_SDK_VERSION}/AzureCloudHSM-ClientSDK-OpenSSL3-${AZURE_CLOUD_HSM_SDK_VERSION}.deb}"
AZURE_CLOUD_HSM_BIN_DIR="${AZURE_CLOUD_HSM_BIN_DIR:-/opt/azurecloudhsm/bin}"
# Where the shipped azcloudhsm_client.cfg's "e2e_owner_crt_path" expects PO.crt to live;
# writing it under AZURE_CLOUD_HSM_BIN_DIR instead leaves the client daemon unable to
# validate the E2E owner certificate, so C_Initialize later fails with CKR_GENERAL_ERROR.
AZURE_CLOUD_HSM_CERT_DIR="${AZURE_CLOUD_HSM_CERT_DIR:-/opt/azurecloudhsm/cert}"
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
  printf '%s\n' "${AZURE_CLOUD_HSM_PO_CERT}" | sudo tee "${AZURE_CLOUD_HSM_CERT_DIR}/PO.crt" >/dev/null
  sudo chmod 0644 "${AZURE_CLOUD_HSM_CERT_DIR}/PO.crt"
}

# Derives the per-node Private Link FQDN (hsm<index>.<same-suffix>) from the
# primary AZURE_CLOUD_HSM_HOSTNAME (hsm1.<suffix>), since all nodes in one
# cluster share the same <suffix> and only the leading "hsmN" alias differs —
# confirmed against this cluster's own private DNS zone records (hsm1/hsm2/hsm3
# all under the same "<cluster>-<uniquestring>.privatelink.cloudhsm.azure.net"
# suffix). Falls back to the raw IP when no hostname is configured at all.
cluster_node_hostname() {
  local index="$1"
  local ip="$2"
  if [ -z "${AZURE_CLOUD_HSM_HOSTNAME:-}" ]; then
    printf '%s' "${ip}"
    return 0
  fi
  printf '%s' "${AZURE_CLOUD_HSM_HOSTNAME}" | sed -E "s/^hsm[0-9]+\./hsm${index}./"
}

# azcloudhsm_resource.cfg must point at each partition's Private Link FQDN
# (hsm<N>.<cluster>-<uniquestring>.privatelink.cloudhsm.azure.net) rather than
# a bare IP: azcloudhsm_mgmt_util only ever activated this cluster's 3 nodes
# successfully when driven by that exact per-node hostname (see the
# hsm_changepswd session transcript), never by raw IP. Resolution is handled
# locally via /etc/hosts (maybe_map_hostname_to_ip below) since the
# *.privatelink.cloudhsm.azure.net zone only resolves through Azure's
# VNet-linked private DNS, which an external VPN client has no route to.
#
# A single "servers" entry is not enough: with only one node listed, the
# client's own peer-discovery (triggered after login) hands back addresses
# that are not reachable from outside Azure's backend fabric at all — observed
# as an endless "daemontoserver network error, closing conn." reconnect loop
# and "[create_object_min_nodes] Required number of servers(3) not available"
# on every keypair generation. Set AZURE_CLOUD_HSM_HSM_IPS to all of the
# cluster's private-endpoint IPs, in hsm1/hsm2/hsm3 order (list them with
# `az network private-dns record-set a list --zone-name
# privatelink.cloudhsm.azure.net`), so every node is listed explicitly instead
# of relying on that discovery step.
write_resource_config() {
  require_command sudo
  local servers_json=""
  if [ -n "${AZURE_CLOUD_HSM_HSM_IPS:-}" ]; then
    local ip
    local index=1
    for ip in ${AZURE_CLOUD_HSM_HSM_IPS}; do
      local entry_hostname
      entry_hostname="$(cluster_node_hostname "${index}" "${ip}")"
      [ -n "${servers_json}" ] && servers_json+=",\n"
      servers_json+="    {\n        \"hostname\" : \"${entry_hostname}\"\n    }"
      index=$((index + 1))
    done
  else
    : "${AZURE_CLOUD_HSM_HOSTNAME:?AZURE_CLOUD_HSM_HOSTNAME is required}"
    local server_address="${AZURE_CLOUD_HSM_HSM_IP:-${AZURE_CLOUD_HSM_HOSTNAME}}"
    servers_json="    {\n        \"hostname\" : \"${server_address}\"\n    }"
  fi
  printf '{\n    "servers": [\n%b]\n}\n' "${servers_json}" |
    sudo tee "${AZURE_CLOUD_HSM_BIN_DIR}/azcloudhsm_resource.cfg" >/dev/null
  # Values are masked by CI if they match a configured secret, but the entry
  # count (brace/comma structure) still shows whether the multi-node branch
  # above actually ran, which digit-masked log output elsewhere cannot confirm.
  echo "--- azcloudhsm_resource.cfg (values may be masked) ---" >&2
  sudo cat "${AZURE_CLOUD_HSM_BIN_DIR}/azcloudhsm_resource.cfg" >&2
}

AZURE_CLOUD_HSM_OPENVPN_PID_FILE="${AZURE_CLOUD_HSM_OPENVPN_PID_FILE:-/tmp/azure-cloudhsm-openvpn.pid}"
AZURE_CLOUD_HSM_OPENVPN_CONF_FILE="${AZURE_CLOUD_HSM_OPENVPN_CONF_FILE:-/tmp/azure-cloudhsm-openvpn.conf}"
AZURE_CLOUD_HSM_OPENVPN_LOG_FILE="${AZURE_CLOUD_HSM_OPENVPN_LOG_FILE:-/tmp/azure-cloudhsm-openvpn.log}"

# The *.privatelink.cloudhsm.azure.net name only resolves inside the Azure VNet;
# map every node's hostname (not just the primary one — write_resource_config
# now writes a hostname per node) to its known private IP so the client daemon
# can dial each one, since its own lookup bypasses /etc/hosts for names it
# can't resolve otherwise.
maybe_map_hostname_to_ip() {
  if [ -z "${AZURE_CLOUD_HSM_HOSTNAME:-}" ]; then
    return 0
  fi
  require_command sudo
  if [ -n "${AZURE_CLOUD_HSM_HSM_IPS:-}" ]; then
    local ip
    local index=1
    for ip in ${AZURE_CLOUD_HSM_HSM_IPS}; do
      local entry_hostname
      entry_hostname="$(cluster_node_hostname "${index}" "${ip}")"
      if ! grep -q "${entry_hostname}" /etc/hosts 2>/dev/null; then
        printf '%s %s\n' "${ip}" "${entry_hostname}" | sudo tee -a /etc/hosts >/dev/null
      fi
      index=$((index + 1))
    done
    return 0
  fi
  if [ -n "${AZURE_CLOUD_HSM_HSM_IP:-}" ] && ! grep -q "${AZURE_CLOUD_HSM_HOSTNAME}" /etc/hosts 2>/dev/null; then
    printf '%s %s\n' "${AZURE_CLOUD_HSM_HSM_IP}" "${AZURE_CLOUD_HSM_HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
  fi
}

# The Azure Cloud HSM client/management protocol listens on 2225 (confirmed via
# azcloudhsm_mgmt_util: "Connecting to 'server 0': hostname '<ip>', port 2225");
# it is not an HTTPS endpoint, so 443 is never open on the HSM nodes.
AZURE_CLOUD_HSM_PORT="${AZURE_CLOUD_HSM_PORT:-2225}"

# The daemon's inter-node "daemontoserver" cluster protocol (used to sync
# membership/quorum after the initial handshake) listens on a separate port
# from the client-facing 2225: confirmed via the daemon log's own
# cluster_info_timeout broadcasts, e.g. "Cluster Info: server[<ip>],
# port[2224], ... state[enabled]". A node can be reachable on 2225 yet refuse
# 2224 (errno 111), which the client only discovers after claiming the
# daemon is ready, deep inside a PKCS#11 call (CKR_SLOT_ID_INVALID /
# CKR_FUNCTION_FAILED) — hence checking it explicitly up front below.
AZURE_CLOUD_HSM_CLUSTER_PORT="${AZURE_CLOUD_HSM_CLUSTER_PORT:-2224}"

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

# Fails fast with a precise, actionable diagnostic instead of letting the
# daemon silently reconnect-loop and the test fail deep inside
# C_GenerateKeyPair with a bare CKR_FUNCTION_FAILED. Checks every IP listed in
# AZURE_CLOUD_HSM_HSM_IPS (the same list written into azcloudhsm_resource.cfg)
# on the mgmt port, since they all live on the one private-endpoint subnet the
# VPN route already reaches for the primary node.
verify_azure_cloud_hsm_cluster_reachable() {
  if [ -z "${AZURE_CLOUD_HSM_HSM_IPS:-}" ]; then
    echo "AZURE_CLOUD_HSM_HSM_IPS not set: skipping multi-node reachability check" >&2
    return 0
  fi
  local unreachable=()
  local cluster_unreachable=()
  local ip
  for ip in ${AZURE_CLOUD_HSM_HSM_IPS}; do
    if ! timeout 5 bash -c "echo >/dev/tcp/${ip}/${AZURE_CLOUD_HSM_PORT}" 2>/dev/null; then
      unreachable+=("${ip}")
    fi
    if ! timeout 5 bash -c "echo >/dev/tcp/${ip}/${AZURE_CLOUD_HSM_CLUSTER_PORT}" 2>/dev/null; then
      cluster_unreachable+=("${ip}")
    fi
  done
  if [ ${#unreachable[@]} -gt 0 ]; then
    echo "ERROR: ${#unreachable[@]} Azure Cloud HSM cluster node(s) unreachable on port ${AZURE_CLOUD_HSM_PORT}: ${unreachable[*]}" >&2
    echo "Cluster operations (e.g. key generation) require quorum across all nodes; widen the VPN route/NSG to cover these private IPs." >&2
    exit 1
  fi
  if [ ${#cluster_unreachable[@]} -gt 0 ]; then
    echo "ERROR: ${#cluster_unreachable[@]} Azure Cloud HSM cluster node(s) unreachable on port ${AZURE_CLOUD_HSM_CLUSTER_PORT}: ${cluster_unreachable[*]}" >&2
    echo "This is the daemon's inter-node cluster protocol port, distinct from ${AZURE_CLOUD_HSM_PORT}; the daemon will still report itself ready, then every PKCS#11 call fails (e.g. CKR_SLOT_ID_INVALID) because quorum never forms. Widen the VPN route/NSG to cover port ${AZURE_CLOUD_HSM_CLUSTER_PORT} on these private IPs." >&2
    exit 1
  fi
  echo "All configured Azure Cloud HSM cluster nodes reachable on ports ${AZURE_CLOUD_HSM_PORT} and ${AZURE_CLOUD_HSM_CLUSTER_PORT}" >&2
}

# The PKCS#11 library talks to azcloudhsm_client over a local socket; without
# this daemon running, C_Initialize fails with a connection error. The daemon
# process can exist (pgrep succeeds) before it has finished its own E2E
# handshake with every HSM node in the cluster; wait for that log line too,
# not just the process, to avoid a race against the PKCS#11 test's
# C_Initialize call (observed as CKR_GENERAL_ERROR when too eager).
#
# A single readiness-marker match is not enough: the daemon logs one such
# line per cluster node as it connects (confirmed via azcloudhsm_mgmt_util
# against this cluster: "E2E enabled on server 0/1/2"), so matching on the
# first occurrence lets the test start while nodes 1/2 are still syncing —
# observed as an immediate (sub-second) CKR_FUNCTION_FAILED on the first
# multi-node operation (e.g. C_GenerateKeyPair) once node 0 alone is ready.
AZURE_CLOUD_HSM_CLUSTER_SIZE="${AZURE_CLOUD_HSM_CLUSTER_SIZE:-3}"
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
      break
    fi
    sleep 1
  done
  if ! pgrep -f "azcloudhsm_client" >/dev/null 2>&1; then
    echo "ERROR: azcloudhsm_client daemon did not start" >&2
    cat /tmp/azcloudhsm_client.log >&2 2>/dev/null || true
    exit 1
  fi

  for _ in $(seq 1 30); do
    local enabled_count
    enabled_count="$(grep -ci "E2E enabled" /tmp/azcloudhsm_client.log 2>/dev/null || true)"
    enabled_count="${enabled_count:-0}"
    if [ "${enabled_count}" -ge "${AZURE_CLOUD_HSM_CLUSTER_SIZE}" ]; then
      # The "E2E enabled" marker per node confirms the transport handshake,
      # but the daemon's internal slot/mechanism table can lag slightly
      # behind it: observed as an immediate (sub-second) CKR_SLOT_ID_INVALID
      # on the very first PKCS#11 call (C_GetMechanismList) even though all
      # 3 nodes had already logged "E2E enabled". Apply the same grace
      # period used by the fallback path below before declaring ready.
      sleep 10
      return 0
    fi
    sleep 1
  done
  # The expected per-node count was never reached within the window (e.g. the
  # exact log wording differs across SDK versions): fall back to any single
  # readiness marker plus a grace period, rather than failing outright.
  for _ in $(seq 1 20); do
    if grep -qi "E2E enabled\|session.*established\|ready" /tmp/azcloudhsm_client.log 2>/dev/null; then
      sleep 10
      return 0
    fi
    sleep 1
  done
  sleep 10
}

: "${HSM_USER_PASSWORD:?HSM_USER_PASSWORD is required (format <user>:<password>)}"

install_azure_cloud_hsm_client
write_po_certificate
write_resource_config
maybe_map_hostname_to_ip
maybe_start_azure_cloud_hsm_vpn
verify_azure_cloud_hsm_cluster_reachable
start_azure_cloud_hsm_client_daemon

export AZURE_CLOUD_HSM_PKCS11_LIB
