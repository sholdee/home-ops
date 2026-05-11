#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools

"${SCRIPT_DIR}/inventory.sh"

"${BOOTSTRAP_DIR}/ansible/run.sh" \
  --profile lima \
  --inventory-dir "$(lima_inventory_dir)" \
  --skip-render \
  --skip-prereqs \
  --skip-import \
  --yes

lima_log "installing host kube context"
lima_install_host_kubecontext
