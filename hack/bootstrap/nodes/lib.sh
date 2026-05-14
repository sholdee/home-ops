#!/usr/bin/env bash

NODE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${NODE_SCRIPT_DIR}/.." && pwd)"

LIMA_CLUSTER_NAME="${LIMA_CLUSTER_NAME:-home-ops-k3s-test}"
NODE_LIVE_INVENTORY_DIR="${NODE_LIVE_INVENTORY_DIR:-${BOOTSTRAP_DIR}/ansible/inventory/live}"
NODE_LIMA_INVENTORY_DIR="${NODE_LIMA_INVENTORY_DIR:-${BOOTSTRAP_DIR}/.out/lima-${LIMA_CLUSTER_NAME}/inventory}"
NODE_KUBECTL_BIN="${NODE_KUBECTL_BIN:-kubectl}"
NODE_YQ_BIN="${NODE_YQ_BIN:-yq}"
NODE_JQ_BIN="${NODE_JQ_BIN:-jq}"
NODE_SSH_KEYGEN_BIN="${NODE_SSH_KEYGEN_BIN:-ssh-keygen}"
NODE_JOINING_TAINT_KEY="node.home-ops.sh/joining"
NODE_LIMA_KUBECONFIG_PORT="${NODE_LIMA_KUBECONFIG_PORT:-${LIMA_KUBECONFIG_PORT:-16443}}"
NODE_REIMAGE_PAYLOAD_DIR="${NODE_REIMAGE_PAYLOAD_DIR:-}"

NODE_LIB_DIR="${NODE_SCRIPT_DIR}/lib"

# shellcheck source=hack/bootstrap/nodes/lib/common.sh
source "${NODE_LIB_DIR}/common.sh"
# shellcheck source=hack/bootstrap/nodes/lib/inventory.sh
source "${NODE_LIB_DIR}/inventory.sh"
# shellcheck source=hack/bootstrap/nodes/lib/k8s.sh
source "${NODE_LIB_DIR}/k8s.sh"
# shellcheck source=hack/bootstrap/nodes/lib/pods.sh
source "${NODE_LIB_DIR}/pods.sh"
# shellcheck source=hack/bootstrap/nodes/lib/cilium.sh
source "${NODE_LIB_DIR}/cilium.sh"
# shellcheck source=hack/bootstrap/nodes/lib/longhorn.sh
source "${NODE_LIB_DIR}/longhorn.sh"
# shellcheck source=hack/bootstrap/nodes/lib/etcd.sh
source "${NODE_LIB_DIR}/etcd.sh"
# shellcheck source=hack/bootstrap/nodes/lib/ansible.sh
source "${NODE_LIB_DIR}/ansible.sh"
# shellcheck source=hack/bootstrap/nodes/lib/wait.sh
source "${NODE_LIB_DIR}/wait.sh"
# shellcheck source=hack/bootstrap/nodes/lib/lima.sh
source "${NODE_LIB_DIR}/lima.sh"
# shellcheck source=hack/bootstrap/nodes/lib/reimage.sh
source "${NODE_LIB_DIR}/reimage.sh"
# shellcheck source=hack/bootstrap/nodes/lib/reimage-image.sh
source "${NODE_LIB_DIR}/reimage-image.sh"
