#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/control-plane-delete-preflight.sh [options] NODE

Options:
  --profile NAME   Node lifecycle profile: live or lima. Defaults to live.
  --context NAME   Kubernetes context. Defaults to the profile context.
  --output FORMAT  Output format: text or json. Defaults to text.
  -h, --help       Show help.
EOF
}

join_csv() {
  if (($# == 0)); then
    printf 'none\n'
    return
  fi
  local IFS=,
  printf '%s\n' "$*"
}

json_array() {
  if (($# == 0)); then
    printf '[]\n'
    return
  fi
  printf '%s\n' "$@" | "$NODE_JQ_BIN" -R . | "$NODE_JQ_BIN" -s .
}

emit_text_preflight() {
  printf 'profile: %s\n' "$profile"
  printf 'context: %s\n' "$context"
  printf 'inventory: %s\n' "$inventory_file"
  printf 'target_inventory_node: %s\n' "$inventory_node_name"
  printf 'target_kubernetes_node: %s\n' "$kubernetes_node_name"
  printf 'target_ansible_host: %s\n' "${target_ansible_host:-unknown}"
  printf 'target_ready: %s\n' "$target_ready"
  printf 'probe_inventory_node: %s\n' "$probe_inventory_node"
  printf 'inventory_control_planes: %s\n' "$(join_csv "${inventory_masters[@]}")"
  printf 'ready_control_planes: %s\n' "$(join_csv "${ready_control_planes[@]}")"
  printf 'etcd_members: %s\n' "$(join_csv "${all_member_names[@]}")"
  printf 'etcd_member_count: %s\n' "$member_count"
  printf 'etcd_current_quorum_size: %s\n' "$current_quorum_size"
  printf 'post_remove_member_count: %s\n' "$post_remove_member_count"
  printf 'post_remove_quorum_size: %s\n' "$post_remove_quorum_size"
  printf 'remaining_ready_control_planes_after_target_stop: %s\n' "$remaining_ready_control_planes"

  printf '\ntarget_etcd_member:\n'
  printf '  id: %s\n' "$target_member_id"
  printf '  name: %s\n' "$target_member_name"
  printf '  status: %s\n' "$target_member_status"
  printf '  peer_urls: %s\n' "$target_member_peer_urls"
  printf '  client_urls: %s\n' "$target_member_client_urls"
  printf '  is_learner: %s\n' "$target_member_is_learner"

  printf '\netcd_endpoint_status:\n'
  indent_block <<<"$endpoint_status"

  printf '\nplanned_member_remove:\n'
  printf '  run_on_inventory_node: %s\n' "$probe_inventory_node"
  printf '  command: %s\n' "$planned_member_remove_command"

  printf '\npreflight_result: pass\n'
}

emit_json_preflight() {
  local human_output inventory_masters_json ready_control_planes_json etcd_members_json
  human_output="$(emit_text_preflight)"
  inventory_masters_json="$(json_array "${inventory_masters[@]}")"
  ready_control_planes_json="$(json_array "${ready_control_planes[@]}")"
  etcd_members_json="$(json_array "${all_member_names[@]}")"

  # shellcheck disable=SC2016
  "$NODE_JQ_BIN" -n \
    --arg human_output "$human_output" \
    --arg profile "$profile" \
    --arg context "$context" \
    --arg inventory "$inventory_file" \
    --arg target_inventory_node "$inventory_node_name" \
    --arg target_kubernetes_node "$kubernetes_node_name" \
    --arg target_ansible_host "${target_ansible_host:-unknown}" \
    --argjson target_ready "$target_ready" \
    --arg probe_inventory_node "$probe_inventory_node" \
    --argjson inventory_control_planes "$inventory_masters_json" \
    --argjson ready_control_planes "$ready_control_planes_json" \
    --argjson etcd_members "$etcd_members_json" \
    --argjson etcd_member_count "$member_count" \
    --argjson etcd_current_quorum_size "$current_quorum_size" \
    --argjson post_remove_member_count "$post_remove_member_count" \
    --argjson post_remove_quorum_size "$post_remove_quorum_size" \
    --argjson remaining_ready_control_planes_after_target_stop "$remaining_ready_control_planes" \
    --arg target_member_id "$target_member_id" \
    --arg target_member_name "$target_member_name" \
    --arg target_member_status "$target_member_status" \
    --arg target_member_peer_urls "$target_member_peer_urls" \
    --arg target_member_client_urls "$target_member_client_urls" \
    --arg target_member_is_learner "$target_member_is_learner" \
    --arg etcd_endpoint_status "$endpoint_status" \
    --arg planned_member_remove_run_on_inventory_node "$probe_inventory_node" \
    --arg planned_member_remove_command "$planned_member_remove_command" \
    '{
      human_output: $human_output,
      profile: $profile,
      context: $context,
      inventory: $inventory,
      target_inventory_node: $target_inventory_node,
      target_kubernetes_node: $target_kubernetes_node,
      target_ansible_host: $target_ansible_host,
      target_ready: $target_ready,
      probe_inventory_node: $probe_inventory_node,
      inventory_control_planes: $inventory_control_planes,
      ready_control_planes: $ready_control_planes,
      etcd_members: $etcd_members,
      etcd_member_count: $etcd_member_count,
      etcd_current_quorum_size: $etcd_current_quorum_size,
      post_remove_member_count: $post_remove_member_count,
      post_remove_quorum_size: $post_remove_quorum_size,
      remaining_ready_control_planes_after_target_stop: $remaining_ready_control_planes_after_target_stop,
      target_etcd_member: {
        id: $target_member_id,
        name: $target_member_name,
        status: $target_member_status,
        peer_urls: $target_member_peer_urls,
        client_urls: $target_member_client_urls,
        is_learner: $target_member_is_learner
      },
      etcd_endpoint_status: $etcd_endpoint_status,
      planned_member_remove: {
        run_on_inventory_node: $planned_member_remove_run_on_inventory_node,
        command: $planned_member_remove_command
      },
      preflight_result: "pass"
    }'
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

profile=live
context=""
output_format=text

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
    --output)
      output_format="$2"
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
case "$output_format" in
  text|json)
    ;;
  *)
    node_die "unsupported output format: ${output_format}"
    ;;
esac
context="${context:-$(node_context_for_profile "$profile")}"

node_require_tool "$NODE_KUBECTL_BIN"
node_require_tool "$NODE_YQ_BIN"
node_require_tool "$NODE_JQ_BIN"
node_require_tool ansible

IFS=$'\t' read -r inventory_node_name inventory_role < <(node_resolve_inventory_node "$profile" "$node_name")
node_assert_inventory_control_plane "$inventory_node_name" "$inventory_role"
kubernetes_node_name="$(node_expected_kubernetes_node_name "$profile" "$inventory_node_name" "$node_name")"
inventory_file="$(node_ansible_inventory_file "$profile")"
target_ansible_host="$(node_inventory_value "$profile" "$inventory_node_name" ansible_host 2>/dev/null || true)"

node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node is absent: ${kubernetes_node_name}"
node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"

mapfile -t inventory_masters < <(node_inventory_group_names "$profile" master)
mapfile -t ready_control_planes < <(node_ready_control_planes "$context")
inventory_master_count="${#inventory_masters[@]}"
ready_control_plane_count="${#ready_control_planes[@]}"
target_ready=false
if contains_line "$kubernetes_node_name" "${ready_control_planes[@]}"; then
  target_ready=true
fi

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
  node_die "no alternate Ready control-plane node is available to query etcd"

read -r -d '' remote_probe <<'EOF' || true
set -eu

etcd_tls_dir=/var/lib/rancher/k3s/server/tls/etcd
etcdctl_path="$(command -v etcdctl 2>/dev/null || true)"
if [ -z "$etcdctl_path" ]; then
  printf 'preflight_error=etcdctl_absent\n'
  exit 2
fi

for cert_file in server-ca.crt client.crt client.key; do
  if [ ! -f "$etcd_tls_dir/$cert_file" ]; then
    printf 'preflight_error=missing_etcd_cert:%s\n' "$cert_file"
    exit 2
  fi
done

printf 'hostname=%s\n' "$(hostname)"
printf 'etcdctl=%s\n' "$etcdctl_path"
etcdctl_version="$("$etcdctl_path" version 2>/dev/null | sed -n '1p' || true)"
printf 'etcdctl_version=%s\n' "${etcdctl_version:-unknown}"
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
printf 'etcd_endpoint_status_begin\n'
"$etcdctl_path" \
  --endpoints=https://127.0.0.1:2379 \
  --dial-timeout=3s \
  --command-timeout=5s \
  --cacert="$etcd_tls_dir/server-ca.crt" \
  --cert="$etcd_tls_dir/client.crt" \
  --key="$etcd_tls_dir/client.key" \
  endpoint status
printf 'etcd_endpoint_status_end\n'
EOF

if remote_output="$(
  ANSIBLE_HOST_KEY_CHECKING=False \
  ANSIBLE_PYTHON_INTERPRETER=auto_silent \
    ansible -i "$inventory_file" "$probe_inventory_node" \
      --become \
      -m ansible.builtin.shell \
      -a "$remote_probe" 2>&1
)"; then
  filtered_remote_output="$(filter_ansible_probe_output "$probe_inventory_node" <<<"$remote_output")"
