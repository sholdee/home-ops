#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/drain.sh [options] NODE

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

node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node is absent: ${kubernetes_node_name}"

case "$inventory_role" in
  master)
    node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"
    node_log "running control-plane delete preflight before drain"
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/control-plane-delete-preflight.sh" \
      --profile "$profile" \
      --context "$context" \
      "$node_name"
    node_confirm "$yes" "drain control-plane node ${kubernetes_node_name} from ${context}"
    ;;
  *)
    node_assert_inventory_worker "$inventory_node_name" "$inventory_role"
    node_assert_kubernetes_worker "$node_json" "$kubernetes_node_name"
    node_confirm "$yes" "drain ${kubernetes_node_name} from ${context}"
    ;;
esac

node_log "draining ${kubernetes_node_name}"
node_kubectl "$context" drain "$kubernetes_node_name" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=120 \
  --timeout=15m

node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node disappeared during drain: ${kubernetes_node_name}"
if [[ "$inventory_role" == master ]]; then
  node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"
else
  node_assert_kubernetes_worker "$node_json" "$kubernetes_node_name"
fi
node_assert_cordoned "$node_json" "$kubernetes_node_name"
node_assert_no_ordinary_pods "$context" "$kubernetes_node_name"
node_wait_for_longhorn_maintenance_safe "$context" "$kubernetes_node_name"
node_log "drain complete: ${kubernetes_node_name}"
