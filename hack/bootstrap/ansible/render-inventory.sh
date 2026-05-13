#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/ansible/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/ansible/render-inventory.sh [options]

Options:
  --backend NAME          Ansible backend: k3s-ansible or home-ops.
                          Defaults to BOOTSTRAP_ANSIBLE_BACKEND or home-ops.
  --profile NAME          Inventory profile: live or lima. Defaults to live.
  --inventory-source DIR  Source inventory directory with hosts.yml and group_vars/all.yml.
  --output-dir DIR        Generated inventory directory.
  --summary               Print a non-secret run summary after rendering.
  -h, --help              Show help.
EOF
}

profile="live"
backend="$BOOTSTRAP_ANSIBLE_BACKEND"
source_dir=""
output_dir=""
summary=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      backend="$2"
      shift 2
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    --inventory-source)
      source_dir="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    --summary)
      summary=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ansible_die "unknown argument: $1"
      ;;
  esac
done

case "$backend" in
  k3s-ansible|home-ops)
    BOOTSTRAP_ANSIBLE_BACKEND="$backend"
    export BOOTSTRAP_ANSIBLE_BACKEND
    ;;
  *)
    ansible_die "unknown Ansible backend: ${backend}"
    ;;
esac

case "$profile" in
  live)
    source_dir="${source_dir:-$BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR}"
    ;;
  lima)
    [[ -n "$source_dir" ]] || ansible_die "--inventory-source is required for lima"
    ;;
  *)
    ansible_die "unknown Ansible bootstrap profile: ${profile}"
    ;;
esac
ansible_set_profile "$profile"

output_dir="${output_dir:-$(ansible_inventory_dir "$profile")}"

ansible_require_tool yq
ansible_require_tool jq
ansible_render_inventory "$profile" "$source_dir" "$output_dir"
ansible_log "rendered ${profile} Ansible inventory: ${output_dir}/hosts.yml"

if ansible_bool "$summary"; then
  ansible_print_summary "$profile" "$output_dir"
fi
