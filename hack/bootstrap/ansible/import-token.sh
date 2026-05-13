#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/ansible/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/ansible/import-token.sh [options]

Reads the existing K3s server token from the first live control-plane node and
writes it to op://Kubernetes/k3s-bootstrap/k3s_token. The token is not logged.

Options:
  --inventory-source DIR  Source live inventory directory.
  --output-dir DIR        Generated inventory directory.
  --yes                   Skip the explicit confirmation prompt.
  -h, --help              Show help.
EOF
}

source_dir="$BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR"
output_dir=""
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory-source)
      source_dir="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
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
    *)
      ansible_die "unknown argument: $1"
      ;;
  esac
done

output_dir="${output_dir:-$(ansible_inventory_dir live)}"

ansible_require_tool yq
ansible_require_tool jq
ansible_require_tool ssh
ansible_require_tool op
ansible_require_tool openssl
ansible_render_inventory live "$source_dir" "$output_dir"
ansible_print_summary live "$output_dir"

if ! ansible_bool "$yes"; then
  printf 'Type "import k3s token" to read the live node token into 1Password: ' >&2
  read -r answer
  [[ "$answer" == "import k3s token" ]] || ansible_die "confirmation failed"
fi

token="$(ansible_read_remote_token_if_exists "$output_dir")"
[[ -n "$token" ]] || ansible_die "no existing K3s token found on first control-plane node"
ansible_write_token_to_op "$token"
ansible_log "imported existing K3s token into $(ansible_token_ref)"
