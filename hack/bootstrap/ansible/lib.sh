#!/usr/bin/env bash

ANSIBLE_BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${ANSIBLE_BOOTSTRAP_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BOOTSTRAP_DIR}/../.." && pwd)"

# shellcheck source=hack/bootstrap/lib/config.sh
source "${BOOTSTRAP_DIR}/lib/config.sh"
# shellcheck source=hack/bootstrap/lib/repo-facts.sh
source "${BOOTSTRAP_DIR}/lib/repo-facts.sh"

K3S_ANSIBLE_DIR="${K3S_ANSIBLE_DIR:-${REPO_ROOT}/../k3s-ansible}"
BOOTSTRAP_ANSIBLE_BACKEND="${BOOTSTRAP_ANSIBLE_BACKEND:-home-ops}"
BOOTSTRAP_ANSIBLE_PROFILE="${BOOTSTRAP_ANSIBLE_PROFILE:-live}"
if [[ -z "${BOOTSTRAP_ANSIBLE_OUT_DIR+x}" ]]; then
  BOOTSTRAP_ANSIBLE_OUT_DIR_DEFAULTED=true
  BOOTSTRAP_ANSIBLE_OUT_DIR="${BOOTSTRAP_DIR}/.out/ansible-${BOOTSTRAP_ANSIBLE_PROFILE}"
else
  BOOTSTRAP_ANSIBLE_OUT_DIR_DEFAULTED=false
fi
BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR="${BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR:-${ANSIBLE_BOOTSTRAP_DIR}/inventory/live}"
BOOTSTRAP_ANSIBLE_OP_VAULT="${BOOTSTRAP_ANSIBLE_OP_VAULT:-Kubernetes}"
BOOTSTRAP_ANSIBLE_OP_ITEM="${BOOTSTRAP_ANSIBLE_OP_ITEM:-k3s-bootstrap}"
BOOTSTRAP_ANSIBLE_OP_FIELD="${BOOTSTRAP_ANSIBLE_OP_FIELD:-k3s_token}"
BOOTSTRAP_ANSIBLE_OP_ACCOUNT="${BOOTSTRAP_ANSIBLE_OP_ACCOUNT:-${BOOTSTRAP_OP_ACCOUNT:-}}"
BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_VAULT="${BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_VAULT:-Kubernetes}"
BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_ITEM="${BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_ITEM:-host-services}"
BOOTSTRAP_ANSIBLE_KUBECONTEXT="${BOOTSTRAP_ANSIBLE_KUBECONTEXT:-default}"
BOOTSTRAP_ANSIBLE_USER_KUBECONFIG="${BOOTSTRAP_ANSIBLE_USER_KUBECONFIG:-${HOME}/.kube/config}"

# shellcheck source=hack/bootstrap/ansible/lib/common.sh
source "${ANSIBLE_BOOTSTRAP_DIR}/lib/common.sh"
# shellcheck source=hack/bootstrap/ansible/lib/paths.sh
source "${ANSIBLE_BOOTSTRAP_DIR}/lib/paths.sh"
# shellcheck source=hack/bootstrap/ansible/lib/inventory.sh
source "${ANSIBLE_BOOTSTRAP_DIR}/lib/inventory.sh"
# shellcheck source=hack/bootstrap/ansible/lib/op.sh
source "${ANSIBLE_BOOTSTRAP_DIR}/lib/op.sh"
# shellcheck source=hack/bootstrap/ansible/lib/token.sh
source "${ANSIBLE_BOOTSTRAP_DIR}/lib/token.sh"
# shellcheck source=hack/bootstrap/ansible/lib/host-services.sh
source "${ANSIBLE_BOOTSTRAP_DIR}/lib/host-services.sh"
# shellcheck source=hack/bootstrap/ansible/lib/kubeconfig.sh
source "${ANSIBLE_BOOTSTRAP_DIR}/lib/kubeconfig.sh"
# shellcheck source=hack/bootstrap/ansible/lib/playbooks.sh
source "${ANSIBLE_BOOTSTRAP_DIR}/lib/playbooks.sh"
