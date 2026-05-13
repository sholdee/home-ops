#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/cmd.sh [options] NODE -- COMMAND [ARG...]

Run one SSH command against a node from inventory. The helper does not add sudo
or mutate Kubernetes state by itself.

Options:
  --profile NAME  Inventory profile: live or lima. Defaults to live.
  -h, --help      Show help.
EOF
}

profile="live"
input_node=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    --*)
      node_die "unknown argument: $1"
      ;;
    *)
      if [[ -n "$input_node" ]]; then
        node_die "use -- before the remote command"
      fi
      input_node="$1"
      shift
      ;;
  esac
done

[[ -n "$input_node" ]] || node_die "NODE is required"
[[ $# -gt 0 ]] || node_die "remote command is required after --"

node_validate_profile "$profile"
node_require_tool "$NODE_YQ_BIN"
node_require_tool ssh
node_inventory_exists "$profile" || node_die "missing inventory: $(node_inventory_file "$profile")"

IFS=$'\t' read -r inventory_node inventory_role < <(
  node_resolve_inventory_node "$profile" "$input_node"
)

case "$inventory_role" in
  master|node)
    ;;
  absent)
    node_die "node is not present in ${profile} inventory: ${input_node}"
    ;;
  conflict)
    node_die "node is present in multiple ${profile} inventory groups: ${input_node}"
    ;;
  *)
    node_die "could not resolve inventory role for node: ${input_node}"
    ;;
esac

if [[ "$profile" == lima ]]; then
  lima_ssh_config="${HOME}/.lima/${inventory_node}/ssh.config"
  [[ -f "$lima_ssh_config" ]] ||
    node_die "missing Lima ssh config for ${inventory_node}: ${lima_ssh_config}"
  exec ssh -F "$lima_ssh_config" "lima-${inventory_node}" "$@"
fi

target="$(node_inventory_value "$profile" "$inventory_node" ansible_host 2>/dev/null || true)"
if [[ -z "$target" || "$target" == "null" ]]; then
  target="$inventory_node"
fi

user="$(node_effective_ansible_user "$profile" "$inventory_node")"
[[ -n "$user" ]] || node_die "could not resolve ansible_user for ${inventory_node}"

ssh_key="$(node_effective_ssh_key "$profile" "$inventory_node")"
ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
if [[ -n "$ssh_key" ]]; then
  ssh_args+=(-i "$ssh_key")
fi

exec ssh "${ssh_args[@]}" "${user}@${target}" "$@"
