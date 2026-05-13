#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/lima/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools
lima_install_host_kubecontext

lima_log "context ready: kubectl --context ${LIMA_KUBECONTEXT} get nodes"
