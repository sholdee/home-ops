#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-stage.sh [options] NODE IMAGE_URL SHA256

Stage a one-shot Raspberry Pi tryboot network reimage payload. By default the
Kubernetes Node must already be deleted.

Options:
  --profile NAME        Node lifecycle profile: live or lima. Defaults to live.
  --context NAME        Kubernetes context. Defaults to the profile context.
  --metadata-url URL    Image metadata URL. Defaults to IMAGE_URL.metadata.json.
  --metadata-file FILE  Read image metadata from a local file instead of URL.
  --payload-dir DIR     Use local initramfs.img and cmdline.txt instead of
                        building a payload from the target node initramfs.
  --force               Skip only the Kubernetes-node-absent check.
  --yes                 Skip confirmation prompt.
  -h, --help            Show help.
EOF
}

profile=live
context=""
metadata_url=""
metadata_file=""
payload_dir="$NODE_REIMAGE_PAYLOAD_DIR"
force=false
yes=false
positional=()

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
    --metadata-url)
      metadata_url="$2"
      shift 2
      ;;
    --metadata-file)
      metadata_file="$2"
      shift 2
      ;;
    --payload-dir)
      payload_dir="$2"
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
      positional+=("$1")
      shift
      ;;
  esac
done

[[ "${#positional[@]}" -eq 3 ]] || node_die "NODE, IMAGE_URL, and SHA256 are required"
node_name="${positional[0]}"
image_url="${positional[1]}"
image_sha256="$(node_reimage_normalize_sha256 "${positional[2]}")"

[[ -z "$metadata_file" || -z "$metadata_url" ]] ||
  node_die "use either --metadata-file or --metadata-url, not both"
if [[ -z "$metadata_file" && -z "$metadata_url" ]]; then
  metadata_url="${image_url}.metadata.json"
fi
metadata_source="${metadata_file:-$metadata_url}"

node_validate_profile "$profile"
context="${context:-$(node_context_for_profile "$profile")}"

node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible
node_require_tool base64

IFS=$'\t' read -r inventory_node inventory_role < <(node_resolve_inventory_node "$profile" "$node_name")
case "$inventory_role" in
  master|node)
    ;;
  absent)
    node_die "node is not present in ${profile} inventory: ${node_name}"
    ;;
  conflict)
    node_die "node is present in multiple ${profile} inventory groups: ${node_name}"
    ;;
  *)
    node_die "could not resolve inventory role for node: ${node_name}"
    ;;
esac

kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_node" "$node_name")"
if node_bool "$force"; then
  node_warn "force enabled; skipping Kubernetes node-absent check for ${kubernetes_node}"
else
  node_require_tool "$NODE_KUBECTL_BIN"
  node_assert_api_reachable "$context"
  if node_has_resource "$context" "node/${kubernetes_node}"; then
    node_die "Kubernetes node still exists; run just node-delete ${kubernetes_node} before staging reimage"
  fi
fi

disk_path="$(node_reimage_inventory_disk_path "$profile" "$inventory_node")"
node_log "probing ${inventory_node} identity and target disk"
probe="$(node_reimage_probe_host "$profile" "$inventory_node" "$disk_path")"
node_reimage_validate_probe "$profile" "$inventory_node" "$probe"

node_log "validating image metadata from ${metadata_source}"
metadata="$(node_reimage_read_metadata "$metadata_source")"
metadata="$(node_reimage_validate_metadata "$profile" "$inventory_node" "$image_url" "$image_sha256" "$metadata")"
manifest="$(node_reimage_build_manifest "$profile" "$inventory_node" "$kubernetes_node" "$image_url" "$image_sha256" "$metadata_source" "$metadata")"

if [[ -n "$payload_dir" ]]; then
  node_reimage_payload_file "$payload_dir" initramfs.img >/dev/null
  node_reimage_payload_file "$payload_dir" cmdline.txt >/dev/null
fi

node_confirm "$yes" "stage network reimage for ${inventory_node}"
node_reimage_stage_files "$profile" "$inventory_node" "$manifest" "$payload_dir"
node_log "reimage staged for ${inventory_node}; reboot with just node-reimage-reboot ${inventory_node}"
