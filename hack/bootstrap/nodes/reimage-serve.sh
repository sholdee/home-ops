#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-serve.sh [options] NODE HOST

Copy the recorded image artifact to HOST, start a node-specific HTTP server,
render local metadata for the served URL, and record serve state for apply and
cleanup phases.

Options:
  --profile NAME  Inventory profile. Defaults to live.
  --port PORT     HTTP port on HOST. Defaults to 18080.
  --yes           Skip confirmation prompt.
  -h, --help      Show help.
EOF
}

profile=live
port="$NODE_REIMAGE_DEFAULT_PORT"
yes=false
positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --port)
      port="$2"
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
      positional+=("$1")
      shift
      ;;
  esac
done

[[ "${#positional[@]}" -eq 2 ]] || node_die "NODE and HOST are required"
[[ "$port" =~ ^[0-9]+$ ]] || node_die "port must be numeric: ${port}"
node_name="${positional[0]}"
host_name="${positional[1]}"

node_validate_profile "$profile"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible

IFS=$'\t' read -r inventory_node _ < <(
  node_reimage_resolve_existing_inventory_node "$profile" "$node_name"
)
IFS=$'\t' read -r host_node _ < <(
  node_reimage_resolve_existing_inventory_node "$profile" "$host_name"
)
[[ "$inventory_node" != "$host_node" ]] ||
  node_die "reimage host must not be the node being reimaged: ${inventory_node}"

build_state="$(node_reimage_build_state_file "$profile" "$inventory_node")"
artifact_path="$(node_reimage_read_state_value "$build_state" '.artifactPath')"
sha256="$(node_reimage_read_state_value "$build_state" '.sha256')"
[[ -f "$artifact_path" ]] || node_die "recorded image artifact is missing: ${artifact_path}"
actual_sha256="$(node_reimage_sha256_file "$artifact_path")"
[[ "$actual_sha256" == "$sha256" ]] ||
  node_die "recorded image SHA does not match artifact: state ${sha256}, actual ${actual_sha256}"

host_address="$(node_reimage_target_address "$profile" "$host_node")"
remote_dir="$(node_reimage_remote_dir_for "$inventory_node")"
remote_artifact="${remote_dir}/$(basename "$artifact_path")"
image_url="http://${host_address}:${port}/$(basename "$artifact_path")"
metadata_path="$(node_reimage_node_dir "$profile" "$inventory_node")/$(basename "$artifact_path").metadata.json"

node_log "rendering metadata for ${image_url}"
"${NODE_SCRIPT_DIR}/reimage-metadata.sh" \
  --profile "$profile" \
  "$inventory_node" \
  "$image_url" \
  "$sha256" > "$metadata_path"

node_confirm "$yes" "serve reimage image for ${inventory_node} from ${host_node}"

printf -v remote_dir_q '%q' "$remote_dir"
printf -v bind_q '%q' "$host_address"
printf -v port_q '%q' "$port"
node_log "preparing remote serve directory ${host_node}:${remote_dir}"
node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$host_node" "
set -eu
if [ -f ${remote_dir_q}/http.pid ]; then
  old_pid=\"\$(cat ${remote_dir_q}/http.pid 2>/dev/null || true)\"
  if [ -n \"\$old_pid\" ] && kill -0 \"\$old_pid\" >/dev/null 2>&1; then
    kill \"\$old_pid\" || true
  fi
fi
rm -rf ${remote_dir_q}
install -d -m 0755 ${remote_dir_q}
"

node_log "copying image and metadata to ${host_node}"
node_reimage_ansible_copy "$profile" "$host_node" "$artifact_path" "$remote_artifact" "0644"
node_reimage_ansible_copy "$profile" "$host_node" "$metadata_path" "${remote_artifact}.metadata.json" "0644"

node_log "starting image HTTP server on ${host_node}:${port}"
node_run_remote_shell "$(node_ansible_inventory_file "$profile")" "$host_node" "
set -eu
cd ${remote_dir_q}
nohup python3 -m http.server ${port_q} --bind ${bind_q} >http.log 2>&1 &
pid=\$!
printf '%s\n' \"\$pid\" > http.pid
sleep 1
if ! kill -0 \"\$pid\" >/dev/null 2>&1; then
  cat http.log >&2 || true
  exit 2
fi
printf 'http_pid=%s\n' \"\$pid\"
" | node_indent_block

serve_state="$(node_reimage_write_serve_state \
  "$profile" \
  "$inventory_node" \
  "$host_node" \
  "$host_address" \
  "$port" \
  "$remote_dir" \
  "$image_url" \
  "$artifact_path" \
  "$metadata_path" \
  "$sha256")"

printf 'image_url=%s\n' "$image_url"
printf 'sha256=%s\n' "$sha256"
printf 'metadata=%s\n' "$metadata_path"
printf 'serve_state=%s\n' "$serve_state"
