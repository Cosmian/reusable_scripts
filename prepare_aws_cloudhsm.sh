#!/usr/bin/env bash
set -euo pipefail

AWS_CLOUDHSM_PKCS11_LIB="${AWS_CLOUDHSM_PKCS11_LIB:-/opt/cloudhsm/lib/libcloudhsm_pkcs11.so}"
AWS_CLOUDHSM_CONFIGURE_PKCS11="${AWS_CLOUDHSM_CONFIGURE_PKCS11:-/opt/cloudhsm/bin/configure-pkcs11}"
AWS_CLOUDHSM_HSM_CA_CERT="${AWS_CLOUDHSM_HSM_CA_CERT:-/opt/cloudhsm/etc/customerCA.crt}"
AWS_CLOUDHSM_CONFIGURE_CLI="${AWS_CLOUDHSM_CONFIGURE_CLI:-/opt/cloudhsm/bin/configure-cli}"

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: required command '${command_name}' not found" >&2
    exit 1
  fi
}

install_aws_cloudhsm_pkcs11_client_ubuntu() {
  require_command curl
  require_command sudo

  local distro_dir
  local package_suffix
  case "${VERSION_ID:-}" in
    24.04)
      distro_dir="Noble"
      package_suffix="u24.04"
      ;;
    22.04)
      distro_dir="Jammy"
      package_suffix="u22.04"
      ;;
    20.04)
      distro_dir="Focal"
      package_suffix="u20.04"
      ;;
    18.04)
      distro_dir="Bionic"
      package_suffix="u18.04"
      ;;
    *)
      echo "ERROR: unsupported Ubuntu VERSION_ID='${VERSION_ID:-unknown}' for AWS CloudHSM PKCS#11 client install" >&2
      exit 1
      ;;
  esac

  local package_arch
  case "$(uname -m)" in
    x86_64) package_arch="amd64" ;;
    aarch64 | arm64) package_arch="arm64" ;;
    *)
      echo "ERROR: unsupported architecture '$(uname -m)' for AWS CloudHSM PKCS#11 client install" >&2
      exit 1
      ;;
  esac

  local package_path
  package_path="$(mktemp --suffix=.deb)"
  local package_url="https://s3.amazonaws.com/cloudhsmv2-software/CloudHsmClient/${distro_dir}/cloudhsm-pkcs11_latest_${package_suffix}_${package_arch}.deb"
  curl -fsSL "${package_url}" -o "${package_path}"
  sudo apt-get update
  sudo apt-get install -y "${package_path}"
  rm -f "${package_path}"
}

write_aws_cloudhsm_ca_certificate() {
  if [ -z "${AWS_CLOUDHSM_CA_CERT:-}" ]; then
    return 0
  fi

  require_command sudo
  printf '%s\n' "${AWS_CLOUDHSM_CA_CERT}" | sudo tee "${AWS_CLOUDHSM_HSM_CA_CERT}" >/dev/null
  sudo chmod 0644 "${AWS_CLOUDHSM_HSM_CA_CERT}"
}

install_aws_cloudhsm_pkcs11_client() {
  if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: AWS CloudHSM PKCS#11 client is supported only on Linux" >&2
    exit 1
  fi

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
  fi

  case "${ID:-}" in
    ubuntu) install_aws_cloudhsm_pkcs11_client_ubuntu ;;
    *)
      echo "ERROR: unsupported OS '${ID:-unknown}'. Install AWS CloudHSM PKCS#11 client SDK 5 before running this script" >&2
      exit 1
      ;;
  esac
}

CLOUDHSM_OPENVPN_PID_FILE="${CLOUDHSM_OPENVPN_PID_FILE:-/tmp/cloudhsm-openvpn.pid}"
CLOUDHSM_OPENVPN_CONF_FILE="${CLOUDHSM_OPENVPN_CONF_FILE:-/tmp/cloudhsm-openvpn.conf}"
CLOUDHSM_OPENVPN_LOG_FILE="${CLOUDHSM_OPENVPN_LOG_FILE:-/tmp/cloudhsm-openvpn.log}"

