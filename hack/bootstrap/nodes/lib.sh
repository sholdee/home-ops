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

node_log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

node_require_tool() {
  command -v "$1" >/dev/null 2>&1 || node_die "required tool not found: $1"
}

node_bool() {
  [[ "${1:-}" == true ]]
}

node_confirm() {
  local yes="$1"
  local expected="$2"

  if node_bool "$yes"; then
    return
  fi

  printf 'Type "%s" to continue: ' "$expected" >&2
  local answer
  read -r answer
  [[ "$answer" == "$expected" ]] || node_die "confirmation failed"
}

node_validate_profile() {
  case "$1" in
    live|lima)
      ;;
    *)
      node_die "unknown node lifecycle profile: ${1}"
      ;;
  esac
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

node_ansible_inventory_file() {
  node_inventory_file "$1"
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

node_resolve_inventory_node() {
  local profile="$1"
  local input_node="$2"
  local inventory_node="$input_node"
  local inventory_role

  inventory_role="$(node_inventory_role "$profile" "$inventory_node")"
  if [[ "$inventory_role" == absent && "$profile" == lima && "$input_node" == lima-* ]]; then
    local inventory_candidate="${input_node#lima-}"
    local inventory_candidate_role
    inventory_candidate_role="$(node_inventory_role "$profile" "$inventory_candidate")"
    if [[ "$inventory_candidate_role" != absent ]]; then
      inventory_node="$inventory_candidate"
      inventory_role="$inventory_candidate_role"
    fi
  fi

  printf '%s\t%s\n' "$inventory_node" "$inventory_role"
}

node_expected_kubernetes_node_name() {
  local profile="$1"
  local inventory_node="$2"
  local input_node="$3"

  if [[ "$profile" == lima ]]; then
    if [[ "$input_node" == lima-* ]]; then
      printf '%s\n' "$input_node"
    else
      printf 'lima-%s\n' "$inventory_node"
    fi
    return
  fi

  printf '%s\n' "$inventory_node"
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

node_assert_api_reachable() {
  local context="$1"
  node_kubectl "$context" get --raw=/readyz >/dev/null 2>&1 ||
    node_die "Kubernetes context is not reachable: ${context}"
}

node_node_json_if_present() {
  local context="$1"
  local node="$2"
  node_get_json "$context" "node/${node}" 2>/dev/null || true
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
    [
      .spec.taints[]?
      | select(.key == $key)
    ] as $taints |
    if ($taints | length) == 0 then
      "absent"
    elif any($taints[]; (.value // "") == "true" and (.effect // "") == "NoSchedule") then
      "present"
    else
      "invalid"
    end
  '
}

node_assert_inventory_worker() {
  local inventory_node="$1"
  local inventory_role="$2"

  case "$inventory_role" in
    node)
      ;;
    master)
      node_die "control-plane lifecycle is not implemented yet: ${inventory_node}"
      ;;
    absent)
      node_die "node is not present in the selected inventory: ${inventory_node}"
      ;;
    conflict)
      node_die "node appears in both master and node inventory groups: ${inventory_node}"
      ;;
    *)
      node_die "unexpected inventory role for ${inventory_node}: ${inventory_role}"
      ;;
  esac
}

node_assert_kubernetes_worker() {
  local node_json="$1"
  local node="$2"
  local k8s_role

  k8s_role="$(node_k8s_role_from_node_json <<<"$node_json")"
  [[ "$k8s_role" == node ]] ||
    node_die "control-plane lifecycle is not implemented yet: ${node}"
}

node_assert_ready() {
  local node_json="$1"
  local node="$2"
  local ready

  ready="$(node_ready_from_node_json <<<"$node_json")"
  [[ "$ready" == Ready ]] || node_die "node is not Ready: ${node}"
}

node_assert_cordoned() {
  local node_json="$1"
  local node="$2"
  local schedulable

  schedulable="$(node_schedulable_from_node_json <<<"$node_json")"
  [[ "$schedulable" == cordoned ]] || node_die "node must be cordoned first: ${node}"
}

