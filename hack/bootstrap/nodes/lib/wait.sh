# shellcheck shell=bash

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

node_wait_for_schedulable() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))
  local node_json

  while true; do
    node_json="$(node_node_json_if_present "$context" "$node")"
    if [[ -n "$node_json" ]] && (node_assert_schedulable "$node_json" "$node") >/dev/null 2>&1; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      [[ -n "$node_json" ]] || node_die "Kubernetes node disappeared while waiting for uncordon: ${node}"
      node_assert_schedulable "$node_json" "$node"
    fi
    sleep 2
  done
}

node_wait_for_boot_id_change() {
  local context="$1"
  local node="$2"
  local previous_boot_id="$3"
  local timeout="${4:-600}"
  local deadline=$((SECONDS + timeout))
  local node_json ready boot_id

  [[ -n "$previous_boot_id" ]] ||
    node_die "previous bootID is required to verify reboot completion: ${node}"

  while true; do
    node_json="$(node_node_json_if_present "$context" "$node")"
    if [[ -n "$node_json" ]]; then
      ready="$(node_ready_from_node_json <<<"$node_json")"
      boot_id="$(node_boot_id_from_node_json <<<"$node_json")"
      if [[ "$ready" == Ready && -n "$boot_id" && "$boot_id" != "$previous_boot_id" ]]; then
        return 0
      fi
    fi
    ((SECONDS < deadline)) || node_die "timed out waiting for node reboot: ${node}"
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

node_wait_for_stable_assertion() {
  local timeout="$1"
  local stable_for="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  local stable_since=""

  while true; do
    if ("$@") >/dev/null 2>&1; then
      if [[ -z "$stable_since" ]]; then
        stable_since="$SECONDS"
      fi
      if ((SECONDS - stable_since >= stable_for)); then
        return 0
      fi
    else
      stable_since=""
    fi

    if ((SECONDS >= deadline)); then
      "$@"
      return 1
    fi
    sleep 5
  done
}

node_wait_for_longhorn_storage_idle() {
  local context="$1"
  local timeout="${2:-1800}"
  local stable_for="${3:-60}"
  local state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  node_wait_for_stable_assertion \
    "$timeout" \
    "$stable_for" \
    node_assert_longhorn_storage_idle \
    "$context"
}

node_wait_for_longhorn_replacement_ready() {
  local context="$1"
  local timeout="${2:-1800}"
  local stable_for="${3:-60}"
  local state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  node_wait_for_stable_assertion \
    "$timeout" \
    "$stable_for" \
    node_assert_longhorn_replacement_ready \
    "$context"
}

node_wait_for_longhorn_maintenance_safe() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))

  while true; do
    if (node_assert_longhorn_maintenance_safe "$context" "$node") >/dev/null 2>&1; then
      return 0
    fi
    ((SECONDS < deadline)) || node_assert_longhorn_maintenance_safe "$context" "$node"
    sleep 5
  done
}

node_wait_for_longhorn_empty_for_delete() {
  local context="$1"
  local node="$2"
  local timeout="${3:-1800}"
  local deadline=$((SECONDS + timeout))

  while true; do
    if (node_assert_longhorn_empty_for_delete "$context" "$node") >/dev/null 2>&1; then
      return 0
    fi
    ((SECONDS < deadline)) || node_assert_longhorn_empty_for_delete "$context" "$node"
    sleep 10
  done
}

node_wait_for_longhorn_ready_for_kubernetes_uncordon() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))

  while true; do
    if (node_assert_longhorn_ready_for_kubernetes_uncordon "$context" "$node") >/dev/null 2>&1; then
      return 0
    fi
    ((SECONDS < deadline)) || node_assert_longhorn_ready_for_kubernetes_uncordon "$context" "$node"
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

node_ready_control_plane_internal_ip() {
  local context="$1"
  local node="$2"
  local node_json

  node_json="$(node_node_json_if_present "$context" "$node")"
  [[ -n "$node_json" ]] || node_die "Kubernetes node is absent: ${node}"
  "$NODE_JQ_BIN" -r '
    [
      .status.addresses[]?
      | select(.type == "InternalIP")
      | .address
    ] | first // ""
  ' <<<"$node_json"
}

node_alternate_ready_control_plane_inventory_nodes() {
  local profile="$1"
  local context="$2"
  local target_kubernetes_node="$3"
  local allow_inventory_fallback="${4:-false}"
  local inventory_master probe_kubernetes_node
  local -a inventory_masters ready_control_planes

  mapfile -t inventory_masters < <(node_inventory_group_names "$profile" master)
  mapfile -t ready_control_planes < <(node_ready_control_planes "$context")

  for inventory_master in "${inventory_masters[@]}"; do
    probe_kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_master" "$inventory_master")"
    if [[ "$probe_kubernetes_node" != "$target_kubernetes_node" ]] &&
      node_contains_line "$probe_kubernetes_node" "${ready_control_planes[@]}"; then
      printf '%s\n' "$inventory_master"
    fi
  done

  if [[ ${#ready_control_planes[@]} -eq 0 ]] && node_bool "$allow_inventory_fallback"; then
    for inventory_master in "${inventory_masters[@]}"; do
      probe_kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_master" "$inventory_master")"
      if [[ "$probe_kubernetes_node" != "$target_kubernetes_node" ]]; then
        printf '%s\n' "$inventory_master"
      fi
    done
  fi
}

node_alternate_ready_control_plane_inventory_node() {
  local candidate
  candidate="$(node_alternate_ready_control_plane_inventory_nodes "$@" | sed -n '1p')"
  [[ -n "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

node_alternate_ready_control_plane_internal_ip() {
  local profile="$1"
  local context="$2"
  local target_kubernetes_node="$3"
  local alternate_inventory_node alternate_kubernetes_node alternate_internal_ip

  alternate_inventory_node="$(node_alternate_ready_control_plane_inventory_node "$profile" "$context" "$target_kubernetes_node")" ||
    node_die "no alternate Ready control-plane node is available for ${target_kubernetes_node}"
  alternate_kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$alternate_inventory_node" "$alternate_inventory_node")"
  alternate_internal_ip="$(node_ready_control_plane_internal_ip "$context" "$alternate_kubernetes_node")"
  [[ -n "$alternate_internal_ip" && "$alternate_internal_ip" != "null" ]] ||
    node_die "could not determine InternalIP for alternate control-plane node: ${alternate_kubernetes_node}"
  printf '%s\n' "$alternate_internal_ip"
}
