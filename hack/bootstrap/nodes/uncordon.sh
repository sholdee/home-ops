#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/uncordon.sh [options] NODE

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
node_assert_inventory_worker "$inventory_node_name" "$inventory_role"
kubernetes_node_name="$(node_expected_kubernetes_node_name "$profile" "$inventory_node_name" "$node_name")"

node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node is absent: ${kubernetes_node_name}"
node_assert_kubernetes_worker "$node_json" "$kubernetes_node_name"
node_assert_ready "$node_json" "$kubernetes_node_name"
node_assert_cordoned "$node_json" "$kubernetes_node_name"
joining_taint="$(node_joining_taint_from_node_json <<<"$node_json")"
case "$joining_taint" in
  present|absent)
    ;;
  invalid)
    node_die "temporary joining taint has the wrong value/effect: ${kubernetes_node_name}"
    ;;
  *)
    node_die "unexpected temporary joining taint state: ${joining_taint}"
    ;;
esac

node_confirm "$yes" "uncordon ${kubernetes_node_name} in ${context}"

node_log "removing temporary joining taint from k3s agent service args on ${inventory_node_name}"
node_run_worker_ansible_action "$profile" "$inventory_node_name" finalize
node_wait_for_ready "$context" "$kubernetes_node_name"

node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node disappeared before taint removal: ${kubernetes_node_name}"
joining_taint="$(node_joining_taint_from_node_json <<<"$node_json")"
if [[ "$joining_taint" == present || "$joining_taint" == invalid ]]; then
  node_log "removing live temporary joining taint from ${kubernetes_node_name}"
  node_kubectl "$context" taint "node/${kubernetes_node_name}" "${NODE_JOINING_TAINT_KEY}-" --overwrite
else
  node_log "live temporary joining taint is already absent from ${kubernetes_node_name}"
fi

node_wait_for_ready "$context" "$kubernetes_node_name"
node_wait_for_cilium_ready "$context" "$kubernetes_node_name"
node_wait_for_longhorn_safe "$context" "$kubernetes_node_name"
node_wait_for_longhorn_ready_for_uncordon "$context" "$kubernetes_node_name"

node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node disappeared before uncordon: ${kubernetes_node_name}"
node_assert_kubernetes_worker "$node_json" "$kubernetes_node_name"
node_assert_ready "$node_json" "$kubernetes_node_name"
node_assert_no_joining_taint "$node_json" "$kubernetes_node_name"

node_log "uncordoning ${kubernetes_node_name}"
node_kubectl "$context" uncordon "$kubernetes_node_name"
node_log "uncordon complete: ${kubernetes_node_name}"
