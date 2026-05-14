#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-metadata.sh [options] NODE IMAGE_URL SHA256

Render image metadata JSON expected by node-reimage-stage.

Options:
  --profile NAME  Inventory profile: live or lima. Defaults to live.
  -h, --help      Show help.
EOF
}

profile=live
positional=()

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

node_validate_profile "$profile"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"

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

ansible_host="$(node_inventory_value "$profile" "$inventory_node" ansible_host 2>/dev/null || true)"
[[ -n "$ansible_host" && "$ansible_host" != "null" ]] ||
  node_die "inventory ansible_host is required for image metadata: ${inventory_node}"

ansible_user="$(node_effective_ansible_user "$profile" "$inventory_node")"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# shellcheck disable=SC2016
"$NODE_JQ_BIN" -n \
  --arg schema "$NODE_REIMAGE_METADATA_SCHEMA" \
  --arg generatedAt "$generated_at" \
  --arg node "$inventory_node" \
  --arg hostname "$inventory_node" \
  --arg ansibleHost "$ansible_host" \
  --arg ansibleUser "$ansible_user" \
  --arg imageUrl "$image_url" \
  --arg sha256 "$image_sha256" \
  '{
    schemaVersion: $schema,
    generatedAt: $generatedAt,
    node: $node,
    hostname: $hostname,
    ansibleHost: $ansibleHost,
    ansibleUser: $ansibleUser,
    imageUrl: $imageUrl,
    sha256: $sha256,
    arch: "arm64"
  }'
