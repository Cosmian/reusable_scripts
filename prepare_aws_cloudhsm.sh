#!/usr/bin/env bash
# Prepare the AWS CloudHSM PKCS#11 client to connect to the persistent CI cluster.
#
# This script must be *sourced* (not executed), because it exports AWS_CLOUDHSM_PKCS11_LIB
# and HSM_USER_PASSWORD for the calling mise task / Rust test harness.
#
# Required environment variables (see crate/hsm/aws_cloudhsm/README.md for provisioning):
#   AWS_CLOUDHSM_CLUSTER_ID   - the persistent CI cluster ID
#   AWS_CLOUDHSM_CU_USERNAME  - the dedicated CI Crypto User name
#   AWS_CLOUDHSM_CU_PASSWORD  - the CI Crypto User password
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION - reused generic CI AWS credentials,
#     used only for the read-only `aws cloudhsmv2 describe-clusters` API call.
set -euo pipefail
source "${MISE_CONFIG_ROOT}/.mise/lib/common.sh"

: "${AWS_CLOUDHSM_CLUSTER_ID:?AWS_CLOUDHSM_CLUSTER_ID must be set (see crate/hsm/aws_cloudhsm/README.md)}"
: "${AWS_CLOUDHSM_CU_USERNAME:?AWS_CLOUDHSM_CU_USERNAME must be set}"
: "${AWS_CLOUDHSM_CU_PASSWORD:?AWS_CLOUDHSM_CU_PASSWORD must be set}"

require_cmd aws "The AWS CLI is required to fetch the CloudHSM cluster CA certificate."
require_cmd dpkg "dpkg is required to install the AWS CloudHSM PKCS#11 client package."

CLOUDHSM_LIB="/opt/cloudhsm/lib/libcloudhsm_pkcs11.so"
TMP_DEB=""
CA_CERT=""
cleanup() {
  [ -n "${TMP_DEB}" ] && rm -f "${TMP_DEB}"
  [ -n "${CA_CERT}" ] && rm -f "${CA_CERT}"
}
trap cleanup EXIT

if [ ! -f "${CLOUDHSM_LIB}" ]; then
  print_status "Installing the AWS CloudHSM PKCS#11 client package"
  ARCH="$(dpkg --print-architecture)"
  TMP_DEB="$(mktemp --suffix=.deb)"
  case "${ARCH}" in
    amd64)
      curl -fsSL -o "${TMP_DEB}" \
        "https://s3.amazonaws.com/cloudhsmv2-software/CloudHsmClient/Bionic/cloudhsm-pkcs11_latest_u18.04_amd64.deb"
      ;;
    arm64)
      curl -fsSL -o "${TMP_DEB}" \
        "https://s3.amazonaws.com/cloudhsmv2-software/CloudHsmClient/Bionic/cloudhsm-pkcs11_latest_u18.04_arm64.deb"
      ;;
    *)
      print_error "Unsupported architecture for AWS CloudHSM client: ${ARCH}"
      ;;
  esac
  sudo apt-get install -y "${TMP_DEB}"
fi

print_status "Fetching the CloudHSM cluster CA certificate chain via the AWS CLI"
CA_CERT="$(mktemp --suffix=.crt)"
aws cloudhsmv2 describe-clusters \
  --filters "clusterIds=${AWS_CLOUDHSM_CLUSTER_ID}" \
  --query 'Clusters[0].Certificates.ClusterCertificate' \
  --output text >"${CA_CERT}"

print_status "Registering the AWS CloudHSM cluster with configure-pkcs11"
sudo /opt/cloudhsm/bin/configure-pkcs11 \
  add-cluster \
  --cluster-id "${AWS_CLOUDHSM_CLUSTER_ID}" \
  --hsm-ca-cert "${CA_CERT}"

# Exported for the Rust test harness: the CU login PIN convention for AWS CloudHSM is
# "<cu_username>:<cu_password>" (see crate/hsm/aws_cloudhsm/README.md and lib.rs doc comment).
export AWS_CLOUDHSM_PKCS11_LIB="${CLOUDHSM_LIB}"
export HSM_USER_PASSWORD="${AWS_CLOUDHSM_CU_USERNAME}:${AWS_CLOUDHSM_CU_PASSWORD}"

print_success "AWS CloudHSM client ready (cluster: ${AWS_CLOUDHSM_CLUSTER_ID})"
