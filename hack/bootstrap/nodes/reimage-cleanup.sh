#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-cleanup.sh [options] NODE

Stop the recorded node-specific image HTTP server and remove its remote
temporary serving directory.

Options:
  --profile NAME  Inventory profile. Defaults to live.
  --yes           Skip confirmation prompt.
  -h, --help      Show help.
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
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible

IFS=$'\t' read -r inventory_node _ < <(
  node_reimage_resolve_existing_inventory_node "$profile" "$node_name"
)

serve_state="$(node_reimage_serve_state_file "$profile" "$inventory_node")"
state_host_node="$(node_reimage_read_state_value "$serve_state" '.hostNode')"
remote_dir="$(node_reimage_read_state_value "$serve_state" '.remoteDir')"
IFS=$'\t' read -r host_node _ < <(
  node_reimage_resolve_existing_inventory_node "$profile" "$state_host_node"
)
[[ "$inventory_node" != "$host_node" ]] ||
  node_die "reimage host must not be the node being reimaged: ${inventory_node}"
node_reimage_assert_safe_remote_dir "$inventory_node" "$remote_dir"

node_confirm "$yes" "cleanup reimage image server for ${inventory_node} on ${host_node}"

printf -v remote_dir_q '%q' "$remote_dir"
node_log "stopping image HTTP server and removing ${host_node}:${remote_dir}"
node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$host_node" "
set -eu
if [ -f ${remote_dir_q}/http.pid ]; then
  pid=\"\$(cat ${remote_dir_q}/http.pid 2>/dev/null || true)\"
  if [ -n \"\$pid\" ] && kill -0 \"\$pid\" >/dev/null 2>&1; then
    kill \"\$pid\" || true
  fi
fi
rm -rf ${remote_dir_q}
"

cleanup_state="$(node_reimage_write_cleanup_state "$profile" "$inventory_node" "$host_node" "$remote_dir")"
mv "$serve_state" "${serve_state%.json}.cleaned.json"
printf 'cleanup_state=%s\n' "$cleanup_state"
