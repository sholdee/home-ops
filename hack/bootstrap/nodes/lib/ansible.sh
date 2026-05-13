# shellcheck shell=bash

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

node_stop_k3s_server() {
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
    -a "name=k3s enabled=false state=stopped"
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

node_run_control_plane_ansible_action() {
  local profile="$1"
  local inventory_node="$2"
  local action="$3"
  local join_ip="${4:-}"
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
  if [[ -n "$join_ip" ]]; then
    args+=(--join-ip "$join_ip")
  fi

  NODE_CONTROL_PLANE_ANSIBLE_INTERNAL=true "${BOOTSTRAP_DIR}/ansible/node-control-plane.sh" "${args[@]}" "$inventory_node"
}
