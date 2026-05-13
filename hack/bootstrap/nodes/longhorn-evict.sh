#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/longhorn-evict.sh [options] NODE

Options:
  --profile NAME   Node lifecycle profile: live or lima. Defaults to live.
  --context NAME   Kubernetes context. Defaults to the profile context.
  --yes            Skip confirmation prompt.
  -h, --help       Show help.
EOF
}

profile=live
context=""
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --context)
      context="$2"
      shift 2
      ;;
    --yes)
      yes=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      node_die "unknown argument: $1"
      ;;
    *)
      if [[ -n "${node_name:-}" ]]; then
        node_die "only one node may be provided"
      fi
      node_name="$1"
      shift
      ;;
  esac
done

[[ -n "${node_name:-}" ]] || node_die "NODE is required"
node_validate_profile "$profile"
context="${context:-$(node_context_for_profile "$profile")}"

node_require_tool "$NODE_KUBECTL_BIN"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"

IFS=$'\t' read -r inventory_node_name inventory_role < <(node_resolve_inventory_node "$profile" "$node_name")
kubernetes_node_name="$(node_expected_kubernetes_node_name "$profile" "$inventory_node_name" "$node_name")"

node_handoff_first_master_api_if_needed "$profile" "$context" "$inventory_node_name" "$kubernetes_node_name"
node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node is absent: ${kubernetes_node_name}"

case "$inventory_role" in
  master)
    node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"
    node_log "running control-plane delete preflight before Longhorn eviction"
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/control-plane-delete-preflight.sh" \
      --profile "$profile" \
      --context "$context" \
      "$node_name"
    ;;
  *)
    node_assert_inventory_worker "$inventory_node_name" "$inventory_role"
    node_assert_kubernetes_worker "$node_json" "$kubernetes_node_name"
    ;;
esac

node_assert_cordoned "$node_json" "$kubernetes_node_name"
node_assert_no_ordinary_pods "$context" "$kubernetes_node_name"
node_assert_longhorn_eviction_feasible "$context" "$kubernetes_node_name"

node_confirm "$yes" "evict Longhorn replicas from ${kubernetes_node_name} in ${context}"
node_log "requesting Longhorn replica eviction from ${kubernetes_node_name}"
node_request_longhorn_eviction "$context" "$kubernetes_node_name"
node_wait_for_longhorn_empty_for_delete "$context" "$kubernetes_node_name"
node_log "Longhorn eviction complete: ${kubernetes_node_name}"
