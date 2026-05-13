# shellcheck shell=bash

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

node_pods_on_node() {
  local context="$1"
  local node="$2"
  local pods_json
  pods_json="$(node_get_json "$context" pods -A --field-selector "spec.nodeName=${node}" 2>/dev/null || true)"
  [[ -n "$pods_json" ]] || {
    printf 'pods are not readable for %s\n' "$node"
    return 0
  }
  "$NODE_JQ_BIN" -r '
    def owner_kind:
      (.metadata.ownerReferences // [] | map(.kind) | join(","));
    .items[]
    | select(.status.phase != "Succeeded")
    | [
        .metadata.namespace,
        .metadata.name,
        (.status.phase // "unknown"),
        owner_kind
      ]
    | @tsv
  ' <<<"$pods_json"
}

node_delete_stale_pods_for_deleted_node() {
  local context="$1"
  local node="$2"
  local pods namespace name _phase _owner

  if node_has_resource "$context" "node/${node}"; then
    node_die "refusing to delete node-bound pods while Kubernetes node still exists: ${node}"
  fi

  pods="$(node_pods_on_node "$context" "$node" | sed '/^$/d')"
  [[ -n "$pods" ]] || return 0

  while IFS=$'\t' read -r namespace name _phase _owner; do
    [[ -n "$namespace" && -n "$name" ]] || continue
    node_log "deleting stale pod ${namespace}/${name} bound to deleted node ${node}"
    node_kubectl "$context" -n "$namespace" delete pod "$name" \
      --grace-period=0 \
      --force \
      --wait=false \
      --ignore-not-found
  done <<<"$pods"
}

node_wait_for_deleted_node_pods_absent() {
  local context="$1"
  local node="$2"
  local timeout="${3:-300}"
  local deadline=$((SECONDS + timeout))
  local pods

  while true; do
    pods="$(node_pods_on_node "$context" "$node" | sed '/^$/d')"
    if [[ -z "$pods" ]]; then
      return 0
    fi
    ((SECONDS < deadline)) || {
      printf '%s\n' "$pods" >&2
      node_die "timed out waiting for stale node-bound pods to disappear: ${node}"
    }
    sleep 5
  done
}

node_cleanup_pods_for_deleted_node() {
  local context="$1"
  local node="$2"

  node_wait_for_node_absent "$context" "$node"
  node_delete_stale_pods_for_deleted_node "$context" "$node"
  node_wait_for_deleted_node_pods_absent "$context" "$node"
}
