#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/status.sh [options] NODE

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

case "$profile" in
  live|lima)
    ;;
  *)
    node_die "unknown node lifecycle profile: ${profile}"
    ;;
esac

context="${context:-$(node_context_for_profile "$profile")}"

node_require_tool "$NODE_KUBECTL_BIN"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"

input_node_name="$node_name"
inventory_node_name="$node_name"
inventory_role=absent
inventory_file="$(node_inventory_file "$profile")"
if node_inventory_exists "$profile"; then
  inventory_role="$(node_inventory_role "$profile" "$inventory_node_name")"
  if [[ "$inventory_role" == absent && "$profile" == lima && "$input_node_name" == lima-* ]]; then
    inventory_candidate="${input_node_name#lima-}"
    inventory_candidate_role="$(node_inventory_role "$profile" "$inventory_candidate")"
    if [[ "$inventory_candidate_role" != absent ]]; then
      inventory_node_name="$inventory_candidate"
      inventory_role="$inventory_candidate_role"
    fi
  fi
else
  node_warn "inventory not found for profile ${profile}: ${inventory_file}"
fi

printf 'profile: %s\n' "$profile"
printf 'context: %s\n' "$context"
printf 'node: %s\n' "$input_node_name"
printf 'inventory: %s\n' "$inventory_file"
printf 'inventory_node: %s\n' "$inventory_node_name"
printf 'inventory_role: %s\n' "$inventory_role"

if [[ "$inventory_role" == conflict ]]; then
  node_die "node ${inventory_node_name} appears in both master and node inventory groups"
fi

ansible_host="$(node_inventory_value "$profile" "$inventory_node_name" ansible_host 2>/dev/null || true)"
ansible_user="$(node_effective_ansible_user "$profile" "$inventory_node_name" 2>/dev/null || true)"
ssh_key="$(node_effective_ssh_key "$profile" "$inventory_node_name" 2>/dev/null || true)"
[[ -n "$ansible_host" ]] && printf 'ansible_host: %s\n' "$ansible_host"
[[ -n "$ansible_user" ]] && printf 'ansible_user: %s\n' "$ansible_user"
[[ -n "$ssh_key" ]] && printf 'ansible_ssh_private_key_file: %s\n' "$ssh_key"

if ! node_kubectl "$context" get --raw=/readyz >/dev/null 2>&1; then
  node_die "Kubernetes context is not reachable: ${context}"
fi

kubernetes_node_name="$input_node_name"
node_json="$(node_get_json "$context" "node/${kubernetes_node_name}" 2>/dev/null || true)"
if [[ -z "$node_json" && "$profile" == lima && "$input_node_name" != lima-* ]]; then
  kubernetes_candidate="lima-${input_node_name}"
  node_json="$(node_get_json "$context" "node/${kubernetes_candidate}" 2>/dev/null || true)"
  if [[ -n "$node_json" ]]; then
    kubernetes_node_name="$kubernetes_candidate"
  fi
fi
if [[ -z "$node_json" ]]; then
  printf 'kubernetes_node: absent\n'
  exit 0
fi

k8s_role="$(node_k8s_role_from_node_json <<<"$node_json")"
ready="$(node_ready_from_node_json <<<"$node_json")"
schedulable="$(node_schedulable_from_node_json <<<"$node_json")"
joining_taint="$(node_joining_taint_from_node_json <<<"$node_json")"

printf 'kubernetes_node: present\n'
printf 'kubernetes_node_name: %s\n' "$kubernetes_node_name"
printf 'kubernetes_role: %s\n' "$k8s_role"
printf 'ready: %s\n' "$ready"
printf 'schedulable: %s\n' "$schedulable"
printf 'joining_taint: %s\n' "$joining_taint"

printf '\nordinary_pods:\n'
ordinary_pods="$(node_workload_pods_report "$context" "$kubernetes_node_name")"
if [[ -z "$ordinary_pods" ]]; then
  printf '  none\n'
else
  while IFS=$'\t' read -r namespace name phase owner; do
    printf '  %s/%s phase=%s owner=%s\n' "$namespace" "$name" "$phase" "${owner:-none}"
  done <<<"$ordinary_pods"
fi

printf '\ncilium:\n'
while IFS= read -r line; do
  printf '  %s\n' "$line"
done < <(node_cilium_report "$context" "$kubernetes_node_name")

printf '\nlonghorn:\n'
longhorn_state_output="$(node_longhorn_state "$context")"
longhorn_state="${longhorn_state_output%%$'\t'*}"
if [[ "$longhorn_state" == installed ]]; then
  printf '  installed: true\n'
  printf '  node:\n'
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done < <(node_longhorn_node_report "$context" "$kubernetes_node_name")
  printf '  node_pods:\n'
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done < <(node_longhorn_pods_report "$context" "$kubernetes_node_name")
  printf '  volumes:\n'
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done < <(node_longhorn_volume_report "$context")
  printf '  replicas:\n'
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done < <(node_longhorn_replicas_report "$context" "$kubernetes_node_name")
  printf '  instance_managers:\n'
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done < <(node_longhorn_managers_report "$context" "$kubernetes_node_name" InstanceManager instancemanagers.longhorn.io)
  printf '  share_managers:\n'
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done < <(node_longhorn_managers_report "$context" "$kubernetes_node_name" ShareManager sharemanagers.longhorn.io)
elif [[ "$longhorn_state" == absent ]]; then
  printf '  installed: false\n'
else
  longhorn_error="${longhorn_state_output#"$longhorn_state"}"
  longhorn_error="${longhorn_error#$'\t'}"
  printf '  installed: unknown\n'
  printf '  discovery_error: %s\n' "${longhorn_error:-unknown error}"
fi

if [[ "$k8s_role" == control-plane ]]; then
  printf '\netcd:\n'
  printf '  status: deferred\n'
  printf '  note: use control-plane-status for embedded-etcd member introspection\n'
  ready_control_planes="$(node_ready_control_planes "$context" | paste -sd ',' -)"
  printf '  ready_control_planes: %s\n' "${ready_control_planes:-none}"
fi
