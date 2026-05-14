#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-build.sh [options] NODE

Render a per-node rpi-image-gen source tree, build the image, copy the image
artifact to .out/reimage/<profile>/<node>/, compute SHA256, and record build
state for later serve/apply phases.

Options:
  --profile NAME             Inventory profile. Defaults to live.
  --rpi-image-gen-dir DIR    rpi-image-gen checkout. Defaults to ../rpi-image-gen.
  --builder-mode MODE        auto, lima, or local. Defaults to auto.
  --builder-name NAME        Lima builder name. Defaults to home-ops-rpi-image-builder.
  --base-layer NAME          rpi-image-gen base layer. Defaults to trixie-minbase.
  --interface NAME           Static image network interface. Defaults to eth0.
  --prefix CIDR_BITS         Static image IPv4 prefix. Defaults to 24.
  --gateway IP               Static image gateway. Defaults to host /24 .1.
  --dns IP                   Static image DNS. Defaults to gateway.
  --ssh-public-key FILE      Public SSH key to bake into the image.
  -h, --help                 Show help.
EOF
}

profile=live
rpi_image_gen_dir="${RPI_IMAGE_GEN_DIR:-$(node_reimage_default_rpi_image_gen_dir)}"
builder_mode="$NODE_REIMAGE_BUILDER_MODE"
builder_name="$NODE_REIMAGE_BUILDER_NAME"
base_layer=trixie-minbase
iface=eth0
prefix=24
gateway=""
dns=""
public_key_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="$2"
      shift 2
      ;;
    --rpi-image-gen-dir)
      rpi_image_gen_dir="$2"
      shift 2
      ;;
    --builder-mode)
      builder_mode="$2"
      shift 2
      ;;
    --builder-name)
      builder_name="$2"
      shift 2
      ;;
    --base-layer)
      base_layer="$2"
      shift 2
      ;;
    --interface)
      iface="$2"
      shift 2
      ;;
    --prefix)
      prefix="$2"
      shift 2
      ;;
    --gateway)
      gateway="$2"
      shift 2
      ;;
    --dns)
      dns="$2"
      shift 2
      ;;
    --ssh-public-key)
      public_key_file="$2"
      shift 2
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

IFS=$'\t' read -r inventory_node inventory_role < <(
  node_reimage_resolve_existing_inventory_node "$profile" "$node_name"
)
case "$inventory_role" in
  master|node)
    ;;
  *)
    node_die "node is not a worker or control-plane inventory host: ${node_name}"
    ;;
esac

node_dir="$(node_reimage_node_dir "$profile" "$inventory_node")"
source_dir="${node_dir}/source"
build_dir="${node_dir}/build"
mkdir -p "$node_dir" "$(node_reimage_state_dir "$profile" "$inventory_node")"

node_log "rendering rpi-image-gen source for ${inventory_node}"
render_output="$(
  node_reimage_image_render_source \
    "$profile" \
    "$inventory_node" \
    "$source_dir" \
    "$public_key_file" \
    "$base_layer" \
    "$iface" \
    "$prefix" \
    "$gateway" \
    "$dns"
)"
printf '%s\n' "$render_output"
image_name="$(awk -F= '$1 == "image_name" {print $2; exit}' <<<"$render_output")"
[[ -n "$image_name" ]] || node_die "could not determine rendered image name"

rpi_image_gen_dir="${rpi_image_gen_dir%/}"
builder_mode="$(node_reimage_builder_effective_mode "$builder_mode")"
node_log "building ${image_name} with ${builder_mode} builder"
rm -rf "$build_dir"
mkdir -p "$build_dir"
node_reimage_run_image_build "$builder_mode" "$builder_name" "$rpi_image_gen_dir" "$source_dir" "$build_dir" "$image_name"

built_artifact="$(node_reimage_find_build_artifact "$build_dir" "$image_name")"
artifact_path="${node_dir}/$(basename "$built_artifact")"
cp "$built_artifact" "$artifact_path"
sha256="$(node_reimage_sha256_file "$artifact_path")"
state_file="$(node_reimage_write_build_state \
  "$profile" \
  "$inventory_node" \
  "$image_name" \
  "$builder_mode" \
  "$builder_name" \
  "$rpi_image_gen_dir" \
  "$source_dir" \
  "$build_dir" \
  "$artifact_path" \
  "$sha256")"

printf 'artifact=%s\n' "$artifact_path"
printf 'sha256=%s\n' "$sha256"
printf 'build_state=%s\n' "$state_file"
