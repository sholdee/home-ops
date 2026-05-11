#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools
lima_require_tool kubectl
lima_require_tool nc

mkdir -p "$LIMA_OUT_DIR"
lima_start_apiserver_tunnel >/dev/null
kubeconfig="$(lima_prepare_kubeconfig)"
profile="${LIMA_BOOTSTRAP_PROFILE:-foundation}"

lima_log "running home-ops ${profile} bootstrap"
BOOTSTRAP_LIMA=true "${BOOTSTRAP_DIR}/bootstrap.sh" \
  --repo "$REPO_ROOT" \
  --kubeconfig "$kubeconfig" \
  --profile "$profile" \
  --yes \
  "$@"