node_assert_no_joining_taint() {
  local node_json="$1"
  local node="$2"
  local joining_taint

  joining_taint="$(node_joining_taint_from_node_json <<<"$node_json")"
  [[ "$joining_taint" == absent ]] || node_die "temporary joining taint is still present: ${node}"
}

node_assert_joining_taint() {
  local node_json="$1"
  local node="$2"
  local joining_taint

  joining_taint="$(node_joining_taint_from_node_json <<<"$node_json")"
  case "$joining_taint" in
    present)
      ;;
    invalid)
      node_die "temporary joining taint has the wrong value/effect: ${node}"
      ;;
    *)
      node_die "temporary joining taint is missing: ${node}"
      ;;
  esac
}

node_assert_no_ordinary_pods() {
  local context="$1"
  local node="$2"
  local pods_json ordinary_pods

  pods_json="$(node_get_json "$context" pods -A --field-selector "spec.nodeName=${node}" 2>/dev/null)" ||
    node_die "ordinary pods are not readable for ${node}"
  ordinary_pods="$("$NODE_JQ_BIN" -r '
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
  ' <<<"$pods_json")"
  if [[ -n "$ordinary_pods" ]]; then
    printf '%s\n' "$ordinary_pods" >&2
    node_die "ordinary non-DaemonSet pods are still scheduled on ${node}"
  fi
}

node_assert_cilium_ready() {
  local context="$1"
  local node="$2"
  local pods_json problems count

  pods_json="$(node_get_json "$context" -n kube-system pods -l k8s-app=cilium 2>/dev/null || true)"
  [[ -n "$pods_json" ]] || node_die "Cilium pods are not readable"

  # shellcheck disable=SC2016
  count="$("$NODE_JQ_BIN" -r --arg node "$node" '[.items[] | select(.spec.nodeName == $node)] | length' <<<"$pods_json")"
  [[ "$count" -gt 0 ]] || node_die "no Cilium pod found on ${node}"

  # shellcheck disable=SC2016
  problems="$("$NODE_JQ_BIN" -r --arg node "$node" '
    [
      .items[]
      | select(.spec.nodeName == $node)
      | {
          name: .metadata.name,
          phase: (.status.phase // "unknown"),
          ready: ([.status.containerStatuses[]? | select(.ready == true)] | length),
          total: ([.status.containerStatuses[]?] | length)
        }
      | select(.phase != "Running" or .total == 0 or .ready != .total)
      | "\(.name) phase=\(.phase) ready=\(.ready)/\(.total)"
    ] | .[]
  ' <<<"$pods_json")"

  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    node_die "Cilium is not ready on ${node}"
  fi
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
  [[ "$(node_longhorn_state_kind "$context")" == installed ]]
}

node_longhorn_state() {
  local context="$1"
  local output

  if output="$(node_kubectl "$context" get crd volumes.longhorn.io -o json 2>&1 >/dev/null)"; then
    printf '%s\n' installed
    return
  fi

  if grep -qi 'not found' <<<"$output"; then
    printf '%s\n' absent
    return
  fi

  printf 'error\t%s\n' "${output:-unknown Longhorn CRD discovery error}"
}

node_longhorn_state_kind() {
  local state_output
  state_output="$(node_longhorn_state "$1")"
  printf '%s\n' "${state_output%%$'\t'*}"
}

node_assert_longhorn_discovery() {
  local context="$1"
  local state_output state reason

  state_output="$(node_longhorn_state "$context")"
  state="${state_output%%$'\t'*}"
  case "$state" in
    installed|absent)
      printf '%s\n' "$state"
      ;;
    *)
      reason="${state_output#"$state"}"
      reason="${reason#$'\t'}"
      node_die "Longhorn CRD discovery failed: ${reason:-unknown error}"
      ;;
  esac
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

