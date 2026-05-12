#!/usr/bin/env bash

NODE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${NODE_SCRIPT_DIR}/.." && pwd)"

LIMA_CLUSTER_NAME="${LIMA_CLUSTER_NAME:-home-ops-k3s-test}"
NODE_LIVE_INVENTORY_DIR="${NODE_LIVE_INVENTORY_DIR:-${BOOTSTRAP_DIR}/ansible/inventory/live}"
NODE_LIMA_INVENTORY_DIR="${NODE_LIMA_INVENTORY_DIR:-${BOOTSTRAP_DIR}/.out/lima-${LIMA_CLUSTER_NAME}/inventory}"
NODE_KUBECTL_BIN="${NODE_KUBECTL_BIN:-kubectl}"
NODE_YQ_BIN="${NODE_YQ_BIN:-yq}"
NODE_JQ_BIN="${NODE_JQ_BIN:-jq}"
NODE_JOINING_TAINT_KEY="node.home-ops.sh/joining"

node_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

node_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

node_require_tool() {
  command -v "$1" >/dev/null 2>&1 || node_die "required tool not found: $1"
}

node_context_for_profile() {
  local profile="$1"
  case "$profile" in
    live)
      printf '%s\n' default
      ;;
    lima)
      printf 'lima-%s\n' "$LIMA_CLUSTER_NAME"
      ;;
    *)
      node_die "unknown node lifecycle profile: ${profile}"
      ;;
  esac
}

node_inventory_dir() {
  local profile="$1"
  case "$profile" in
    live)
      printf '%s\n' "$NODE_LIVE_INVENTORY_DIR"
      ;;
    lima)
      printf '%s\n' "$NODE_LIMA_INVENTORY_DIR"
      ;;
    *)
      node_die "unknown node lifecycle profile: ${profile}"
      ;;
  esac
}

node_inventory_file() {
  printf '%s/hosts.yml\n' "$(node_inventory_dir "$1")"
}

node_group_vars_file() {
  printf '%s/group_vars/all.yml\n' "$(node_inventory_dir "$1")"
}

node_inventory_exists() {
  [[ -f "$(node_inventory_file "$1")" ]]
}

node_inventory_group_has() {
  local profile="$1"
  local group="$2"
  local node="$3"
  local inventory
  inventory="$(node_inventory_file "$profile")"
  [[ -f "$inventory" ]] || return 1
  NODE_NAME="$node" "$NODE_YQ_BIN" -r \
    ".all.children.k3s_cluster.children.${group}.hosts | has(strenv(NODE_NAME))" \
    "$inventory" 2>/dev/null | grep -Fxq true
}

node_inventory_role() {
  local profile="$1"
  local node="$2"
  local in_master=false
  local in_node=false
  if node_inventory_group_has "$profile" master "$node"; then
    in_master=true
  fi
  if node_inventory_group_has "$profile" node "$node"; then
    in_node=true
  fi

  case "${in_master}:${in_node}" in
    true:false)
      printf '%s\n' master
      ;;
    false:true)
      printf '%s\n' node
      ;;
    false:false)
      printf '%s\n' absent
      ;;
    true:true)
      printf '%s\n' conflict
      ;;
  esac
}

node_inventory_value() {
  local profile="$1"
  local node="$2"
  local key="$3"
  local role
  local inventory
  role="$(node_inventory_role "$profile" "$node")"
  [[ "$role" == master || "$role" == node ]] || return 1
  inventory="$(node_inventory_file "$profile")"
  NODE_NAME="$node" "$NODE_YQ_BIN" -r \
    ".all.children.k3s_cluster.children.${role}.hosts[strenv(NODE_NAME)].${key} // \"\"" \
    "$inventory"
}

node_group_var() {
  local profile="$1"
  local key="$2"
  local group_vars
  group_vars="$(node_group_vars_file "$profile")"
  [[ -f "$group_vars" ]] || return 1
  "$NODE_YQ_BIN" -r ".${key} // \"\"" "$group_vars"
}

