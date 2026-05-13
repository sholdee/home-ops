#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/control-plane-delete.sh [options] NODE

Options:
  --profile NAME   Node lifecycle profile: live or lima. Defaults to live.
  --context NAME   Kubernetes context. Defaults to the profile context.
  --yes            Skip confirmation prompt.
  -h, --help       Show help.
EOF
}

parse_preflight_scalar() {
  local key="$1"
  awk -v key="$key" '
    index($0, key ": ") == 1 {
      sub("^[^:]+: ", "")
      print
      exit
    }
  '
}

parse_preflight_target_member_id() {
  awk '
    $0 == "target_etcd_member:" {inside = 1; next}
    inside && /^  id: / {
      sub(/^  id: /, "")
      print
      exit
    }
    inside && NF == 0 {inside = 0}
  '
}

profile=live
context=""
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

node_require_tool "$NODE_KUBECTL_BIN"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible

IFS=$'\t' read -r inventory_node_name inventory_role < <(node_resolve_inventory_node "$profile" "$node_name")
node_assert_inventory_control_plane "$inventory_node_name" "$inventory_role"
kubernetes_node_name="$(node_expected_kubernetes_node_name "$profile" "$inventory_node_name" "$node_name")"
inventory_file="$(node_ansible_inventory_file "$profile")"
preflight_script="${NODE_SCRIPT_DIR}/control-plane-delete-preflight.sh"

node_handoff_first_master_api_if_needed "$profile" "$context" "$inventory_node_name" "$kubernetes_node_name"
node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
if [[ -z "$node_json" ]]; then
  node_confirm "$yes" "clean up deleted control-plane node state ${kubernetes_node_name} from ${context}"
  node_log "stopping k3s server on ${inventory_node_name} before deleted-node cleanup"
  node_stop_k3s_server "$profile" "$inventory_node_name"
  node_assert_control_plane_etcd_member_absent \
    "$profile" \
    "$context" \
    "$inventory_node_name" \
    "$kubernetes_node_name" \
    "refusing deleted-node cleanup because etcd still has"
  node_cleanup_pods_for_deleted_node "$context" "$kubernetes_node_name"
  node_cleanup_longhorn_deleted_node "$context" "$kubernetes_node_name"
  node_log "control-plane delete cleanup complete: ${kubernetes_node_name}"
  exit 0
fi
node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"
node_assert_cordoned "$node_json" "$kubernetes_node_name"
node_assert_no_ordinary_pods "$context" "$kubernetes_node_name"
node_assert_longhorn_empty_for_delete "$context" "$kubernetes_node_name"

node_log "running control-plane delete preflight before mutation"
preflight_output="$("$preflight_script" --profile "$profile" --context "$context" "$node_name")"
printf '%s\n' "$preflight_output"

probe_inventory_node="$(parse_preflight_scalar probe_inventory_node <<<"$preflight_output")"
target_member_id="$(parse_preflight_target_member_id <<<"$preflight_output")"
member_count="$(parse_preflight_scalar etcd_member_count <<<"$preflight_output")"
[[ -n "$probe_inventory_node" ]] || node_die "could not parse preflight probe node"
[[ "$target_member_id" =~ ^[0-9a-f]+$ ]] || node_die "could not parse target etcd member id"
[[ "$member_count" =~ ^[0-9]+$ ]] || node_die "could not parse etcd member count"

node_confirm "$yes" "delete control-plane node ${kubernetes_node_name} from ${context}"

node_log "stopping k3s server on ${inventory_node_name}"
node_stop_k3s_server "$profile" "$inventory_node_name"

node_log "waiting for Kubernetes API after stopping ${kubernetes_node_name}"
node_wait_for_api_reachable "$context" 180

node_log "rechecking control-plane delete preflight after stopping ${kubernetes_node_name}"
post_stop_preflight_output="$("$preflight_script" --profile "$profile" --context "$context" "$node_name")"
printf '%s\n' "$post_stop_preflight_output"

probe_inventory_node="$(parse_preflight_scalar probe_inventory_node <<<"$post_stop_preflight_output")"
target_member_id="$(parse_preflight_target_member_id <<<"$post_stop_preflight_output")"
member_count="$(parse_preflight_scalar etcd_member_count <<<"$post_stop_preflight_output")"
[[ -n "$probe_inventory_node" ]] || node_die "could not parse post-stop preflight probe node"
[[ "$target_member_id" =~ ^[0-9a-f]+$ ]] || node_die "could not parse post-stop target etcd member id"
[[ "$member_count" =~ ^[0-9]+$ ]] || node_die "could not parse post-stop etcd member count"

safe_node_name="$(tr -c 'A-Za-z0-9._-' '-' <<<"$kubernetes_node_name" | sed 's/-$//')"
snapshot_name="pre-remove-${safe_node_name}-$(date -u '+%Y%m%dT%H%M%SZ')"
[[ "$snapshot_name" =~ ^[A-Za-z0-9._-]+$ ]] || node_die "generated snapshot name is unsafe: ${snapshot_name}"

