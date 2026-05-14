#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/bootstrap/nodes/lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-image-source.sh [options] NODE

Render a per-node rpi-image-gen source tree for a Raspberry Pi OS image.

Options:
  --profile NAME         Node lifecycle profile. Defaults to live.
  --output-dir DIR       Output directory. Defaults to hack/bootstrap/.out.
  --base-layer NAME      rpi-image-gen base layer. Defaults to trixie-minbase.
  --ssh-public-key FILE  Public SSH key to embed for the Ansible user.
  --interface NAME       First-boot systemd-networkd interface. Defaults to eth0.
  --prefix BITS         IPv4 prefix length. Defaults to 24.
  --gateway IP          IPv4 gateway. Defaults to ansible_host's /24 .1.
  --dns IP              IPv4 DNS server. Defaults to gateway.
  -h, --help            Show help.
EOF
}

profile=live
output_dir=""
base_layer="$NODE_REIMAGE_IMAGE_DEFAULT_BASE_LAYER"
public_key_file=""
network_iface="$NODE_REIMAGE_IMAGE_DEFAULT_INTERFACE"
network_prefix="$NODE_REIMAGE_IMAGE_DEFAULT_PREFIX"
network_gateway=""
network_dns=""
positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="${2:?missing value for --profile}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --base-layer|--base-config)
      base_layer="${2:?missing value for $1}"
      shift 2
      ;;
    --ssh-public-key)
      public_key_file="${2:?missing value for --ssh-public-key}"
      shift 2
      ;;
    --interface)
      network_iface="${2:?missing value for --interface}"
      shift 2
      ;;
    --prefix)
      network_prefix="${2:?missing value for --prefix}"
      shift 2
      ;;
    --gateway)
      network_gateway="${2:?missing value for --gateway}"
      shift 2
      ;;
    --dns)
      network_dns="${2:?missing value for --dns}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      node_die "unknown option: $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

[[ "${#positional[@]}" -eq 1 ]] || {
  usage >&2
  exit 2
}

node_validate_profile "$profile"
node_require_tool "$NODE_JQ_BIN"
node_require_tool "$NODE_YQ_BIN"

read -r inventory_node inventory_role < <(node_resolve_inventory_node "$profile" "${positional[0]}")
[[ "$inventory_role" == master || "$inventory_role" == node ]] ||
  node_die "node is not present in ${profile} inventory: ${positional[0]}"

node_reimage_image_render_source \
  "$profile" \
  "$inventory_node" \
  "$output_dir" \
  "$public_key_file" \
  "$base_layer" \
  "$network_iface" \
  "$network_prefix" \
  "$network_gateway" \
  "$network_dns"
