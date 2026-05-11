#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools
lima_require_tool ansible-playbook
lima_require_tool ansible-galaxy

"${SCRIPT_DIR}/inventory.sh"
inventory_file="$(lima_inventory_file)"

lima_log "installing k3s-ansible collections"
ansible-galaxy collection install -r "${K3S_ANSIBLE_DIR}/collections/requirements.yml"

lima_log "running k3s-ansible site.yml"
(
  cd "$K3S_ANSIBLE_DIR"
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "$inventory_file" site.yml
)

lima_log "installing host kube context"
lima_install_host_kubecontext
