#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reboot.sh [options] NODE

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
kubernetes_node_name="$(node_expected_kubernetes_node_name "$profile" "$inventory_node_name" "$node_name")"

if [[ "$inventory_role" == master ]]; then
  node_handoff_control_plane_api_if_needed "$profile" "$context" "$inventory_node_name" "$kubernetes_node_name"
fi
node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node is absent: ${kubernetes_node_name}"

case "$inventory_role" in
  master)
    node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"
    node_log "running control-plane delete preflight before reboot"
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

node_assert_ready "$node_json" "$kubernetes_node_name"
node_assert_cordoned "$node_json" "$kubernetes_node_name"
node_assert_no_ordinary_pods "$context" "$kubernetes_node_name"
node_wait_for_longhorn_maintenance_safe "$context" "$kubernetes_node_name"
previous_boot_id="$(node_boot_id_from_node_json <<<"$node_json")"
[[ -n "$previous_boot_id" ]] ||
  node_die "node bootID is missing; cannot verify reboot completion: ${kubernetes_node_name}"

node_confirm "$yes" "reboot ${kubernetes_node_name} from ${context}"

inventory_file="$(node_inventory_file "$profile")"
node_log "scheduling reboot on ${inventory_node_name}"
node_run_remote_shell "$inventory_file" "$inventory_node_name" \
  "nohup sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &"

node_log "waiting for ${kubernetes_node_name} to report a new boot ID"
node_wait_for_boot_id_change "$context" "$kubernetes_node_name" "$previous_boot_id" 900
node_wait_for_cilium_ready "$context" "$kubernetes_node_name" 600
node_wait_for_longhorn_ready_for_kubernetes_uncordon "$context" "$kubernetes_node_name" 600

node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node disappeared after reboot: ${kubernetes_node_name}"
if [[ "$inventory_role" == master ]]; then
  node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"
else
  node_assert_kubernetes_worker "$node_json" "$kubernetes_node_name"
fi
node_assert_ready "$node_json" "$kubernetes_node_name"
node_assert_cordoned "$node_json" "$kubernetes_node_name"
node_log "reboot complete: ${kubernetes_node_name}; node remains cordoned"