node_longhorn_node_report() {
  local context="$1"
  local node="$2"
  local longhorn_node_json

  longhorn_node_json="$(node_get_json "$context" -n longhorn-system "nodes.longhorn.io/${node}" 2>/dev/null || true)"
  if [[ -z "$longhorn_node_json" ]]; then
    printf 'Longhorn node resource not readable\n'
    return 0
  fi

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r '
    def condition_status($type):
      ([.status.conditions[]? | select(.type == $type) | .status] | first) // "unknown";
    "allowScheduling=\((.spec.allowScheduling // true) | tostring) ready=\(condition_status("Ready")) schedulable=\(condition_status("Schedulable"))"
  ' <<<"$longhorn_node_json"
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

node_longhorn_pod_problems() {
  local context="$1"
  local node="$2"
  local pods_json

  pods_json="$(node_get_json "$context" -n longhorn-system pods --field-selector "spec.nodeName=${node}" 2>/dev/null || true)"
  [[ -n "$pods_json" ]] || {
    printf 'longhorn-system pods not readable\n'
    return 0
  }

  "$NODE_JQ_BIN" -r '
    if (.items | length) == 0 then
      ["no longhorn-system pods on node"]
    else
      [
        .items[]
        | select(.status.phase != "Succeeded")
        | {
            name: .metadata.name,
            phase: (.status.phase // "unknown"),
            ready: ([.status.containerStatuses[]? | select(.ready == true)] | length),
            total: ([.status.containerStatuses[]?] | length)
          }
        | select(.phase != "Running" or .total == 0 or .ready != .total)
        | "\(.name) phase=\(.phase) ready=\(.ready)/\(.total)"
      ]
    end | .[]
  ' <<<"$pods_json"
}

node_longhorn_attached_volumes_on_node() {
  local context="$1"
  local node="$2"
  local volumes_json

  volumes_json="$(node_get_json "$context" -n longhorn-system volumes.longhorn.io 2>/dev/null || true)"
  [[ -n "$volumes_json" ]] || {
    printf 'Longhorn volumes not readable\n'
    return 0
  }

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" '
    [
      .items[]
      | {
          name: .metadata.name,
          state: (.status.state // "unknown"),
          robustness: (.status.robustness // "unknown"),
          node: (.status.currentNodeID // "")
        }
      | select(.node == $node and .state == "attached")
      | "\(.name) state=\(.state) robustness=\(.robustness) node=\(.node)"
    ] | .[]
  ' <<<"$volumes_json"
}

node_longhorn_volume_problems() {
  local context="$1"
  local volumes_json

  volumes_json="$(node_get_json "$context" -n longhorn-system volumes.longhorn.io 2>/dev/null || true)"
  [[ -n "$volumes_json" ]] || {
    printf 'Longhorn volumes not readable\n'
    return 0
  }

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
    ] | .[]
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

node_longhorn_replica_problems() {
  local context="$1"
  local node="$2"
  local replicas_json

  replicas_json="$(node_get_json "$context" -n longhorn-system replicas.longhorn.io 2>/dev/null || true)"
  [[ -n "$replicas_json" ]] || {
    printf 'Longhorn replicas not readable\n'
    return 0
  }

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" '
    [
      .items[]
      | select((.spec.nodeID // .status.currentNodeID // "") == $node)
      | {
          name: .metadata.name,
          state: (.status.currentState // .status.state // "unknown"),
          failedAt: (.status.failedAt // "")
        }
      | select(.failedAt != "" or (.state != "running" and .state != "stopped"))
      | "\(.name) state=\(.state) failedAt=\(.failedAt)"
    ] | .[]
  ' <<<"$replicas_json"
}

node_longhorn_replicas_on_node() {
  local context="$1"
  local node="$2"
  local replicas_json

  replicas_json="$(node_get_json "$context" -n longhorn-system replicas.longhorn.io 2>/dev/null || true)"
  [[ -n "$replicas_json" ]] || {
    printf 'Longhorn replicas not readable\n'
    return 0
  }

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" '
    [
      .items[]
      | select((.spec.nodeID // .status.currentNodeID // "") == $node)
      | {
          name: .metadata.name,
          state: (.status.currentState // .status.state // "unknown"),
          failedAt: (.status.failedAt // "")
        }
      | "\(.name) state=\(.state) failedAt=\(.failedAt)"
    ] | .[]
  ' <<<"$replicas_json"
}

node_longhorn_scheduling_problem() {
  local context="$1"
  local node="$2"
  local longhorn_node_json

  longhorn_node_json="$(node_get_json "$context" -n longhorn-system "nodes.longhorn.io/${node}" 2>/dev/null || true)"
  [[ -n "$longhorn_node_json" ]] || {
    printf 'Longhorn node resource not readable: %s\n' "$node"
    return 0
  }

  "$NODE_JQ_BIN" -r '
    select((.spec.allowScheduling // true) != false)
    | "Longhorn scheduling is still enabled"
  ' <<<"$longhorn_node_json"
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

node_longhorn_manager_problems() {
  local context="$1"
  local node="$2"
  local kind="$3"
  local resource="$4"
  local json

  json="$(node_get_json "$context" -n longhorn-system "$resource" 2>/dev/null || true)"
  [[ -n "$json" ]] || {
    printf '%s not readable\n' "$kind"
    return 0
  }

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" --arg kind "$kind" '
    [
      .items[]
      | select((.spec.nodeID // .status.ownerID // .status.currentNodeID // "") == $node)
      | {
          name: .metadata.name,
          state: (.status.currentState // .status.state // "unknown")
        }
      | select(.state != "running")
      | "\($kind)/\(.name) state=\(.state)"
    ] | .[]
  ' <<<"$json"
}

node_assert_longhorn_safe() {
  local context="$1"
  local node="$2"
  local problems state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  problems="$(
    {
      node_longhorn_pod_problems "$context" "$node"
      node_longhorn_volume_problems "$context"
      node_longhorn_replica_problems "$context" "$node"
      node_longhorn_manager_problems "$context" "$node" InstanceManager instancemanagers.longhorn.io
      node_longhorn_manager_problems "$context" "$node" ShareManager sharemanagers.longhorn.io
    } | sed '/^$/d'
  )"

  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    node_die "Longhorn is not in a safe state for ${node}"
  fi
}

node_assert_longhorn_empty_for_delete() {
  local context="$1"
  local node="$2"
  local problems state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  problems="$(
    {
      node_longhorn_scheduling_problem "$context" "$node"
      node_longhorn_attached_volumes_on_node "$context" "$node"
      node_longhorn_replicas_on_node "$context" "$node"
    } | sed '/^$/d'
  )"

  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    node_die "Longhorn still has target-node state; disable scheduling and evict replicas before deleting ${node}"
  fi
}

node_longhorn_uncordon_problems() {
  local context="$1"
  local node="$2"
  local longhorn_node_json

  longhorn_node_json="$(node_get_json "$context" -n longhorn-system "nodes.longhorn.io/${node}" 2>/dev/null || true)"
  [[ -n "$longhorn_node_json" ]] || {
    printf 'Longhorn node resource not readable: %s\n' "$node"
    return 0
  }

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r '
    def condition_status($type):
      ([.status.conditions[]? | select(.type == $type) | .status] | first) // "unknown";
    [
      if ((.spec.allowScheduling // true) != true) then
        "Longhorn scheduling is not enabled"
      else empty end,
      if condition_status("Ready") != "True" then
        "Longhorn node Ready condition is \(condition_status("Ready"))"
      else empty end,
      if condition_status("Schedulable") != "True" then
        "Longhorn node Schedulable condition is \(condition_status("Schedulable"))"
      else empty end
    ] | .[]
  ' <<<"$longhorn_node_json"
}

node_assert_longhorn_ready_for_uncordon() {
  local context="$1"
  local node="$2"
  local problems state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  problems="$(node_longhorn_uncordon_problems "$context" "$node")"
  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    node_die "Longhorn node is not ready for uncordon: ${node}"
  fi
}

node_ansible_ping() {
  local profile="$1"
  local inventory_node="$2"
  local inventory_file

  inventory_file="$(node_ansible_inventory_file "$profile")"
  node_require_tool ansible
  if ! ANSIBLE_HOST_KEY_CHECKING=False ansible \
    -i "$inventory_file" \
    "$inventory_node" \
    -m ansible.builtin.ping; then
    node_die "Ansible could not reach ${inventory_node}; if the host was rebuilt, run the SSH host-key refresh helper"
  fi
}

node_stop_k3s_agent() {
  local profile="$1"
  local inventory_node="$2"
  local inventory_file

  inventory_file="$(node_ansible_inventory_file "$profile")"
  node_require_tool ansible
  ANSIBLE_HOST_KEY_CHECKING=False ansible \
    -i "$inventory_file" \
    "$inventory_node" \
    --become \
    -m ansible.builtin.systemd \
    -a "name=k3s-node enabled=false state=stopped"
}

node_run_worker_ansible_action() {
  local profile="$1"
  local inventory_node="$2"
  local action="$3"
  local -a args

  args=(--profile "$profile" --action "$action")
  case "$profile" in
    live)
      args+=(--inventory-source "$NODE_LIVE_INVENTORY_DIR")
      ;;
    lima)
      args+=(--inventory-dir "$NODE_LIMA_INVENTORY_DIR")
      ;;
  esac

  NODE_WORKER_ANSIBLE_INTERNAL=true "${BOOTSTRAP_DIR}/ansible/node-worker.sh" "${args[@]}" "$inventory_node"
}

node_wait_for_node_json() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))
  local node_json

  while true; do
    node_json="$(node_node_json_if_present "$context" "$node")"
    if [[ -n "$node_json" ]]; then
      printf '%s\n' "$node_json"
      return 0
    fi
    ((SECONDS < deadline)) || node_die "timed out waiting for node object: ${node}"
    sleep 5
  done
}

node_wait_for_node_absent() {
  local context="$1"
  local node="$2"
  local timeout="${3:-180}"
  local deadline=$((SECONDS + timeout))

  while true; do
    if ! node_has_resource "$context" "node/${node}"; then
      return 0
    fi
    ((SECONDS < deadline)) || node_die "timed out waiting for node deletion: ${node}"
    sleep 5
  done
}

node_wait_for_ready() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))
  local node_json ready

  while true; do
    node_json="$(node_node_json_if_present "$context" "$node")"
    if [[ -n "$node_json" ]]; then
      ready="$(node_ready_from_node_json <<<"$node_json")"
      [[ "$ready" == Ready ]] && return 0
    fi
    ((SECONDS < deadline)) || node_die "timed out waiting for node Ready: ${node}"
    sleep 5
  done
}

node_wait_for_cilium_ready() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))

  while true; do
    if (node_assert_cilium_ready "$context" "$node") >/dev/null 2>&1; then
      return 0
    fi
    ((SECONDS < deadline)) || node_assert_cilium_ready "$context" "$node"
    sleep 5
  done
}

node_wait_for_longhorn_safe() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))

  while true; do
    if (node_assert_longhorn_safe "$context" "$node") >/dev/null 2>&1; then
      return 0
    fi
    ((SECONDS < deadline)) || node_assert_longhorn_safe "$context" "$node"
    sleep 5
  done
}

node_wait_for_longhorn_ready_for_uncordon() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))

  while true; do
    if (node_assert_longhorn_ready_for_uncordon "$context" "$node") >/dev/null 2>&1; then
      return 0
    fi
    ((SECONDS < deadline)) || node_assert_longhorn_ready_for_uncordon "$context" "$node"
    sleep 5
  done
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
