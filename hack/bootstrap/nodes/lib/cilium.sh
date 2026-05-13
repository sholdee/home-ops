# shellcheck shell=bash

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
