#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

NODE_JOIN_SCRIPT="${NODE_JOIN_SCRIPT:-${NODE_SCRIPT_DIR}/join.sh}"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/converge.sh [options]

Additive-only node convergence. Joins inventory nodes that are absent from
Kubernetes, refuses all other drift, and leaves joined nodes cordoned.

Options:
  --profile NAME    Node lifecycle profile: live or lima. Defaults to live.
  --context NAME    Kubernetes context. Defaults to the profile context.
  --plan            Print the plan without mutating.
  --output FORMAT   Output format: text or json. Defaults to text.
  --yes             Skip confirmation prompt.
  -h, --help        Show help.
EOF
}

node_converge_json_array() {
  if [[ "$#" -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | "$NODE_JQ_BIN" -R -s 'split("\n")[:-1]'
}

node_converge_has_value() {
  local needle="$1"
  shift
  local value
  for value in "$@"; do
    [[ "$value" == "$needle" ]] && return 0
  done
  return 1
}

node_converge_inventory_role_for_kubernetes_node() {
  local kube_node="$1"
  local i
  for ((i = 0; i < ${#inventory_kube_nodes[@]}; i++)); do
    if [[ "${inventory_kube_nodes[$i]}" == "$kube_node" ]]; then
      printf '%s\n' "${inventory_roles[$i]}"
      return 0
    fi
  done
  printf 'absent\n'
}

node_converge_inventory_name_for_kubernetes_node() {
  local kube_node="$1"
  local i
  for ((i = 0; i < ${#inventory_kube_nodes[@]}; i++)); do
    if [[ "${inventory_kube_nodes[$i]}" == "$kube_node" ]]; then
      printf '%s\n' "${inventory_names[$i]}"
      return 0
    fi
  done
  printf '%s\n' "$kube_node"
}

node_converge_desired_k3s_version() {
  local profile="$1"
  local value
  if [[ "$profile" == live ]]; then
    "${BOOTSTRAP_DIR}/ansible/render-inventory.sh" \
      --profile live \
      --inventory-source "$NODE_LIVE_INVENTORY_DIR" >/dev/null
  fi
  value="$(node_effective_ansible_group_var "$profile" k3s_version 2>/dev/null || true)"
  [[ -n "$value" && "$value" != "null" ]] ||
    node_die "k3s_version is missing from effective ${profile} inventory vars; run the Ansible plan/render step first"
  printf '%s\n' "$value"
}

node_converge_node_json() {
  local nodes_json="$1"
  local node="$2"
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -c --arg node "$node" '.items[] | select(.metadata.name == $node)' <<<"$nodes_json"
}

node_converge_longhorn_scheduling_disabled() {
  local context="$1"
  local node="$2"
  local longhorn_node_json allow_scheduling

  longhorn_node_json="$(node_get_json "$context" -n longhorn-system "nodes.longhorn.io/${node}" 2>/dev/null || true)"
  [[ -n "$longhorn_node_json" ]] || return 1
  allow_scheduling="$("$NODE_JQ_BIN" -r '
    if ((.spec // {}) | has("allowScheduling")) then .spec.allowScheduling else true end
  ' <<<"$longhorn_node_json")"
  [[ "$allow_scheduling" == false ]]
}

node_converge_print_list() {
  local label="$1"
  shift
  printf '%s:\n' "$label"
  if [[ "$#" -eq 0 ]]; then
    printf '  none\n'
    return 0
  fi
  local value
  for value in "$@"; do
    printf '  %s\n' "$value"
  done
}

node_converge_print_text_plan() {
  printf 'profile: %s\n' "$profile"
  printf 'context: %s\n' "$context"
  printf 'active_context: %s\n' "$active_context"
  printf 'desired_k3s_version: %s\n' "$desired_k3s_version"
  node_converge_print_list "blockers" "${blockers[@]}"
  node_converge_print_list "missing_workers" "${missing_workers_kube[@]}"
  node_converge_print_list "missing_control_planes" "${missing_control_planes_kube[@]}"
  node_converge_print_list "join_order" "${planned_kube_nodes[@]}"
  node_converge_print_list "follow_up" "${follow_up_commands[@]}"
}

node_converge_print_json_plan() {
  local blockers_json missing_workers_json missing_control_planes_json join_order_json follow_up_json
  blockers_json="$(node_converge_json_array "${blockers[@]}")"
  missing_workers_json="$(node_converge_json_array "${missing_workers_kube[@]}")"
  missing_control_planes_json="$(node_converge_json_array "${missing_control_planes_kube[@]}")"
  join_order_json="$(node_converge_json_array "${planned_kube_nodes[@]}")"
  follow_up_json="$(node_converge_json_array "${follow_up_commands[@]}")"

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg profile "$profile" \
    --arg context "$context" \
    --arg active_context "$active_context" \
    --arg desired_k3s_version "$desired_k3s_version" \
    --argjson blockers "$blockers_json" \
    --argjson missing_workers "$missing_workers_json" \
    --argjson missing_control_planes "$missing_control_planes_json" \
    --argjson join_order "$join_order_json" \
    --argjson follow_up "$follow_up_json" \
    '{
      profile: $profile,
      context: $context,
      active_context: $active_context,
      desired_k3s_version: $desired_k3s_version,
      blockers: $blockers,
      missing_workers: $missing_workers,
      missing_control_planes: $missing_control_planes,
      join_order: $join_order,
      follow_up: $follow_up
    }'
}

node_converge_print_plan() {
  case "$output_format" in
    text)
      node_converge_print_text_plan
      ;;
    json)
      node_converge_print_json_plan
      ;;
    *)
      node_die "unknown output format: ${output_format}"
      ;;
  esac
}

profile=live
context=""
plan=false
output_format=text
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
    --plan)
      plan=true
      shift
      ;;
    --output)
      output_format="$2"
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
    *)
      node_die "unknown argument: $1"
      ;;
  esac
done

node_validate_profile "$profile"
context="${context:-$(node_context_for_profile "$profile")}"

case "$output_format" in
  text|json)
    ;;
  *)
    node_die "--output must be text or json"
    ;;
esac
if [[ "$output_format" == json && "$plan" != true ]]; then
  node_die "--output json is only supported with --plan"
fi

node_require_tool "$NODE_KUBECTL_BIN"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible

node_inventory_exists "$profile" || node_die "inventory not found for profile ${profile}: $(node_inventory_file "$profile")"
active_context="$(node_current_context)"
if ! node_bool "$plan"; then
  node_assert_current_context "$context"
fi
node_assert_api_reachable "$context"
desired_k3s_version="$(node_converge_desired_k3s_version "$profile")"
longhorn_state="$(node_assert_longhorn_discovery "$context")"
kubernetes_nodes_json="$(node_get_json "$context" nodes)"

inventory_names=()
inventory_roles=()
inventory_kube_nodes=()
kubernetes_node_names=()
blockers=()
missing_workers_inventory=()
missing_workers_kube=()
missing_control_planes_inventory=()
missing_control_planes_kube=()
planned_inventory_nodes=()
planned_kube_nodes=()
follow_up_commands=()
current_control_plane_count=0
desired_control_plane_count="$(node_inventory_group_count "$profile" master)"

while IFS= read -r inventory_node; do
  [[ -n "$inventory_node" ]] || continue
  if [[ "$(node_inventory_role "$profile" "$inventory_node")" == conflict ]]; then
    blockers+=("node appears in both master and node inventory groups: ${inventory_node}")
  fi
  inventory_names+=("$inventory_node")
  inventory_roles+=(master)
  inventory_kube_nodes+=("$(node_expected_kubernetes_node_name "$profile" "$inventory_node" "$inventory_node")")
done < <(node_inventory_group_names "$profile" master)

while IFS= read -r inventory_node; do
  [[ -n "$inventory_node" ]] || continue
  if [[ "$(node_inventory_role "$profile" "$inventory_node")" == conflict ]]; then
    blockers+=("node appears in both master and node inventory groups: ${inventory_node}")
  fi
  inventory_names+=("$inventory_node")
  inventory_roles+=(node)
  inventory_kube_nodes+=("$(node_expected_kubernetes_node_name "$profile" "$inventory_node" "$inventory_node")")
done < <(node_inventory_group_names "$profile" node)

for ((i = 0; i < ${#inventory_kube_nodes[@]}; i++)); do
  for ((j = i + 1; j < ${#inventory_kube_nodes[@]}; j++)); do
    if [[ "${inventory_kube_nodes[$i]}" == "${inventory_kube_nodes[$j]}" ]]; then
      blockers+=("duplicate expected Kubernetes node name in inventory: ${inventory_kube_nodes[$i]}")
    fi
  done
done

while IFS= read -r kube_node; do
  [[ -n "$kube_node" ]] || continue
  kubernetes_node_names+=("$kube_node")
done < <("$NODE_JQ_BIN" -r '.items[].metadata.name' <<<"$kubernetes_nodes_json")

for kube_node in "${kubernetes_node_names[@]}"; do
  node_json="$(node_converge_node_json "$kubernetes_nodes_json" "$kube_node")"
  inventory_role="$(node_converge_inventory_role_for_kubernetes_node "$kube_node")"
  inventory_node="$(node_converge_inventory_name_for_kubernetes_node "$kube_node")"
  k8s_role="$(node_k8s_role_from_node_json <<<"$node_json")"
  ready="$(node_ready_from_node_json <<<"$node_json")"
  schedulable="$(node_schedulable_from_node_json <<<"$node_json")"
  joining_taint="$(node_joining_taint_from_node_json <<<"$node_json")"
  kubelet_version="$("$NODE_JQ_BIN" -r '.status.nodeInfo.kubeletVersion // ""' <<<"$node_json")"

  if [[ "$k8s_role" == control-plane ]]; then
    current_control_plane_count=$((current_control_plane_count + 1))
  fi
  if [[ "$inventory_role" == absent ]]; then
    blockers+=("Kubernetes node is not present in inventory: ${kube_node}")
    continue
  fi
  expected_role=node
  if [[ "$inventory_role" == master ]]; then
    expected_role=control-plane
  fi
  if [[ "$k8s_role" != "$expected_role" ]]; then
    blockers+=("role drift for ${kube_node}: inventory=${inventory_role} kubernetes=${k8s_role}")
  fi
  if [[ "$ready" != Ready ]]; then
    blockers+=("Kubernetes node is not Ready: ${kube_node}")
  fi
  if [[ "$schedulable" != schedulable ]]; then
    blockers+=("Kubernetes node is cordoned or pending finalization: ${kube_node}")
  fi
  case "$joining_taint" in
    absent)
      ;;
    present)
      blockers+=("Kubernetes node still has temporary joining taint: ${kube_node}")
      ;;
    invalid)
      blockers+=("Kubernetes node has invalid temporary joining taint: ${kube_node}")
      ;;
    *)
      blockers+=("Kubernetes node has unexpected joining taint state ${joining_taint}: ${kube_node}")
      ;;
  esac
  if [[ "$kubelet_version" != "$desired_k3s_version" ]]; then
    blockers+=("K3s version drift for ${kube_node}: desired=${desired_k3s_version} kubelet=${kubelet_version:-missing}")
  fi
  if [[ "$longhorn_state" == installed ]] &&
    node_converge_longhorn_scheduling_disabled "$context" "$kube_node"; then
    blockers+=("Longhorn scheduling is disabled for existing node: ${kube_node}")
  fi
  if [[ "$inventory_node" != "$kube_node" && "$profile" == live ]]; then
    blockers+=("live inventory node name does not match Kubernetes node name: inventory=${inventory_node} kubernetes=${kube_node}")
  fi
done

if ((desired_control_plane_count % 2 == 0)); then
  blockers+=("desired control-plane count must be odd; desired=${desired_control_plane_count}")
fi
if ((current_control_plane_count == 0)); then
  blockers+=("current Kubernetes control-plane count must be nonzero")
fi

for ((i = 0; i < ${#inventory_names[@]}; i++)); do
  inventory_node="${inventory_names[$i]}"
  inventory_role="${inventory_roles[$i]}"
  kube_node="${inventory_kube_nodes[$i]}"
  if node_converge_has_value "$kube_node" "${kubernetes_node_names[@]}"; then
    continue
  fi
  case "$inventory_role" in
    node)
      missing_workers_inventory+=("$inventory_node")
      missing_workers_kube+=("$kube_node")
      ;;
    master)
      missing_control_planes_inventory+=("$inventory_node")
      missing_control_planes_kube+=("$kube_node")
      ;;
  esac
done

allow_even_control_plane_repair=false
if ((current_control_plane_count > 0 && current_control_plane_count % 2 == 0)); then
  if [[ "${#missing_control_planes_inventory[@]}" -eq 1 &&
    "${#missing_workers_inventory[@]}" -eq 0 &&
    $(((current_control_plane_count + 1) % 2)) -eq 1 &&
    $((desired_control_plane_count % 2)) -eq 1 ]]; then
    allow_even_control_plane_repair=true
  else
    blockers+=("current Kubernetes control-plane count must be odd; current=${current_control_plane_count}")
  fi
fi

for ((i = 0; i < ${#missing_workers_inventory[@]}; i++)); do
  planned_inventory_nodes+=("${missing_workers_inventory[$i]}")
  planned_kube_nodes+=("${missing_workers_kube[$i]}")
done

if [[ "${#missing_control_planes_inventory[@]}" -gt 0 ]]; then
  if [[ "${#missing_control_planes_inventory[@]}" -ne 1 ]]; then
    blockers+=("control-plane converge supports exactly one missing control-plane; missing=${#missing_control_planes_inventory[@]}")
  elif ((desired_control_plane_count % 2 == 0)); then
    blockers+=("desired control-plane count must be odd; desired=${desired_control_plane_count}")
  elif ((current_control_plane_count % 2 == 0)) && [[ "$allow_even_control_plane_repair" != true ]]; then
    blockers+=("cannot join control-plane while current control-plane count is even; current=${current_control_plane_count}")
  elif (((current_control_plane_count + 1) % 2 == 0)); then
    blockers+=("post-converge control-plane count must be odd; post=$((current_control_plane_count + 1))")
  else
    planned_inventory_nodes+=("${missing_control_planes_inventory[0]}")
    planned_kube_nodes+=("${missing_control_planes_kube[0]}")
  fi
fi

for inventory_node in "${planned_inventory_nodes[@]}"; do
  if ! ping_output="$(node_ansible_ping "$profile" "$inventory_node" 2>&1 >/dev/null)"; then
    blockers+=("Ansible could not reach planned node ${inventory_node}: ${ping_output}")
  fi
done

for kube_node in "${planned_kube_nodes[@]}"; do
  case "$profile" in
    live)
      follow_up_commands+=("just node-uncordon ${kube_node}")
      ;;
    lima)
      follow_up_commands+=("just node-lima-uncordon ${kube_node}")
      ;;
  esac
done

if [[ "${#blockers[@]}" -gt 0 ]]; then
  node_converge_print_plan
  exit 1
fi

node_converge_print_plan
if node_bool "$plan"; then
  exit 0
fi

if [[ "${#planned_kube_nodes[@]}" -eq 0 ]]; then
  node_log "no missing inventory nodes to join"
  exit 0
fi

node_confirm "$yes" "converge missing nodes in ${context}"

for kube_node in "${planned_kube_nodes[@]}"; do
  node_log "joining missing node ${kube_node}"
  "$NODE_JOIN_SCRIPT" --profile "$profile" --context "$context" --yes "$kube_node"
done

node_log "converge complete; inspect joined nodes and run follow-up uncordon commands when ready"
for command in "${follow_up_commands[@]}"; do
  printf '  %s\n' "$command"
done
