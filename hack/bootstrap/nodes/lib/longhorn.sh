# shellcheck shell=bash

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
    def allow_scheduling:
      if ((.spec // {}) | has("allowScheduling")) then .spec.allowScheduling else true end;
    def eviction_requested:
      if ((.spec // {}) | has("evictionRequested")) then .spec.evictionRequested else false end;
    def condition_status($type):
      ([.status.conditions[]? | select(.type == $type) | .status] | first) // "unknown";
    "allowScheduling=\(allow_scheduling | tostring) evictionRequested=\(eviction_requested | tostring) ready=\(condition_status("Ready")) schedulable=\(condition_status("Schedulable"))"
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

node_longhorn_volume_delete_blockers() {
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
          specNode: (.spec.nodeID // ""),
          currentNode: (.status.currentNodeID // "")
        }
      | select(.specNode == $node or .currentNode == $node)
      | "\(.name) state=\(.state) robustness=\(.robustness) specNode=\(.specNode) currentNode=\(.currentNode) reason=volume-still-targets-node"
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

node_longhorn_replica_delete_safety_jq() {
  cat <<'EOF'
($volumes[0].items // []) as $volume_items |
def node_id:
  (.spec.nodeID // .status.currentNodeID // .metadata.labels.longhornnode // "");
def volume_name:
  (.spec.volumeName // .metadata.labels.longhornvolume // "");
def replica_state:
  (.status.currentState // .status.state // "unknown");
def desire_state:
  (.spec.desireState // "");
def failed_at:
  (.spec.failedAt // .status.failedAt // "");
def healthy_at:
  (.spec.healthyAt // .status.healthyAt // "");
def healthy_replica:
  failed_at == "" and
  healthy_at != "" and
  (replica_state == "running" or replica_state == "stopped");
def running_replica:
  replica_state == "running" or
  (.status.started // false) == true or
  ((.status.instanceManagerName // "") != "");
def volume_by_name($name):
  first($volume_items[]? | select(.metadata.name == $name)) // null;
def target_node_replica_delete_safety:
  (.items // []) as $all_replicas |
  $all_replicas[]
  | select(node_id == $node)
  | (volume_name) as $volume_name
  | (volume_by_name($volume_name)) as $volume
  | ($volume.spec.numberOfReplicas // 1 | tonumber? // 1) as $desired_replicas
  | ([ $all_replicas[]
      | select(volume_name == $volume_name)
      | select(node_id != $node)
      | select(healthy_replica)
    ] | length) as $healthy_elsewhere
  | {
      name: (.metadata.name // "unknown"),
      volume: $volume_name,
      state: replica_state,
      desireState: desire_state,
      failedAt: failed_at,
      healthyElsewhere: $healthy_elsewhere,
      desiredReplicas: $desired_replicas,
      volumeFound: ($volume != null),
      running: running_replica,
      safeToDelete: (
        ($volume != null) and
        (running_replica | not) and
        replica_state == "stopped" and
        desire_state == "stopped" and
        $healthy_elsewhere >= $desired_replicas
      )
    };
EOF
}

node_longhorn_replica_delete_blockers() {
  local context="$1"
  local node="$2"
  local replicas_json volumes_json jq_defs jq_filter

  replicas_json="$(node_get_json "$context" -n longhorn-system replicas.longhorn.io 2>/dev/null || true)"
  [[ -n "$replicas_json" ]] || {
    printf 'Longhorn replicas not readable\n'
    return 0
  }

  volumes_json="$(node_get_json "$context" -n longhorn-system volumes.longhorn.io 2>/dev/null || true)"
  [[ -n "$volumes_json" ]] || {
    printf 'Longhorn volumes not readable\n'
    return 0
  }

  # A stopped target-node replica is not itself a running process, and Longhorn
  # may keep it around temporarily after rebuilding healthy copies elsewhere.
  # For node replacement it is only safe to ignore when the desired healthy
  # replica count is already present on other nodes.
  jq_defs="$(node_longhorn_replica_delete_safety_jq)"
  jq_filter="$(printf '%s\n%s\n' "$jq_defs" '
    target_node_replica_delete_safety
    | if (.volumeFound | not) then
        "\(.name) volume=\(.volume) state=\(.state) desired=\(.desireState) failedAt=\(.failedAt) reason=volume-not-found"
      elif .running then
        "\(.name) volume=\(.volume) state=\(.state) desired=\(.desireState) failedAt=\(.failedAt) reason=replica-still-running"
      elif .state != "stopped" or .desireState != "stopped" then
        "\(.name) volume=\(.volume) state=\(.state) desired=\(.desireState) failedAt=\(.failedAt) reason=replica-not-stopped"
      elif .healthyElsewhere < .desiredReplicas then
        "\(.name) volume=\(.volume) state=\(.state) healthyElsewhere=\(.healthyElsewhere)/\(.desiredReplicas) reason=insufficient-healthy-replicas-elsewhere"
      else
        empty
      end
  ')"
  "$NODE_JQ_BIN" -r --arg node "$node" --slurpfile volumes <(printf '%s\n' "$volumes_json") "$jq_filter" <<<"$replicas_json"
}

node_longhorn_engine_delete_blockers() {
  local context="$1"
  local node="$2"
  local engines_json

  engines_json="$(node_get_json "$context" -n longhorn-system engines.longhorn.io 2>/dev/null || true)"
  [[ -n "$engines_json" ]] || {
    printf 'Longhorn engines not readable\n'
    return 0
  }

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" '
    [
      .items[]
      | {
          name: .metadata.name,
          volume: (.spec.volumeName // .metadata.labels.longhornvolume // ""),
          state: (.status.currentState // .status.state // "unknown"),
          desireState: (.spec.desireState // ""),
          specNode: (.spec.nodeID // ""),
          currentNode: (.status.currentNodeID // ""),
          ownerNode: (.status.ownerID // "")
        }
      | select(.specNode == $node or .currentNode == $node or .ownerNode == $node)
      | "\(.name) volume=\(.volume) state=\(.state) desired=\(.desireState) specNode=\(.specNode) currentNode=\(.currentNode) owner=\(.ownerNode) reason=engine-still-targets-node"
    ] | .[]
  ' <<<"$engines_json"
}

node_longhorn_safe_stale_replicas_for_deleted_node() {
  local context="$1"
  local node="$2"
  local replicas_json volumes_json jq_defs jq_filter

  replicas_json="$(node_get_json "$context" -n longhorn-system replicas.longhorn.io 2>/dev/null || true)"
  [[ -n "$replicas_json" ]] || {
    printf 'Longhorn replicas not readable\n'
    return 0
  }

  volumes_json="$(node_get_json "$context" -n longhorn-system volumes.longhorn.io 2>/dev/null || true)"
  [[ -n "$volumes_json" ]] || {
    printf 'Longhorn volumes not readable\n'
    return 0
  }

  # These replicas are safe to delete only after the Kubernetes node is gone.
  jq_defs="$(node_longhorn_replica_delete_safety_jq)"
  jq_filter="$(printf '%s\n%s\n' "$jq_defs" '
    target_node_replica_delete_safety
    | select(.safeToDelete)
    | .name
  ')"
  "$NODE_JQ_BIN" -r --arg node "$node" --slurpfile volumes <(printf '%s\n' "$volumes_json") "$jq_filter" <<<"$replicas_json"
}

node_longhorn_max_replica_count() {
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
      | (.spec.numberOfReplicas // 0)
      | tonumber
    ] | max // 0
  ' <<<"$volumes_json"
}

node_longhorn_eligible_storage_node_count_excluding() {
  local context="$1"
  local node="$2"
  local nodes_json

  nodes_json="$(node_get_json "$context" -n longhorn-system nodes.longhorn.io 2>/dev/null || true)"
  [[ -n "$nodes_json" ]] || {
    printf 'Longhorn nodes not readable\n'
    return 0
  }

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -r --arg node "$node" '
    def allow_scheduling:
      if ((.spec // {}) | has("allowScheduling")) then .spec.allowScheduling else true end;
    def condition_status($type):
      ([.status.conditions[]? | select(.type == $type) | .status] | first) // "unknown";
    [
      .items[]
      | select(.metadata.name != $node)
      | select(allow_scheduling == true)
      | select(condition_status("Ready") == "True")
      | select(condition_status("Schedulable") == "True")
    ] | length
  ' <<<"$nodes_json"
}

node_longhorn_scheduling_problem() {
  local context="$1"
  local node="$2"
  local longhorn_node_json

  longhorn_node_json="$(node_get_json "$context" -n longhorn-system "nodes.longhorn.io/${node}" 2>/dev/null || true)"
  [[ -n "$longhorn_node_json" ]] || return 0

  "$NODE_JQ_BIN" -r '
    def allow_scheduling:
      if ((.spec // {}) | has("allowScheduling")) then .spec.allowScheduling else true end;
    select(allow_scheduling != false)
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

node_longhorn_managers_on_node() {
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
      | "\($kind)/\(.name) state=\(.state)"
    ] | .[]
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

node_assert_longhorn_maintenance_safe() {
  local context="$1"
  local node="$2"
  local problems state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  problems="$(
    {
      node_longhorn_attached_volumes_on_node "$context" "$node"
    } | sed '/^$/d'
  )"

  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    node_die "Longhorn volumes are still attached to ${node}; wait for workloads to move before maintenance"
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
      node_longhorn_volume_delete_blockers "$context" "$node"
      node_longhorn_engine_delete_blockers "$context" "$node"
      node_longhorn_replica_delete_blockers "$context" "$node"
    } | sed '/^$/d'
  )"

  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    node_die "Longhorn still has target-node state; run the explicit Longhorn eviction helper before deleting ${node}, or wait for reported deleted-node blockers to clear before resuming cleanup"
  fi
}

node_assert_longhorn_eviction_feasible() {
  local context="$1"
  local node="$2"
  local state max_replicas eligible_nodes problems

  state="$(node_assert_longhorn_discovery "$context")"
  [[ "$state" == installed ]] || node_die "Longhorn is not installed in ${context}"

  max_replicas="$(node_longhorn_max_replica_count "$context")"
  [[ "$max_replicas" =~ ^[0-9]+$ ]] || node_die "$max_replicas"
  eligible_nodes="$(node_longhorn_eligible_storage_node_count_excluding "$context" "$node")"
  [[ "$eligible_nodes" =~ ^[0-9]+$ ]] || node_die "$eligible_nodes"

  problems="$(
    {
      if ((max_replicas > eligible_nodes)); then
        printf 'Longhorn eviction is not feasible: max volume replicas=%s, eligible storage nodes after removing target=%s\n' \
          "$max_replicas" "$eligible_nodes"
        printf 'Add another storage node or temporarily lower replica counts before replacing %s; use drain/uncordon for reboot maintenance.\n' \
          "$node"
      fi
      node_longhorn_attached_volumes_on_node "$context" "$node"
    } | sed '/^$/d'
  )"

  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    node_die "Longhorn cannot safely evict ${node}"
  fi
}

node_request_longhorn_eviction() {
  local context="$1"
  local node="$2"

  if ! node_has_resource "$context" -n longhorn-system "nodes.longhorn.io/${node}"; then
    node_log "Longhorn node resource is absent for ${node}; no eviction request needed"
    return 0
  fi

  node_kubectl "$context" -n longhorn-system patch "nodes.longhorn.io/${node}" \
    --type=merge \
    -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
}

node_restore_longhorn_scheduling() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))
  local output state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  node_wait_for_longhorn_node_resource "$context" "$node"
  while true; do
    if output="$(node_kubectl "$context" -n longhorn-system patch "nodes.longhorn.io/${node}" \
      --type=merge \
      -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}' 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    ((SECONDS < deadline)) || {
      printf '%s\n' "$output" >&2
      node_die "timed out restoring Longhorn scheduling for ${node}"
    }
    sleep 5
  done
}

node_wait_for_longhorn_node_resource() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))
  local state longhorn_node_json

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  while true; do
    longhorn_node_json="$(node_get_json "$context" -n longhorn-system "nodes.longhorn.io/${node}" 2>/dev/null || true)"
    if [[ -n "$longhorn_node_json" ]]; then
      return 0
    fi
    ((SECONDS < deadline)) || node_die "timed out waiting for Longhorn node resource: ${node}"
    sleep 5
  done
}

node_wait_for_longhorn_node_absent() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))
  local state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  while true; do
    if ! node_has_resource "$context" -n longhorn-system "nodes.longhorn.io/${node}"; then
      return 0
    fi
    ((SECONDS < deadline)) || node_die "timed out waiting for Longhorn node deletion: ${node}"
    sleep 5
  done
}

node_wait_for_longhorn_replicas_absent() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))
  local replicas

  while true; do
    replicas="$(node_longhorn_replicas_on_node "$context" "$node" | sed '/^$/d')"
    if [[ -z "$replicas" ]]; then
      return 0
    fi
    ((SECONDS < deadline)) || {
      printf '%s\n' "$replicas" >&2
      node_die "timed out waiting for Longhorn replicas to disappear from deleted node: ${node}"
    }
    sleep 5
  done
}

node_cleanup_longhorn_deleted_node() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local state stale_replicas replica

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  if node_has_resource "$context" "node/${node}"; then
    node_die "refusing to clean Longhorn deleted-node state while Kubernetes node still exists: ${node}"
  fi

  if ! node_has_resource "$context" -n longhorn-system "nodes.longhorn.io/${node}"; then
    return
  fi

  node_assert_longhorn_empty_for_delete "$context" "$node"
  stale_replicas="$(node_longhorn_safe_stale_replicas_for_deleted_node "$context" "$node" | sed '/^$/d')"
  if [[ -n "$stale_replicas" ]]; then
    while IFS= read -r replica; do
      [[ -n "$replica" ]] || continue
      node_log "deleting safe stale Longhorn replica ${replica} from deleted node ${node}"
      node_kubectl "$context" -n longhorn-system delete replicas.longhorn.io "$replica" \
        --wait=false \
        --ignore-not-found
    done <<<"$stale_replicas"
    node_wait_for_longhorn_replicas_absent "$context" "$node" "$timeout"
  fi

  node_log "deleting Longhorn node resource for deleted node ${node}"
  node_kubectl "$context" -n longhorn-system delete "nodes.longhorn.io/${node}" \
    --wait=false \
    --ignore-not-found
  node_wait_for_longhorn_node_absent "$context" "$node" "$timeout"
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
    def allow_scheduling:
      if ((.spec // {}) | has("allowScheduling")) then .spec.allowScheduling else true end;
    def eviction_requested:
      if ((.spec // {}) | has("evictionRequested")) then .spec.evictionRequested else false end;
    def condition_status($type):
      ([.status.conditions[]? | select(.type == $type) | .status] | first) // "unknown";
    [
      if allow_scheduling != true then
        "Longhorn scheduling is not enabled"
      else empty end,
      if eviction_requested != false then
        "Longhorn eviction is still requested"
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

node_longhorn_ready_for_kubernetes_uncordon_problems() {
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
    def allow_scheduling:
      if ((.spec // {}) | has("allowScheduling")) then .spec.allowScheduling else true end;
    def eviction_requested:
      if ((.spec // {}) | has("evictionRequested")) then .spec.evictionRequested else false end;
    def condition_status($type):
      ([.status.conditions[]? | select(.type == $type) | .status] | first) // "unknown";
    [
      if allow_scheduling != true then
        "Longhorn scheduling is not enabled"
      else empty end,
      if eviction_requested != false then
        "Longhorn eviction is still requested"
      else empty end,
      if condition_status("Ready") != "True" then
        "Longhorn node Ready condition is \(condition_status("Ready"))"
      else empty end
    ] | .[]
  ' <<<"$longhorn_node_json"
}

node_assert_longhorn_ready_for_kubernetes_uncordon() {
  local context="$1"
  local node="$2"
  local problems state

  state="$(node_assert_longhorn_discovery "$context")"
  if [[ "$state" == absent ]]; then
    return
  fi

  problems="$(node_longhorn_ready_for_kubernetes_uncordon_problems "$context" "$node")"
  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    node_die "Longhorn node is not ready for Kubernetes uncordon: ${node}"
  fi
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