else
  filtered_remote_output="$(filter_ansible_probe_output "$probe_inventory_node" <<<"$remote_output")"
  printf 'remote_probe:\n'
  indent_block <<<"$filtered_remote_output"
  node_die "control-plane delete preflight probe failed from ${probe_inventory_node}"
fi

if grep -q '^preflight_error=' <<<"$filtered_remote_output"; then
  printf 'remote_probe:\n'
  indent_block <<<"$filtered_remote_output"
  node_die "control-plane delete preflight probe reported an error"
fi

member_lines="$(extract_block etcd_member_simple_begin etcd_member_simple_end <<<"$filtered_remote_output")"
endpoint_status="$(extract_block etcd_endpoint_status_begin etcd_endpoint_status_end <<<"$filtered_remote_output")"
[[ -n "$member_lines" ]] || node_die "etcd member list was empty"
[[ -n "$endpoint_status" ]] || node_die "etcd endpoint status output was empty"

target_member_id=""
target_member_status=""
target_member_name=""
target_member_peer_urls=""
target_member_client_urls=""
target_member_is_learner=""
member_count=0
matched_member_count=0
all_member_names=()

while IFS= read -r member_line; do
  [[ -n "$member_line" ]] || continue
  IFS=',' read -r member_id member_status member_name member_peer_urls member_client_urls member_is_learner _ <<<"$member_line"
  member_id="$(trim "$member_id")"
  member_status="$(trim "$member_status")"
  member_name="$(trim "$member_name")"
  member_peer_urls="$(trim "$member_peer_urls")"
  member_client_urls="$(trim "$member_client_urls")"
  member_is_learner="$(trim "$member_is_learner")"
  ((member_count += 1))
  all_member_names+=("$member_name")

  member_matches=false
  if [[ "$member_name" == "$kubernetes_node_name" ||
    "$member_name" == "$inventory_node_name" ||
    "$member_name" == "${kubernetes_node_name}-"* ||
    "$member_name" == "${inventory_node_name}-"* ]]; then
    member_matches=true
  elif [[ -n "$target_ansible_host" &&
    ("$member_peer_urls" == *"://${target_ansible_host}:"* ||
      "$member_client_urls" == *"://${target_ansible_host}:"*) ]]; then
    member_matches=true
  fi

  if node_bool "$member_matches"; then
    target_member_id="$member_id"
    target_member_status="$member_status"
    target_member_name="$member_name"
    target_member_peer_urls="$member_peer_urls"
    target_member_client_urls="$member_client_urls"
    target_member_is_learner="$member_is_learner"
    ((matched_member_count += 1))
  fi
