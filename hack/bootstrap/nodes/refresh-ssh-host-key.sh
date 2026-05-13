#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/refresh-ssh-host-key.sh [options] NODE

Options:
  --profile NAME   Node lifecycle profile: live or lima. Defaults to live.
  --yes            Skip confirmation prompt.
  -h, --help       Show help.
EOF
}

profile=live
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
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
      node_die "unknown argument: $1"
      ;;
    *)
      if [[ -n "${node_name:-}" ]]; then
        node_die "only one node may be provided"
      fi
      node_name="$1"
      shift
      ;;
  esac
done

[[ -n "${node_name:-}" ]] || node_die "NODE is required"
node_validate_profile "$profile"

node_require_tool "$NODE_YQ_BIN"
node_require_tool ssh-keygen
node_require_tool ssh-keyscan

IFS=$'\t' read -r inventory_node_name inventory_role < <(node_resolve_inventory_node "$profile" "$node_name")
node_assert_inventory_worker "$inventory_node_name" "$inventory_role"

ansible_host="$(node_inventory_value "$profile" "$inventory_node_name" ansible_host 2>/dev/null || true)"
target="${ansible_host:-$inventory_node_name}"

node_confirm "$yes" "refresh ssh host key for ${target}"

if [[ "$profile" == lima ]]; then
  node_log "Lima inventory disables host-key checking; no known_hosts refresh is required for ${target}"
  exit 0
fi

node_log "removing stale known_hosts entries for ${target}"
ssh-keygen -R "$target" >/dev/null 2>&1 || true

mkdir -p "${HOME}/.ssh"
touch "${HOME}/.ssh/known_hosts"
chmod 0600 "${HOME}/.ssh/known_hosts" >/dev/null 2>&1 || true

node_log "scanning SSH host key for ${target}"
ssh-keyscan -H "$target" >> "${HOME}/.ssh/known_hosts"
node_log "SSH host key refreshed for ${target}"
