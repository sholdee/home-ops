#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/join.sh [options] NODE

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
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/control-plane-join.sh" "${args[@]}" "$node_name"
fi

node_assert_inventory_worker "$inventory_node_name" "$inventory_role"
kubernetes_node_name="$(node_expected_kubernetes_node_name "$profile" "$inventory_node_name" "$node_name")"

node_assert_api_reachable "$context"
if node_has_resource "$context" "node/${kubernetes_node_name}"; then
  node_die "Kubernetes node already exists; drain/delete it before joining: ${kubernetes_node_name}"
fi

node_ansible_ping "$profile" "$inventory_node_name"
node_confirm "$yes" "join ${inventory_node_name} to ${context}"

node_cleanup_pods_for_deleted_node "$context" "$kubernetes_node_name"
node_wait_for_longhorn_node_absent "$context" "$kubernetes_node_name"
node_run_worker_ansible_action "$profile" "$inventory_node_name" join

node_json="$(node_wait_for_node_json "$context" "$kubernetes_node_name")"
node_assert_kubernetes_worker "$node_json" "$kubernetes_node_name"
node_assert_joining_taint "$node_json" "$kubernetes_node_name"

node_log "cordoning ${kubernetes_node_name} while system DaemonSets settle"
node_kubectl "$context" cordon "$kubernetes_node_name"

node_wait_for_ready "$context" "$kubernetes_node_name"
node_wait_for_cilium_ready "$context" "$kubernetes_node_name"
node_log "join complete; run the uncordon helper when ready: ${kubernetes_node_name}"
