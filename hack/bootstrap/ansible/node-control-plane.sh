#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/ansible/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if [[ "${NODE_CONTROL_PLANE_ANSIBLE_INTERNAL:-}" != true ]]; then
  case " ${*:-} " in
    *" --help "*|*" -h "*)
      ;;
    *)
      ansible_die "node-control-plane.sh is an internal helper; use the node-* or node-lima-* just recipes"
      ;;
  esac
fi

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/ansible/node-control-plane.sh [options] NODE

Options:
  --profile NAME          Inventory profile: live or lima. Defaults to live.
  --inventory-source DIR  Source inventory directory for live.
  --inventory-dir DIR     Existing/generated inventory directory.
  --action NAME           Control-plane action: join or finalize.
  --join-ip ADDRESS       Override the K3s server join endpoint address.
  -h, --help              Show help.
EOF
}

profile="live"
source_dir=""
inventory_dir=""
action=""
join_ip=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --inventory-source)
      source_dir="$2"
      shift 2
      ;;
    --inventory-dir)
      inventory_dir="$2"
      shift 2
      ;;
    --action)
      action="$2"
      shift 2
      ;;
    --join-ip)
      join_ip="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      ansible_die "unknown argument: $1"
      ;;
    *)
      if [[ -n "${node_name:-}" ]]; then
        ansible_die "only one node may be provided"
      fi
      node_name="$1"
      shift
      ;;
  esac
done

[[ -n "${node_name:-}" ]] || ansible_die "NODE is required"

case "$profile" in
  live|lima)
    ;;
  *)
    ansible_die "unknown Ansible bootstrap profile: ${profile}"
    ;;
esac

case "$action" in
  join|finalize)
    ;;
  *)
    ansible_die "--action must be join or finalize"
    ;;
esac

BOOTSTRAP_ANSIBLE_BACKEND=home-ops
export BOOTSTRAP_ANSIBLE_BACKEND
ansible_set_profile "$profile"

ansible_require_tool yq
ansible_require_tool jq
ansible_require_tool ansible-playbook

case "$profile" in
  live)
    source_dir="${source_dir:-$BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR}"
    inventory_dir="${inventory_dir:-$(ansible_inventory_dir "$profile")}"
    ansible_render_inventory "$profile" "$source_dir" "$inventory_dir"
    ansible_require_tool op
    ansible_require_tool openssl
    ansible_require_tool ssh
    K3S_TOKEN="$(ansible_prepare_live_token "$inventory_dir")"
    export K3S_TOKEN
    if [[ "$action" == join ]]; then
      ansible_require_host_service_env master
    fi
    ;;
  lima)
    inventory_dir="${inventory_dir:-${BOOTSTRAP_DIR}/.out/lima-${LIMA_CLUSTER_NAME:-home-ops-k3s-test}/inventory}"
    [[ -f "${inventory_dir}/hosts.yml" ]] ||
      ansible_die "missing generated Lima inventory: ${inventory_dir}/hosts.yml"
    ;;
esac

inventory_file="${inventory_dir}/hosts.yml"
vars_file="${inventory_dir}/group_vars/all.yml"
[[ -f "$vars_file" ]] || ansible_die "missing inventory vars: ${vars_file}"

first_master="$(yq -r '.all.children.k3s_cluster.children.master.hosts // {} | keys | .[0]' "$inventory_file")"
[[ -n "$first_master" && "$first_master" != "null" ]] || ansible_die "master inventory group is empty"
first_master_join_ip="$(
  yq -r '.apiserver_endpoint // ""' "$vars_file"
)"
if [[ -z "$first_master_join_ip" || "$first_master_join_ip" == "null" ]]; then
  first_master_join_ip="$(
    FIRST_MASTER="$first_master" yq -r '
      .all.children.k3s_cluster.children.master.hosts[strenv(FIRST_MASTER)].ansible_host // strenv(FIRST_MASTER)
    ' "$inventory_file"
  )"
fi
[[ -n "$first_master_join_ip" && "$first_master_join_ip" != "null" ]] ||
  ansible_die "could not derive control-plane join address for ${first_master}"
if [[ -n "$join_ip" ]]; then
  first_master_join_ip="$join_ip"
fi

if ! NODE_NAME="$node_name" yq -e '.all.children.k3s_cluster.children.master.hosts | has(strenv(NODE_NAME))' "$inventory_file" >/dev/null; then
  ansible_die "target must be in the master inventory group: ${node_name}"
fi

playbook="${ANSIBLE_BOOTSTRAP_DIR}/home-ops/control-plane-${action}.yml"
ansible_log "running control-plane ${action} playbook for ${node_name}"
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  -i "$inventory_file" \
  "$playbook" \
  -e "home_ops_first_master_join_ip=${first_master_join_ip}" \
  --limit "$node_name"