read -r -d '' remote_snapshot <<EOF || true
set -eu

snapshot_name="${snapshot_name}"
k3s_path="\$(command -v k3s 2>/dev/null || true)"
if [ -z "\$k3s_path" ]; then
  printf 'snapshot_error=k3s_absent\n'
  exit 2
fi

printf 'snapshot_name=%s\n' "\$snapshot_name"
"\$k3s_path" etcd-snapshot save --name "\$snapshot_name"
printf 'snapshot_list_begin\n'
"\$k3s_path" etcd-snapshot ls | grep -F "\$snapshot_name"
printf 'snapshot_list_end\n'
EOF

node_log "creating K3s etcd snapshot on ${probe_inventory_node}"
snapshot_output="$(node_run_remote_shell "$inventory_file" "$probe_inventory_node" "$remote_snapshot")" ||
  node_die "failed to create K3s etcd snapshot on ${probe_inventory_node}"
printf '%s\n' "$snapshot_output"
if grep -q '^snapshot_error=' <<<"$snapshot_output"; then
  node_die "snapshot probe reported an error"
fi
if ! grep -q "^snapshot_name=${snapshot_name}$" <<<"$snapshot_output"; then
  node_die "snapshot output did not confirm expected snapshot name: ${snapshot_name}"
fi

read -r -d '' remote_member_remove <<EOF || true
set -eu

member_id="${target_member_id}"
etcd_tls_dir=/var/lib/rancher/k3s/server/tls/etcd
etcdctl_path="\$(command -v etcdctl 2>/dev/null || true)"
if [ -z "\$etcdctl_path" ]; then
  printf 'remove_error=etcdctl_absent\n'
  exit 2
fi

for cert_file in server-ca.crt client.crt client.key; do
  if [ ! -f "\$etcd_tls_dir/\$cert_file" ]; then
    printf 'remove_error=missing_etcd_cert:%s\n' "\$cert_file"
    exit 2
  fi
done

printf 'member_remove_begin\n'
"\$etcdctl_path" \\
  --endpoints=https://127.0.0.1:2379 \\
  --dial-timeout=3s \\
  --command-timeout=10s \\
  --cacert="\$etcd_tls_dir/server-ca.crt" \\
  --cert="\$etcd_tls_dir/client.crt" \\
  --key="\$etcd_tls_dir/client.key" \\
  member remove "\$member_id"
printf 'member_remove_end\n'
printf 'member_list_after_begin\n'
"\$etcdctl_path" \\
  --endpoints=https://127.0.0.1:2379 \\
  --dial-timeout=3s \\
  --command-timeout=5s \\
  --cacert="\$etcd_tls_dir/server-ca.crt" \\
  --cert="\$etcd_tls_dir/client.crt" \\
  --key="\$etcd_tls_dir/client.key" \\
  member list
printf 'member_list_after_end\n'
EOF

node_log "removing etcd member ${target_member_id} from ${probe_inventory_node}"
member_remove_output="$(node_run_remote_shell "$inventory_file" "$probe_inventory_node" "$remote_member_remove")" ||
  node_die "failed to remove etcd member ${target_member_id} from ${probe_inventory_node}"
printf '%s\n' "$member_remove_output"
if grep -q '^remove_error=' <<<"$member_remove_output"; then
  node_die "etcd member remove reported an error"
fi

post_remove_member_lines="$(node_extract_block member_list_after_begin member_list_after_end <<<"$member_remove_output")"
[[ -n "$post_remove_member_lines" ]] || node_die "post-remove etcd member list was empty"
if grep -Fq "$target_member_id" <<<"$post_remove_member_lines"; then
  node_die "target etcd member is still present after remove: ${target_member_id}"
fi

post_remove_member_count="$(sed '/^$/d' <<<"$post_remove_member_lines" | wc -l | tr -d '[:space:]')"
expected_post_remove_member_count=$((member_count - 1))
[[ "$post_remove_member_count" == "$expected_post_remove_member_count" ]] ||
  node_die "post-remove etcd member count (${post_remove_member_count}) does not match expected count (${expected_post_remove_member_count})"

node_log "deleting Kubernetes node ${kubernetes_node_name}"
node_kubectl "$context" delete "node/${kubernetes_node_name}" --wait=false
node_kubectl "$context" -n kube-system delete "secret/${kubernetes_node_name}.node-password.k3s" --ignore-not-found
node_wait_for_node_absent "$context" "$kubernetes_node_name"
node_cleanup_pods_for_deleted_node "$context" "$kubernetes_node_name"
node_cleanup_longhorn_deleted_node "$context" "$kubernetes_node_name"
node_log "control-plane delete complete: ${kubernetes_node_name}"