node_effective_ansible_user() {
  local profile="$1"
  local node="$2"
  local value
  value="$(node_inventory_value "$profile" "$node" ansible_user 2>/dev/null || true)"
  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  value="$(node_group_var "$profile" ansible_user 2>/dev/null || true)"
  [[ -n "$value" && "$value" != "null" ]] && printf '%s\n' "$value"
}

node_effective_ssh_key() {
  local profile="$1"
  local node="$2"
  local value
  local home_prefix
  home_prefix="$(printf '%s/' '~')"
  value="$(node_inventory_value "$profile" "$node" ansible_ssh_private_key_file 2>/dev/null || true)"
  if [[ -z "$value" || "$value" == "null" ]]; then
    value="$(node_group_var "$profile" ansible_ssh_private_key_file 2>/dev/null || true)"
  fi
  [[ -n "$value" && "$value" != "null" ]] || return 0
  if [[ "${value:0:2}" == "$home_prefix" ]]; then
    printf '%s/%s\n' "$HOME" "${value:2}"
  else
    printf '%s\n' "$value"
  fi
}

node_kubectl() {
  local context="$1"
  shift
  "$NODE_KUBECTL_BIN" --context "$context" "$@"
}

node_get_json() {
  local context="$1"
  shift
  node_kubectl "$context" get "$@" -o json
}

node_has_resource() {
  local context="$1"
  shift
  node_kubectl "$context" get "$@" >/dev/null 2>&1
}

