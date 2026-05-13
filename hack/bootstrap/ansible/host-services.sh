#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/ansible/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/ansible/host-services.sh [options] NODE

Converge only home-ops host services on one live inventory node. This path does
not join, drain, reboot, or run Kubernetes bootstrap phases.

Options:
  --inventory-source DIR  Source inventory directory.
  --inventory-dir DIR     Existing/generated inventory directory.
  --skip-render           Use --inventory-dir as-is.
  --yes                   Skip confirmation prompt.
  -h, --help              Show help.
EOF
}

source_dir="$BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR"
inventory_dir=""
skip_render=false
yes=false
node_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory-source)
      source_dir="$2"
      shift 2
      ;;
    --inventory-dir)
      inventory_dir="$2"
      shift 2
      ;;
    --skip-render)
      skip_render=true
      shift
      ;;
    --yes)
      yes=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      ansible_die "unknown argument: $1"
      ;;
    *)
      if [[ -n "$node_name" ]]; then
        ansible_die "unexpected extra argument: $1"
      fi
      node_name="$1"
      shift
      ;;
  esac
done

[[ -n "$node_name" ]] || ansible_die "NODE is required"

BOOTSTRAP_ANSIBLE_BACKEND=home-ops
export BOOTSTRAP_ANSIBLE_BACKEND
ansible_set_profile live

inventory_dir="${inventory_dir:-$(ansible_inventory_dir live)}"
inventory_file="${inventory_dir}/hosts.yml"

ansible_require_tool yq
ansible_require_tool jq
ansible_require_tool ansible-playbook

if ! ansible_bool "$skip_render"; then
  ansible_render_inventory live "$source_dir" "$inventory_dir"
fi

in_master="$(
  NODE_NAME="$node_name" yq -r \
    '.all.children.k3s_cluster.children.master.hosts | has(strenv(NODE_NAME))' \
    "$inventory_file"
)"
in_node="$(
  NODE_NAME="$node_name" yq -r \
    '.all.children.k3s_cluster.children.node.hosts | has(strenv(NODE_NAME))' \
    "$inventory_file"
)"

case "${in_master}:${in_node}" in
  true:false)
    node_role=master
    ;;
  false:true)
    node_role=node
    ;;
  false:false)
    node_role=absent
    ;;
  true:true)
    node_role=conflict
    ;;
  *)
    node_role=unknown
    ;;
esac

case "$node_role" in
  master|node)
    ;;
  absent)
    ansible_die "node is not present in live inventory: ${node_name}"
    ;;
  conflict)
    ansible_die "node is present in multiple live inventory groups: ${node_name}"
    ;;
  *)
    ansible_die "could not resolve inventory role for node: ${node_name}"
    ;;
esac

ansible_require_host_service_env "$node_role"

if ! ansible_bool "$yes"; then
  ansible_log "host-services target: ${node_name} (${node_role})"
  printf 'Type "converge host services on %s" to continue: ' "$node_name" >&2
  read -r answer
  [[ "$answer" == "converge host services on ${node_name}" ]] ||
    ansible_die "confirmation failed"
fi

ansible_log "converging host services on ${node_name}"
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  -i "$inventory_file" \
  "${ANSIBLE_BOOTSTRAP_DIR}/home-ops/host-services.yml" \
  --limit "$node_name"