done <<<"$member_lines"

((member_count > 0)) || node_die "could not parse etcd members"
((matched_member_count == 1)) ||
  node_die "expected exactly one etcd member for ${kubernetes_node_name}; found ${matched_member_count}"
((member_count == inventory_master_count)) ||
  node_die "inventory control-plane count (${inventory_master_count}) does not match etcd member count (${member_count})"
((member_count >= 3)) ||
  node_die "control-plane delete preflight requires an HA etcd cluster; member count is ${member_count}"

current_quorum_size="$(node_etcd_quorum_size "$member_count")"
post_remove_member_count=$((member_count - 1))
post_remove_quorum_size="$(node_etcd_quorum_size "$post_remove_member_count")"
remaining_ready_control_planes="$ready_control_plane_count"
if node_bool "$target_ready"; then
  remaining_ready_control_planes=$((remaining_ready_control_planes - 1))
fi

((remaining_ready_control_planes >= current_quorum_size)) ||
  node_die "removing ${kubernetes_node_name} would leave ${remaining_ready_control_planes} Ready control-planes; current quorum is ${current_quorum_size}"
((remaining_ready_control_planes >= post_remove_quorum_size)) ||
  node_die "removing ${kubernetes_node_name} would leave ${remaining_ready_control_planes} Ready control-planes; post-remove quorum is ${post_remove_quorum_size}"

planned_member_remove_command="/usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt --key=/var/lib/rancher/k3s/server/tls/etcd/client.key member remove ${target_member_id}"

case "$output_format" in
  text)
    emit_text_preflight
    ;;
  json)
    emit_json_preflight
    ;;
esac