node_k8s_role_from_node_json() {
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r '
    .metadata.labels as $labels |
    if (($labels["node-role.kubernetes.io/control-plane"] // null) != null or
        ($labels["node-role.kubernetes.io/master"] // null) != null or
        ($labels["node-role.kubernetes.io/etcd"] // null) != null) then
      "control-plane"
    else
      "node"
    end
  '
}

node_ready_from_node_json() {
  "$NODE_JQ_BIN" -r '
    if any(.status.conditions[]?; .type == "Ready" and .status == "True") then
      "Ready"
    else
      "NotReady"
    end
  '
}

node_schedulable_from_node_json() {
  "$NODE_JQ_BIN" -r '
    if (.spec.unschedulable // false) then
      "cordoned"
    else
      "schedulable"
    end
  '
}

node_joining_taint_from_node_json() {
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg key "$NODE_JOINING_TAINT_KEY" '
    if any(.spec.taints[]?; .key == $key) then
      "present"
    else
      "absent"
    end
  '
}

node_workload_pods_report() {
  local context="$1"
  local node="$2"
  local pods_json
  pods_json="$(node_get_json "$context" pods -A --field-selector "spec.nodeName=${node}" 2>/dev/null || true)"
  [[ -n "$pods_json" ]] || return 0
  "$NODE_JQ_BIN" -r '
    def owner_kind:
      (.metadata.ownerReferences // [] | map(.kind) | join(","));
    .items[]
    | select(.status.phase != "Succeeded")
    | select((.metadata.ownerReferences // [] | map(.kind) | index("DaemonSet")) | not)
    | [
        .metadata.namespace,
        .metadata.name,
        (.status.phase // "unknown"),
        owner_kind
      ]
    | @tsv
  ' <<<"$pods_json"
}

node_cilium_report() {
  local context="$1"
  local node="$2"
  local pods_json
  if ! node_has_resource "$context" namespace kube-system; then
    printf 'unknown: kube-system namespace not reachable\n'
    return 0
  fi
  pods_json="$(node_get_json "$context" -n kube-system pods -l k8s-app=cilium 2>/dev/null || true)"
  if [[ -z "$pods_json" || "$("$NODE_JQ_BIN" -r '.items | length' <<<"$pods_json")" == 0 ]]; then
    printf 'not installed or no cilium pods found\n'
    return 0
  fi
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" '
    [
      .items[]
      | select(.spec.nodeName == $node)
      | {
          name: .metadata.name,
          phase: (.status.phase // "unknown"),
          ready: ([.status.containerStatuses[]? | select(.ready == true)] | length),
          total: ([.status.containerStatuses[]?] | length)
        }
      | "\(.name) phase=\(.phase) ready=\(.ready)/\(.total)"
    ] | if length == 0 then "no cilium pod on node" else .[] end
  ' <<<"$pods_json"
}

node_longhorn_installed() {
  local context="$1"
  node_has_resource "$context" crd volumes.longhorn.io
}

node_longhorn_pods_report() {
  local context="$1"
  local node="$2"
  local pods_json
  pods_json="$(node_get_json "$context" -n longhorn-system pods --field-selector "spec.nodeName=${node}" 2>/dev/null || true)"
  if [[ -z "$pods_json" ]]; then
    printf 'longhorn-system pods not readable\n'
    return 0
  fi
  "$NODE_JQ_BIN" -r '
    [
      .items[]
      | select(.status.phase != "Succeeded")
      | {
          name: .metadata.name,
          phase: (.status.phase // "unknown"),
          ready: ([.status.containerStatuses[]? | select(.ready == true)] | length),
          total: ([.status.containerStatuses[]?] | length)
        }
      | "\(.name) phase=\(.phase) ready=\(.ready)/\(.total)"
    ] | if length == 0 then "no longhorn pods on node" else .[] end
  ' <<<"$pods_json"
}

node_longhorn_volume_report() {
  local context="$1"
  local volumes_json
  volumes_json="$(node_get_json "$context" -n longhorn-system volumes.longhorn.io 2>/dev/null || true)"
  if [[ -z "$volumes_json" ]]; then
    printf 'Longhorn volumes not readable\n'
    return 0
  fi
  "$NODE_JQ_BIN" -r '
    [
      .items[]
      | {
          name: .metadata.name,
          state: (.status.state // "unknown"),
          robustness: (.status.robustness // "unknown"),
          node: (.status.currentNodeID // "")
        }
      | select(.robustness != "healthy" or (.state != "attached" and .state != "detached"))
      | "\(.name) state=\(.state) robustness=\(.robustness) node=\(.node)"
    ] | if length == 0 then "no risky Longhorn volume states observed" else .[] end
  ' <<<"$volumes_json"
}

node_longhorn_replicas_report() {
  local context="$1"
  local node="$2"
  local replicas_json
  replicas_json="$(node_get_json "$context" -n longhorn-system replicas.longhorn.io 2>/dev/null || true)"
  if [[ -z "$replicas_json" ]]; then
    printf 'Longhorn replicas not readable\n'
    return 0
  fi
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" '
    [
      .items[]
      | select((.spec.nodeID // .status.currentNodeID // "") == $node)
      | {
          name: .metadata.name,
          state: (.status.currentState // .status.state // "unknown"),
          healthyAt: (.status.healthyAt // ""),
          failedAt: (.status.failedAt // "")
        }
      | "\(.name) state=\(.state) healthyAt=\(.healthyAt) failedAt=\(.failedAt)"
    ] | if length == 0 then "no Longhorn replicas on node" else .[] end
  ' <<<"$replicas_json"
}

node_longhorn_managers_report() {
  local context="$1"
  local node="$2"
  local kind="$3"
  local resource="$4"
  local json
  json="$(node_get_json "$context" -n longhorn-system "$resource" 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    printf '%s not readable\n' "$kind"
    return 0
  fi
  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" --arg kind "$kind" '
    [
      .items[]
      | select((.spec.nodeID // .status.ownerID // .status.currentNodeID // "") == $node)
      | {
          name: .metadata.name,
          state: (.status.currentState // .status.state // "unknown")
        }
      | "\($kind)/\(.name) state=\(.state)"
    ] | if length == 0 then "no \($kind) resources on node" else .[] end
  ' <<<"$json"
}

node_ready_control_planes() {
  local context="$1"
  local nodes_json
  nodes_json="$(node_get_json "$context" nodes 2>/dev/null || true)"
  [[ -n "$nodes_json" ]] || return 0
  "$NODE_JQ_BIN" -r '
    .items[]
    | select(
        (.metadata.labels["node-role.kubernetes.io/control-plane"] // null) != null or
        (.metadata.labels["node-role.kubernetes.io/master"] // null) != null or
        (.metadata.labels["node-role.kubernetes.io/etcd"] // null) != null
      )
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name
  ' <<<"$nodes_json"
}
