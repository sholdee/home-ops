#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/ansible/render-inventory.sh [options]

Options:
  --profile NAME          Inventory profile: live or lima. Defaults to live.
  --inventory-source DIR  Source inventory directory with hosts.yml and group_vars/all.yml.
  --output-dir DIR        Generated inventory directory.
  --summary               Print a non-secret run summary after rendering.
  -h, --help              Show help.
EOF
}

profile="live"
source_dir=""
output_dir=""
summary=false

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

output_dir="${output_dir:-$(ansible_inventory_dir "$profile")}"

ansible_require_tool yq
ansible_require_tool jq
ansible_render_inventory "$profile" "$source_dir" "$output_dir"
ansible_log "rendered ${profile} Ansible inventory: ${output_dir}/hosts.yml"

if ansible_bool "$summary"; then
  ansible_print_summary "$profile" "$output_dir"
fi
