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

indent_block() {
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done
}

filter_ansible_probe_output() {
  local host="$1"
  awk -v host="$host" '
    $0 == host " | CHANGED | rc=0 >>" {next}
    $0 == host " | SUCCESS | rc=0 >>" {next}
    /^\[WARNING\]: / {next}
    {print}
  '
}

extract_block() {
  local begin="$1"
  local end="$2"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin {inside = 1; next}
    $0 == end {inside = 0}
    inside {print}
  '
}

contains_line() {
  local needle="$1"
  shift
  local value
  for value in "$@"; do
    [[ "$value" == "$needle" ]] && return 0
  done
  return 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
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

assert_etcd_member_absent() {
  local profile="$1"
  local context="$2"
  local inventory_node_name="$3"
  local kubernetes_node_name="$4"
  local inventory_file="$5"
  local target_ansible_host probe_inventory_node probe_kubernetes_node remote_member_list
  local remote_output filtered_remote_output member_lines member_line
  local _member_id _member_status member_name member_peer_urls member_client_urls _member_is_learner _
  local matched_member_count=0
  local -a inventory_masters ready_control_planes

  target_ansible_host="$(node_inventory_value "$profile" "$inventory_node_name" ansible_host 2>/dev/null || true)"
  mapfile -t inventory_masters < <(node_inventory_group_names "$profile" master)
  mapfile -t ready_control_planes < <(node_ready_control_planes "$context")

  probe_inventory_node=""
  for inventory_master in "${inventory_masters[@]}"; do
    probe_kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_master" "$inventory_master")"
    if [[ "$probe_kubernetes_node" != "$kubernetes_node_name" ]] &&
      contains_line "$probe_kubernetes_node" "${ready_control_planes[@]}"; then
      probe_inventory_node="$inventory_master"
      break
    fi
  done
  [[ -n "$probe_inventory_node" ]] ||
    node_die "no alternate Ready control-plane node is available to verify etcd membership"

  read -r -d '' remote_member_list <<'EOF' || true
set -eu

etcd_tls_dir=/var/lib/rancher/k3s/server/tls/etcd
etcdctl_path="$(command -v etcdctl 2>/dev/null || true)"
if [ -z "$etcdctl_path" ]; then
  printf 'member_list_error=etcdctl_absent\n'
  exit 2
fi

for cert_file in server-ca.crt client.crt client.key; do
  if [ ! -f "$etcd_tls_dir/$cert_file" ]; then
    printf 'member_list_error=missing_etcd_cert:%s\n' "$cert_file"
    exit 2
  fi
done

printf 'etcd_member_simple_begin\n'
"$etcdctl_path" \
  --endpoints=https://127.0.0.1:2379 \
  --dial-timeout=3s \
  --command-timeout=5s \
  --cacert="$etcd_tls_dir/server-ca.crt" \
  --cert="$etcd_tls_dir/client.crt" \
  --key="$etcd_tls_dir/client.key" \
  member list
printf 'etcd_member_simple_end\n'
EOF

  node_log "verifying ${kubernetes_node_name} is absent from etcd membership using ${probe_inventory_node}"
  remote_output="$(run_remote_shell "$inventory_file" "$probe_inventory_node" "$remote_member_list")" ||
    node_die "failed to verify etcd membership from ${probe_inventory_node}"
  filtered_remote_output="$remote_output"

  if grep -q '^member_list_error=' <<<"$filtered_remote_output"; then
    printf 'remote_probe:\n'
    indent_block <<<"$filtered_remote_output"
    node_die "etcd member-list probe reported an error"
  fi

  member_lines="$(extract_block etcd_member_simple_begin etcd_member_simple_end <<<"$filtered_remote_output")"
  [[ -n "$member_lines" ]] || node_die "etcd member list was empty"

  while IFS= read -r member_line; do
    [[ -n "$member_line" ]] || continue
    IFS=',' read -r _member_id _member_status member_name member_peer_urls member_client_urls _member_is_learner _ <<<"$member_line"
    member_name="$(trim "$member_name")"
    member_peer_urls="$(trim "$member_peer_urls")"
    member_client_urls="$(trim "$member_client_urls")"

    if [[ "$member_name" == "$kubernetes_node_name" ||
      "$member_name" == "$inventory_node_name" ||
      "$member_name" == "${kubernetes_node_name}-"* ||
      "$member_name" == "${inventory_node_name}-"* ]]; then
      ((matched_member_count += 1))
    elif [[ -n "$target_ansible_host" &&
      ("$member_peer_urls" == *"://${target_ansible_host}:"* ||
        "$member_client_urls" == *"://${target_ansible_host}:"*) ]]; then
      ((matched_member_count += 1))
    fi
  done <<<"$member_lines"

  ((matched_member_count == 0)) ||
    node_die "refusing deleted-node cleanup because etcd still has ${matched_member_count} member(s) for ${kubernetes_node_name}"
}

run_remote_shell() {
  local inventory_file="$1"
  local inventory_node="$2"
  local remote_script="$3"
  local output filtered_output

  if output="$(
    ANSIBLE_HOST_KEY_CHECKING=False \
    ANSIBLE_PYTHON_INTERPRETER=auto_silent \
      ansible -i "$inventory_file" "$inventory_node" \
        --become \
        -m ansible.builtin.shell \
        -a "$remote_script" 2>&1
  )"; then
    filter_ansible_probe_output "$inventory_node" <<<"$output"
    return 0
  fi

  filtered_output="$(filter_ansible_probe_output "$inventory_node" <<<"$output")"
  printf 'remote_probe:\n'
  indent_block <<<"$filtered_output"
  return 1
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
  assert_etcd_member_absent "$profile" "$context" "$inventory_node_name" "$kubernetes_node_name" "$inventory_file"
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
snapshot_output="$(run_remote_shell "$inventory_file" "$probe_inventory_node" "$remote_snapshot")" ||
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
member_remove_output="$(run_remote_shell "$inventory_file" "$probe_inventory_node" "$remote_member_remove")" ||
  node_die "failed to remove etcd member ${target_member_id} from ${probe_inventory_node}"
printf '%s\n' "$member_remove_output"
if grep -q '^remove_error=' <<<"$member_remove_output"; then
  node_die "etcd member remove reported an error"
fi

post_remove_member_lines="$(extract_block member_list_after_begin member_list_after_end <<<"$member_remove_output")"
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