# GitHub-hosted runners have no network path to the HSM's private VPC IP. When
# direct TCP reachability fails and an AWS Client VPN profile is provided, start
# it so the PKCS#11 client's TLS connection to the HSM ENI has a route to follow.
# See crate/hsm/aws_cloudhsm/README.md for why this is needed (no public IP on
# the HSM, unlike Crypt2Pay/Proteccio).
maybe_start_cloudhsm_vpn() {
  if [ -z "${AWS_CLOUDHSM_HSM_IPS:-}" ]; then
    return 0
  fi
  local first_ip="${AWS_CLOUDHSM_HSM_IPS%% *}"

  if timeout 5 bash -c "echo >/dev/tcp/${first_ip}/2223" 2>/dev/null; then
    return 0
  fi

  if [ -z "${AWS_CLOUDHSM_OVPN_CONF:-}" ]; then
    echo "ERROR: HSM ${first_ip}:2223 is not reachable and AWS_CLOUDHSM_OVPN_CONF is not set" >&2
    exit 1
  fi

  require_command openvpn
  require_command sudo
  # sudo's secure_path ignores the Nix shell's PATH, so resolve the absolute
  # path to the Nix-provided openvpn binary before invoking it as root.
  local openvpn_bin
  openvpn_bin="$(command -v openvpn)"
  printf '%s\n' "${AWS_CLOUDHSM_OVPN_CONF}" >"${CLOUDHSM_OPENVPN_CONF_FILE}"
  sudo "${openvpn_bin}" --config "${CLOUDHSM_OPENVPN_CONF_FILE}" --daemon --writepid "${CLOUDHSM_OPENVPN_PID_FILE}" \
    --log "${CLOUDHSM_OPENVPN_LOG_FILE}"

  for _ in $(seq 1 30); do
    if timeout 5 bash -c "echo >/dev/tcp/${first_ip}/2223" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "ERROR: HSM ${first_ip}:2223 still unreachable after starting the Client VPN tunnel" >&2
  # The log is root-owned (written by the daemonized `sudo openvpn` process), so
  # a plain `-r`/`-s` test as the invoking non-root user silently reports false
  # even when the file has content. Read it through `sudo` unconditionally instead.
  echo "--- openvpn log (${CLOUDHSM_OPENVPN_LOG_FILE}) ---" >&2
  sudo cat "${CLOUDHSM_OPENVPN_LOG_FILE}" >&2 || echo "(no openvpn log found at ${CLOUDHSM_OPENVPN_LOG_FILE})" >&2
  exit 1
}

configure_aws_cloudhsm_pkcs11() {
  require_command sudo

  if [ ! -s "${AWS_CLOUDHSM_HSM_CA_CERT}" ]; then
    echo "ERROR: AWS CloudHSM HSM CA certificate not found at '${AWS_CLOUDHSM_HSM_CA_CERT}'" >&2
    echo "Set AWS_CLOUDHSM_HSM_CA_CERT to the trust anchor used to initialize the cluster." >&2
    exit 1
  fi

  local cluster_locator=()
  if [ -n "${AWS_CLOUDHSM_HSM_IPS:-}" ]; then
    read -r -a cluster_locator <<<"${AWS_CLOUDHSM_HSM_IPS}"
    cluster_locator=("-a" "${cluster_locator[@]}")
  else
    : "${AWS_CLOUDHSM_CLUSTER_ID:?AWS_CLOUDHSM_CLUSTER_ID is required when AWS_CLOUDHSM_HSM_IPS is not set}"
    : "${AWS_REGION:?AWS_REGION is required when AWS_CLOUDHSM_HSM_IPS is not set}"
    cluster_locator=("--cluster-id" "${AWS_CLOUDHSM_CLUSTER_ID}" "--region" "${AWS_REGION}")
  fi

  if [ -x "${AWS_CLOUDHSM_CONFIGURE_CLI}" ]; then
    sudo "${AWS_CLOUDHSM_CONFIGURE_CLI}" \
      "${cluster_locator[@]}" \
      --hsm-ca-cert "${AWS_CLOUDHSM_HSM_CA_CERT}" \
      --disable-key-availability-check \
      --log-type file \
      --log-file /opt/cloudhsm/run/cloudhsm-cli.log \
      --log-rotation daily \
      --log-level info
  fi

  sudo "${AWS_CLOUDHSM_CONFIGURE_PKCS11}" \
    "${cluster_locator[@]}" \
    --hsm-ca-cert "${AWS_CLOUDHSM_HSM_CA_CERT}" \
    --disable-key-availability-check \
    --log-type file \
    --log-file /opt/cloudhsm/run/cloudhsm-pkcs11.log \
    --log-rotation daily \
    --log-level info
}

: "${AWS_CLOUDHSM_CU_USERNAME:?AWS_CLOUDHSM_CU_USERNAME is required}"
: "${AWS_CLOUDHSM_CU_PASSWORD:?AWS_CLOUDHSM_CU_PASSWORD is required}"

install_aws_cloudhsm_pkcs11_client
write_aws_cloudhsm_ca_certificate
maybe_start_cloudhsm_vpn
configure_aws_cloudhsm_pkcs11

export AWS_CLOUDHSM_PKCS11_LIB
export HSM_USER_PASSWORD="${AWS_CLOUDHSM_CU_USERNAME}:${AWS_CLOUDHSM_CU_PASSWORD}"
if [ -n "${AWS_CLOUDHSM_SLOT_ID:-}" ]; then
  export HSM_SLOT_ID="${AWS_CLOUDHSM_SLOT_ID}"
fi