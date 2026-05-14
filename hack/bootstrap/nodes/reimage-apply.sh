#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-apply.sh [options] NODE

Use recorded serve state to stage the reimage payload, reboot into one-shot
tryboot reimage mode, wait for SSH to disappear and return, then refresh the
host key. The Kubernetes Node must already be deleted unless --force is used.

Options:
  --profile NAME  Node lifecycle profile. Defaults to live.
  --context NAME  Kubernetes context. Defaults to the profile context.
  --force         Skip only the Kubernetes-node-absent checks in stage/reboot.
  --yes           Skip confirmation prompt.
  -h, --help      Show help.
EOF
}

profile=live
context=""
force=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --context)
      context="$2"
      shift 2
      ;;
    --force)
      force=true
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
context="${context:-$(node_context_for_profile "$profile")}"

node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool nc
node_require_tool ssh

IFS=$'\t' read -r inventory_node _ < <(
  node_reimage_resolve_existing_inventory_node "$profile" "$node_name"
)

serve_state="$(node_reimage_serve_state_file "$profile" "$inventory_node")"
image_url="$(node_reimage_read_state_value "$serve_state" '.imageUrl')"
sha256="$(node_reimage_read_state_value "$serve_state" '.sha256')"
metadata_path="$(node_reimage_read_state_value "$serve_state" '.metadataPath')"
[[ -f "$metadata_path" ]] || node_die "recorded metadata file is missing: ${metadata_path}"

target_address="$(node_reimage_target_address "$profile" "$inventory_node")"
node_confirm "$yes" "apply staged network reimage for ${inventory_node}"

stage_args=(--profile "$profile" --context "$context" --metadata-file "$metadata_path" --yes)
reboot_args=(--profile "$profile" --context "$context" --yes)
if node_bool "$force"; then
  stage_args+=(--force)
  reboot_args+=(--force)
fi

node_log "staging network reimage payload for ${inventory_node}"
"$NODE_REIMAGE_STAGE_BIN" "${stage_args[@]}" "$inventory_node" "$image_url" "$sha256"

node_log "rebooting ${inventory_node} into tryboot reimage"
"$NODE_REIMAGE_REBOOT_BIN" "${reboot_args[@]}" "$inventory_node"

if [[ "${NODE_REIMAGE_APPLY_SKIP_WAIT:-false}" == true ]]; then
  node_warn "NODE_REIMAGE_APPLY_SKIP_WAIT=true; skipping SSH down/up wait and host-key refresh"
else
  node_log "waiting for SSH to go down on ${target_address}"
  node_reimage_wait_port_down "$target_address" 22 "$NODE_REIMAGE_SSH_DOWN_TIMEOUT_SECONDS"
  node_log "waiting for SSH to come back on ${target_address}"
  node_reimage_wait_port_up "$target_address" 22 "$NODE_REIMAGE_SSH_UP_TIMEOUT_SECONDS"
  node_log "refreshing SSH host key for ${inventory_node}"
  "$NODE_REFRESH_SSH_HOST_KEY_BIN" --profile "$profile" --yes "$inventory_node"
  node_log "waiting for SSH authentication on ${inventory_node}"
  node_reimage_wait_ssh_auth "$profile" "$inventory_node" "$NODE_REIMAGE_SSH_UP_TIMEOUT_SECONDS"
fi

apply_state="$(node_reimage_write_apply_state "$profile" "$inventory_node" "$image_url" "$sha256")"
printf 'apply_state=%s\n' "$apply_state"
printf 'next=%s\n' "just node-join ${inventory_node} && just node-uncordon ${inventory_node}"
