#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/delete.sh [options] NODE

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

if [[ "$inventory_role" == master ]]; then
  args=(--profile "$profile" --context "$context")
  if node_bool "$yes"; then
    args+=(--yes)
  fi
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/control-plane-delete.sh" "${args[@]}" "$node_name"
fi

node_assert_inventory_worker "$inventory_node_name" "$inventory_role"
kubernetes_node_name="$(node_expected_kubernetes_node_name "$profile" "$inventory_node_name" "$node_name")"

node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
if [[ -z "$node_json" ]]; then
  node_confirm "$yes" "clean up deleted node state ${kubernetes_node_name} from ${context}"
  node_log "stopping k3s agent on ${inventory_node_name} before deleted-node cleanup"
  node_stop_k3s_agent "$profile" "$inventory_node_name"
  node_cleanup_pods_for_deleted_node "$context" "$kubernetes_node_name"
  node_cleanup_longhorn_deleted_node "$context" "$kubernetes_node_name"
  node_log "delete cleanup complete: ${kubernetes_node_name}"
  exit 0
fi
node_assert_kubernetes_worker "$node_json" "$kubernetes_node_name"
node_assert_cordoned "$node_json" "$kubernetes_node_name"
node_assert_no_ordinary_pods "$context" "$kubernetes_node_name"
node_assert_longhorn_empty_for_delete "$context" "$kubernetes_node_name"

node_confirm "$yes" "delete ${kubernetes_node_name} from ${context}"
node_log "stopping k3s agent on ${inventory_node_name}"
node_stop_k3s_agent "$profile" "$inventory_node_name"

node_log "deleting Kubernetes node ${kubernetes_node_name}"
node_kubectl "$context" delete "node/${kubernetes_node_name}" --wait=false
node_kubectl "$context" -n kube-system delete "secret/${kubernetes_node_name}.node-password.k3s" --ignore-not-found
node_wait_for_node_absent "$context" "$kubernetes_node_name"
node_cleanup_pods_for_deleted_node "$context" "$kubernetes_node_name"
node_cleanup_longhorn_deleted_node "$context" "$kubernetes_node_name"
node_log "delete complete: ${kubernetes_node_name}"
