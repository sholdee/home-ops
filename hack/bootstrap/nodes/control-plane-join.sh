#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/control-plane-join.sh [options] NODE

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
node_require_tool ansible

IFS=$'\t' read -r inventory_node_name inventory_role < <(node_resolve_inventory_node "$profile" "$node_name")
node_assert_inventory_control_plane "$inventory_node_name" "$inventory_role"
kubernetes_node_name="$(node_expected_kubernetes_node_name "$profile" "$inventory_node_name" "$node_name")"

node_handoff_first_master_api_if_needed "$profile" "$context" "$inventory_node_name" "$kubernetes_node_name"
node_assert_api_reachable "$context"
if node_has_resource "$context" "node/${kubernetes_node_name}"; then
  node_die "Kubernetes node already exists; drain/delete it before joining: ${kubernetes_node_name}"
fi
if node_has_resource "$context" -n kube-system "secret/${kubernetes_node_name}.node-password.k3s"; then
  node_die "K3s node password secret still exists; rerun delete cleanup before joining: ${kubernetes_node_name}"
fi

node_ansible_ping "$profile" "$inventory_node_name"
node_confirm "$yes" "join control-plane node ${kubernetes_node_name} to ${context}"

node_cleanup_pods_for_deleted_node "$context" "$kubernetes_node_name"
node_cleanup_longhorn_deleted_node "$context" "$kubernetes_node_name"
node_assert_control_plane_etcd_member_absent "$profile" "$context" "$inventory_node_name" "$kubernetes_node_name"

join_ip=""
if node_is_first_inventory_master "$profile" "$inventory_node_name"; then
  join_ip="$(node_alternate_ready_control_plane_internal_ip "$profile" "$context" "$kubernetes_node_name")"
  node_log "using alternate control-plane endpoint ${join_ip} for first-master rejoin"
fi

node_log "joining control-plane node ${inventory_node_name} with temporary scheduling taint"
node_run_control_plane_ansible_action "$profile" "$inventory_node_name" join "$join_ip"

node_json="$(node_wait_for_node_json "$context" "$kubernetes_node_name" 600)"
node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"
node_assert_joining_taint "$node_json" "$kubernetes_node_name"

node_log "cordoning ${kubernetes_node_name} while system DaemonSets and etcd settle"
node_kubectl "$context" cordon "$kubernetes_node_name"

node_wait_for_ready "$context" "$kubernetes_node_name" 600
node_wait_for_cilium_ready "$context" "$kubernetes_node_name" 600
node_log "validating control-plane etcd membership for ${kubernetes_node_name}"
"${NODE_SCRIPT_DIR}/control-plane-delete-preflight.sh" --profile "$profile" --context "$context" "$node_name" >/dev/null
node_log "control-plane join complete; run the uncordon helper when ready: ${kubernetes_node_name}"
