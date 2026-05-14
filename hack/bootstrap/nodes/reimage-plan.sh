#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-plan.sh [options] NODE

Read-only discovery for network reimage safety metadata.

Options:
  --profile NAME   Node lifecycle profile: live or lima. Defaults to live.
  --context NAME   Kubernetes context. Defaults to the profile context.
  -h, --help       Show help.
EOF
}

profile=live
context=""

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

node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible

IFS=$'\t' read -r inventory_node inventory_role < <(node_resolve_inventory_node "$profile" "$node_name")
case "$inventory_role" in
  master|node)
    ;;
  absent)
    node_die "node is not present in ${profile} inventory: ${node_name}"
    ;;
  conflict)
    node_die "node is present in multiple ${profile} inventory groups: ${node_name}"
    ;;
  *)
    node_die "could not resolve inventory role for node: ${node_name}"
    ;;
esac

kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_node" "$node_name")"
disk_path="$(node_reimage_inventory_disk_path "$profile" "$inventory_node")"
stage_dir="$(node_reimage_inventory_stage_dir "$profile" "$inventory_node")"
ansible_host="$(node_inventory_value "$profile" "$inventory_node" ansible_host 2>/dev/null || true)"
expected_pi_serial="$(node_inventory_value "$profile" "$inventory_node" home_ops_reimage_pi_serial 2>/dev/null || true)"
expected_disk_serial="$(node_inventory_value "$profile" "$inventory_node" home_ops_reimage_disk_serial 2>/dev/null || true)"

printf 'profile: %s\n' "$profile"
printf 'context: %s\n' "$context"
printf 'inventory_node: %s\n' "$inventory_node"
printf 'inventory_role: %s\n' "$inventory_role"
printf 'kubernetes_node: %s\n' "$kubernetes_node"
printf 'ansible_host: %s\n' "${ansible_host:-missing}"
printf 'target_disk: %s\n' "$disk_path"
printf 'stage_dir: %s\n' "$stage_dir"

if command -v "$NODE_KUBECTL_BIN" >/dev/null 2>&1 && node_kubectl "$context" get --raw=/readyz >/dev/null 2>&1; then
  if node_has_resource "$context" "node/${kubernetes_node}"; then
    printf 'kubernetes_node_state: present\n'
  else
    printf 'kubernetes_node_state: absent\n'
  fi
else
  printf 'kubernetes_node_state: unknown\n'
fi

printf '\ninventory_reimage_identity:\n'
printf '  home_ops_reimage_pi_serial: %s\n' "${expected_pi_serial:-missing}"
printf '  home_ops_reimage_disk_serial: %s\n' "${expected_disk_serial:-missing}"

printf '\nremote_probe:\n'
probe="$(node_reimage_probe_host "$profile" "$inventory_node" "$disk_path")"
while IFS= read -r line; do
  printf '  %s\n' "$line"
done <<<"$probe"

printf '\nnext_inventory_values:\n'
printf '  home_ops_reimage_pi_serial: %s\n' "$(node_reimage_probe_value "$probe" pi_serial)"
printf '  home_ops_reimage_disk_path: %s\n' "$(node_reimage_probe_value "$probe" disk_path)"
printf '  home_ops_reimage_disk_serial: %s\n' "$(node_reimage_probe_value "$probe" disk_serial)"
