# shellcheck shell=bash

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

node_current_context() {
  "$NODE_KUBECTL_BIN" config current-context
}

node_assert_current_context() {
  local context="$1"
  local current_context
  current_context="$(node_current_context)"
  [[ "$current_context" == "$context" ]] ||
    node_die "active kube context must be ${context}; current context is ${current_context}"
}

node_wait_for_api_reachable() {
  local context="$1"
  local timeout="${2:-180}"
  local deadline=$((SECONDS + timeout))

  while true; do
    if (node_assert_api_reachable "$context") >/dev/null 2>&1; then
      return 0
    fi
    ((SECONDS < deadline)) || node_assert_api_reachable "$context"
    sleep 5
  done
}

node_context_cluster_server() {
  local context="$1"
  local config_json cluster_name server

  config_json="$("$NODE_KUBECTL_BIN" config view -o json)"
  # shellcheck disable=SC2016
  cluster_name="$("$NODE_JQ_BIN" -r --arg context "$context" '
    (.contexts[]? | select(.name == $context) | .context.cluster) // ""
  ' <<<"$config_json")"
  [[ -n "$cluster_name" && "$cluster_name" != "null" ]] ||
    node_die "could not find kubeconfig context: ${context}"
  # shellcheck disable=SC2016
  server="$("$NODE_JQ_BIN" -r --arg cluster "$cluster_name" '
    (.clusters[]? | select(.name == $cluster) | .cluster.server) // ""
  ' <<<"$config_json")"
  [[ -n "$server" && "$server" != "null" ]] ||
    node_die "could not find kubeconfig server for context: ${context}"
  printf '%s\n' "$server"
}

node_url_host() {
  local url="$1"
  local host

  host="${url#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  host="${host#[}"
  host="${host%]}"
  printf '%s\n' "$host"
}

node_assert_live_first_master_api_is_stable() {
  local profile="$1"
  local context="$2"
  local inventory_node="$3"
  local kubernetes_node="$4"
  local server server_host target_ansible_host node_json node_internal_ip

  [[ "$profile" == live ]] || return 0
  node_is_first_inventory_master "$profile" "$inventory_node" || return 0

  server="$(node_context_cluster_server "$context")"
  server_host="$(node_url_host "$server")"
  case "$server_host" in
    localhost|127.*|::1)
      node_die "live first-master lifecycle requires a stable API endpoint; kubeconfig server is local: ${server}"
      ;;
  esac

  target_ansible_host="$(node_inventory_value "$profile" "$inventory_node" ansible_host 2>/dev/null || true)"
  node_json="$(node_node_json_if_present "$context" "$kubernetes_node")"
  node_internal_ip=""
  if [[ -n "$node_json" ]]; then
    node_internal_ip="$(node_ready_control_plane_internal_ip "$context" "$kubernetes_node")"
  fi

  if [[ "$server_host" == "$inventory_node" ||
    "$server_host" == "$kubernetes_node" ||
    (-n "$target_ansible_host" && "$server_host" == "$target_ansible_host") ||
    (-n "$node_internal_ip" && "$server_host" == "$node_internal_ip") ]]; then
    node_die "live first-master lifecycle requires a stable API endpoint; kubeconfig server points at target node ${kubernetes_node}: ${server}"
  fi
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
      node_die "use the control-plane lifecycle path for this node: ${inventory_node}"
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

node_assert_inventory_control_plane() {
  local inventory_node="$1"
  local inventory_role="$2"

  case "$inventory_role" in
    master)
      ;;
    node)
      node_die "node is a worker in the selected inventory: ${inventory_node}"
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
    node_die "use the control-plane lifecycle path for this node: ${node}"
}

node_assert_kubernetes_control_plane() {
  local node_json="$1"
  local node="$2"
  local k8s_role

  k8s_role="$(node_k8s_role_from_node_json <<<"$node_json")"
  [[ "$k8s_role" == control-plane ]] ||
    node_die "node is not a Kubernetes control-plane node: ${node}"
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
