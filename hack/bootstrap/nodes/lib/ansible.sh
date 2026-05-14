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
  local stop_script

  inventory_file="$(node_ansible_inventory_file "$profile")"
  # shellcheck disable=SC2016
  stop_script='
set -eu
for service_name in k3s-node k3s-agent; do
  if systemctl list-unit-files "${service_name}.service" --no-legend | grep -q "^${service_name}.service"; then
    systemctl disable --now "${service_name}"
    exit 0
  fi
done
echo "could not find k3s agent service: expected k3s-node or k3s-agent" >&2
exit 1
'
  node_require_tool ansible
  ANSIBLE_HOST_KEY_CHECKING=False ansible \
    -i "$inventory_file" \
    "$inventory_node" \
    --become \
    -m ansible.builtin.shell \
    -a "$stop_script"
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

node_effective_ansible_inventory_dir() {
  local profile="$1"
  local rendered_dir

  case "$profile" in
    live)
      rendered_dir="${BOOTSTRAP_ANSIBLE_OUT_DIR:-${BOOTSTRAP_DIR}/.out/ansible-live}/inventory/live"
      if [[ -f "${rendered_dir}/hosts.yml" && -f "${rendered_dir}/group_vars/all.yml" ]]; then
        printf '%s\n' "$rendered_dir"
        return 0
      fi
      ;;
    lima)
      ;;
    *)
      node_die "unknown node lifecycle profile: ${profile}"
      ;;
  esac

  node_inventory_dir "$profile"
}

node_effective_ansible_inventory_file() {
  printf '%s/hosts.yml\n' "$(node_effective_ansible_inventory_dir "$1")"
}

node_effective_ansible_group_var() {
  local profile="$1"
  local key="$2"
  local group_vars
  group_vars="$(node_effective_ansible_inventory_dir "$profile")/group_vars/all.yml"
  [[ -f "$group_vars" ]] || return 1
  "$NODE_YQ_BIN" -r ".${key}" "$group_vars"
}

node_kube_proxy_replacement_enabled() {
  local profile="$1"
  local value
  value="$(node_effective_ansible_group_var "$profile" kube_proxy_replacement 2>/dev/null || true)"
  case "$value" in
    true)
      return 0
      ;;
    false)
      return 1
      ;;
    ""|null)
      node_die "kube_proxy_replacement is missing from $(node_effective_ansible_inventory_dir "$profile")/group_vars/all.yml"
      ;;
    *)
      node_die "kube_proxy_replacement must be true or false in $(node_effective_ansible_inventory_dir "$profile")/group_vars/all.yml: ${value}"
      ;;
  esac
}

node_assert_kube_proxy_disable_dropin() {
  local profile="$1"
  local inventory_node="$2"
  local inventory_file
  local remote_check

  if ! node_kube_proxy_replacement_enabled "$profile"; then
    node_log "kube_proxy_replacement is false; skipping K3s kube-proxy disable drop-in check"
    return 0
  fi

  inventory_file="$(node_effective_ansible_inventory_file "$profile")"
  read -r -d '' remote_check <<'EOF' || true
set -eu

dropin=/etc/rancher/k3s/config.yaml.d/90-home-ops-kube-proxy.yaml
if [ ! -f "$dropin" ]; then
  printf 'kube_proxy_disable_dropin=missing\n'
  exit 2
fi
if ! grep -Fxq 'disable-kube-proxy: true' "$dropin"; then
  printf 'kube_proxy_disable_dropin=invalid\n'
  exit 2
fi
printf 'kube_proxy_disable_dropin=present\n'
EOF

  node_log "validating K3s kube-proxy disable drop-in on ${inventory_node}"
  node_run_remote_shell "$inventory_file" "$inventory_node" "$remote_check" >/dev/null ||
    node_die "K3s kube-proxy disable drop-in is missing or invalid on ${inventory_node}"
}
