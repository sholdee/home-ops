#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/reimage-full.sh [options] NODE

Build, serve, drain, delete, network-reimage, rejoin, and clean up one live
Raspberry Pi node. The node is left joined, cordoned, and temporarily tainted;
run the uncordon helper after final operator inspection.

Options:
  --profile NAME      Node lifecycle profile. Only live is supported in v1.
  --context NAME      Kubernetes context. Defaults to the profile context.
  --serve-host NODE   Healthy inventory node to host the image. Defaults to auto.
  --port PORT         HTTP port on the serve host. Defaults to 18080.
  --yes               Skip confirmation prompt.
  -h, --help          Show help.
EOF
}

profile=live
context=""
serve_host=""
port="$NODE_REIMAGE_DEFAULT_PORT"
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
    --serve-host)
      serve_host="$2"
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
[[ "$profile" == live ]] || node_die "node-reimage-full currently supports only the live profile"
context="${context:-$(node_context_for_profile "$profile")}"
[[ "$port" =~ ^[0-9]+$ ]] || node_die "port must be numeric: ${port}"

node_require_tool "$NODE_KUBECTL_BIN"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible
node_require_tool ssh

IFS=$'\t' read -r inventory_node inventory_role < <(
  node_reimage_resolve_existing_inventory_node "$profile" "$node_name"
)
kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_node" "$node_name")"

lock_dir="$(node_reimage_image_output_root)/${profile}/.full.lock"
serve_started=false
destructive_started=false
cleanup_completed=false

on_exit() {
  local status=$?
  if [[ "$status" -ne 0 && "$serve_started" == true && "$destructive_started" == false ]]; then
    node_warn "cleaning up image server because reimage-full failed before node deletion"
    "$NODE_REIMAGE_CLEANUP_BIN" --profile "$profile" --yes "$inventory_node" || true
    cleanup_completed=true
  elif [[ "$status" -ne 0 && "$serve_started" == true && "$cleanup_completed" == false ]]; then
    node_warn "image server may still be running; when safe, run: just node-reimage-cleanup ${inventory_node}"
  fi
  if [[ -d "$lock_dir" ]]; then
    rm -f "${lock_dir}/info"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap on_exit EXIT

mkdir -p "$(dirname "$lock_dir")"
if ! mkdir "$lock_dir" 2>/dev/null; then
  node_die "another node-reimage-full appears to be running: ${lock_dir}"
fi
printf 'node=%s\ncontext=%s\nstarted_at=%s\n' \
  "$inventory_node" \
  "$context" \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${lock_dir}/info"

node_log "phase: preflight"
node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node")"
[[ -n "$node_json" ]] || node_die "Kubernetes node must exist before full reimage: ${kubernetes_node}"
node_assert_ready "$node_json" "$kubernetes_node"
joining_taint="$(node_joining_taint_from_node_json <<<"$node_json")"
[[ "$joining_taint" == absent ]] ||
  node_die "Kubernetes node already has a joining taint; finish or repair prior lifecycle state: ${kubernetes_node}"

node_log "phase: reimage-plan"
"$NODE_REIMAGE_PLAN_BIN" --profile "$profile" --context "$context" "$inventory_node"

node_log "validating live Raspberry Pi and target disk identity"
disk_path="$(node_reimage_inventory_disk_path "$profile" "$inventory_node")"
probe="$(node_reimage_probe_host "$profile" "$inventory_node" "$disk_path")"
node_reimage_validate_probe "$profile" "$inventory_node" "$probe"

node_log "checking host-service secret inputs"
node_reimage_assert_host_service_inputs "$profile" "$inventory_role"

if [[ "$inventory_role" == master ]]; then
  node_log "running control-plane delete preflight"
  "$NODE_CONTROL_PLANE_DELETE_PREFLIGHT_BIN" --profile "$profile" --context "$context" "$inventory_node"
fi

node_log "checking Longhorn replacement readiness"
node_assert_longhorn_replacement_ready "$context"

local_path_report="$(node_reimage_local_path_pv_report "$context" "$kubernetes_node" | sed '/^$/d')"
if [[ -n "$local_path_report" ]]; then
  node_warn "local-path PVs are bound to ${kubernetes_node}; network reimage destroys their node-local data"
  node_indent_block <<<"$local_path_report" >&2
fi

if [[ -n "$serve_host" ]]; then
  IFS=$'\t' read -r serve_host serve_host_role < <(node_reimage_resolve_existing_inventory_node "$profile" "$serve_host")
  case "$serve_host_role" in
    master|node)
      ;;
    *)
      node_die "serve host is not present in ${profile} inventory: ${serve_host}"
      ;;
  esac
  [[ "$serve_host" != "$inventory_node" ]] ||
    node_die "serve host must not be the node being reimaged: ${inventory_node}"
  serve_host_address="$(node_reimage_target_address "$profile" "$serve_host")"
  node_reimage_probe_serve_host "$profile" "$serve_host" "$serve_host_address" "$port" ||
    node_die "explicit serve host is not usable: ${serve_host}"
