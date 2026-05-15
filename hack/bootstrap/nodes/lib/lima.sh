# shellcheck shell=bash

node_lima_out_dir() {
  printf '%s\n' "$(dirname "$NODE_LIMA_INVENTORY_DIR")"
}

node_lima_tunnel_pid_file() {
  printf '%s/apiserver-tunnel.pid\n' "$(node_lima_out_dir)"
}

node_lima_tunnel_port_open() {
  local port="$1"
  command -v nc >/dev/null 2>&1 || return 1
  nc -z 127.0.0.1 "$port" >/dev/null 2>&1
}

node_lima_tunnel_listener_pid() {
  local port="$1"
  lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -n 1 || true
}

node_stop_lima_api_tunnel() {
  local pid_file pid
  pid_file="$(node_lima_tunnel_pid_file)"
  [[ -f "$pid_file" ]] || return 0
  pid="$(<"$pid_file")"
  if [[ -n "$pid" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$pid_file"
}

node_start_lima_api_tunnel_to_inventory_node() {
  local inventory_node="$1"
  local context="$2"
  local ssh_config pid_file pid port candidate_port cluster_name

  node_require_tool ssh
  node_require_tool nc
  node_require_tool lsof
  node_require_tool "$NODE_KUBECTL_BIN"
  node_require_tool "$NODE_JQ_BIN"
  ssh_config="${HOME}/.lima/${inventory_node}/ssh.config"
  [[ -f "$ssh_config" ]] || node_die "missing Lima SSH config for ${inventory_node}: ${ssh_config}"
  pid_file="$(node_lima_tunnel_pid_file)"

  node_stop_lima_api_tunnel
  port=""
  for candidate_port in $(seq "$NODE_LIMA_KUBECONFIG_PORT" $((NODE_LIMA_KUBECONFIG_PORT + 20))); do
    if ! node_lima_tunnel_port_open "$candidate_port"; then
      port="$candidate_port"
      break
    fi
  done
  [[ -n "$port" ]] || node_die "could not find an available local port for Lima API handoff"

  mkdir -p "$(node_lima_out_dir)"
  ssh -F "$ssh_config" -S none -fN \
    -o ControlMaster=no \
    -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:${port}:127.0.0.1:6443" \
    "lima-${inventory_node}"
  for _ in $(seq 1 30); do
    if node_lima_tunnel_port_open "$port"; then
      pid="$(node_lima_tunnel_listener_pid "$port")"
      [[ -n "$pid" ]] || node_die "could not identify Lima API tunnel PID on 127.0.0.1:${port}"
      printf '%s\n' "$pid" > "$pid_file"
      # shellcheck disable=SC2016
      cluster_name="$("$NODE_KUBECTL_BIN" config view -o json |
        "$NODE_JQ_BIN" -r --arg context "$context" '
          (.contexts[]? | select(.name == $context) | .context.cluster) // $context
        ')"
      "$NODE_KUBECTL_BIN" config set-cluster "$cluster_name" \
        --server="https://127.0.0.1:${port}" \
        --insecure-skip-tls-verify=true >/dev/null
      "$NODE_KUBECTL_BIN" config unset "clusters.${cluster_name}.certificate-authority-data" >/dev/null 2>&1 || true
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 1
  done
  pid="$(node_lima_tunnel_listener_pid "$port")"
  [[ -z "$pid" ]] || kill "$pid" >/dev/null 2>&1 || true
  rm -f "$pid_file"
  node_die "timed out waiting for Lima API tunnel through ${inventory_node}"
}

node_handoff_control_plane_api_if_needed() {
  local profile="$1"
  local context="$2"
  local inventory_node="$3"
  local kubernetes_node="$4"
  local alternate_inventory_node alternate_kubernetes_node handoff_error
  local -a alternate_inventory_nodes

  case "$profile" in
    lima)
      mapfile -t alternate_inventory_nodes < <(
        node_alternate_ready_control_plane_inventory_nodes "$profile" "$context" "$kubernetes_node" true
      )
      ((${#alternate_inventory_nodes[@]} > 0)) ||
        node_die "no alternate inventory control-plane is available for API handoff"

      for alternate_inventory_node in "${alternate_inventory_nodes[@]}"; do
        alternate_kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$alternate_inventory_node" "$alternate_inventory_node")"
        node_log "retargeting Lima API tunnel away from ${inventory_node} to ${alternate_inventory_node}"
        if handoff_error="$(
          (
            node_start_lima_api_tunnel_to_inventory_node "$alternate_inventory_node" "$context" >/dev/null
            node_assert_api_reachable "$context"
            alternate_node_json="$(node_node_json_if_present "$context" "$alternate_kubernetes_node")"
            [[ -n "$alternate_node_json" ]] ||
              node_die "Lima API tunnel handoff did not reach alternate control-plane node: ${alternate_kubernetes_node}"
            node_assert_kubernetes_control_plane "$alternate_node_json" "$alternate_kubernetes_node"
            node_assert_ready "$alternate_node_json" "$alternate_kubernetes_node"
          ) 2>&1
        )"; then
          return 0
        fi
        node_warn "Lima API handoff candidate ${alternate_inventory_node} failed: ${handoff_error//$'\n'/; }"
      done

      node_die "no alternate inventory control-plane served a reachable Lima API"
      ;;
    live)
      node_is_first_inventory_master "$profile" "$inventory_node" || return 0
      node_assert_live_first_master_api_is_stable "$profile" "$context" "$inventory_node" "$kubernetes_node"
      node_log "first inventory master selected; live context must remain reachable through the stable API endpoint"
      node_assert_api_reachable "$context"
      ;;
  esac
}