else
  node_log "selecting image serve host"
  serve_host="$(node_reimage_select_serve_host "$profile" "$context" "$inventory_node" "$port")"
fi

node_log "selected image serve host: ${serve_host}"

node_log "phase: build"
"$NODE_REIMAGE_BUILD_BIN" --profile "$profile" "$inventory_node"

node_log "phase: serve"
"$NODE_REIMAGE_SERVE_BIN" --profile "$profile" --port "$port" --yes "$inventory_node" "$serve_host"
serve_started=true
serve_state="$(node_reimage_serve_state_file "$profile" "$inventory_node")"
image_url="$(node_reimage_read_state_value "$serve_state" '.imageUrl')"
sha256="$(node_reimage_read_state_value "$serve_state" '.sha256')"

node_log "verifying target can reach image URL before drain"
node_reimage_assert_target_can_fetch "$profile" "$inventory_node" "$image_url"

cat <<EOF

node-reimage-full summary:
  context: ${context}
  target: ${inventory_node}
  role: ${inventory_role}
  serve_host: ${serve_host}
  image_url: ${image_url}
  sha256: ${sha256}
  final_uncordon: operator-run
EOF
node_confirm "$yes" "reimage ${inventory_node} in ${context}"

destructive_started=true

node_log "phase: drain"
"$NODE_DRAIN_BIN" --profile "$profile" --context "$context" --yes "$inventory_node"

node_log "phase: longhorn-evict"
"$NODE_LONGHORN_EVICT_BIN" --profile "$profile" --context "$context" --yes "$inventory_node"

node_log "phase: delete"
"$NODE_DELETE_BIN" --profile "$profile" --context "$context" --yes "$inventory_node"

node_log "phase: apply"
"$NODE_REIMAGE_APPLY_BIN" --profile "$profile" --context "$context" --yes "$inventory_node"

node_log "phase: join"
"$NODE_JOIN_BIN" --profile "$profile" --context "$context" --yes "$inventory_node"

node_log "phase: os-plan-adopt"
node_reimage_adopt_system_upgrade_plan "$context" "$kubernetes_node"

host_services_status=0
node_log "phase: host-services"
if "$NODE_ANSIBLE_HOST_SERVICES_BIN" --yes "$inventory_node"; then
  :
else
  host_services_status=$?
  node_warn "host-services failed after Kubernetes join; retry with: just ansible-host-services ${inventory_node}"
fi

node_log "phase: cleanup"
"$NODE_REIMAGE_CLEANUP_BIN" --profile "$profile" --yes "$inventory_node"
cleanup_completed=true

if [[ "$host_services_status" -eq 0 ]]; then
  full_status=complete
else
  full_status="host-services-failed"
fi
full_state="$(node_reimage_write_full_state \
  "$profile" \
  "$inventory_node" \
  "$context" \
  "$inventory_role" \
  "$serve_host" \
  "$full_status" \
  "$host_services_status")"

printf 'full_state=%s\n' "$full_state"
printf 'next=%s\n' "just node-status ${inventory_node} && just node-uncordon ${inventory_node}"

if [[ "$host_services_status" -ne 0 ]]; then
  exit "$host_services_status"
fi
