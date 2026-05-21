# shellcheck shell=bash

node_assert_control_plane_etcd_member_absent() {
  local profile="$1"
  local context="$2"
  local inventory_node_name="$3"
  local kubernetes_node_name="$4"
  local absent_message_prefix="${5:-etcd still has}"
  local inventory_file target_ansible_host probe_inventory_node probe_kubernetes_node remote_member_list
  local etcd_tls_dir_q
  local filtered_remote_output member_lines member_line
  local _member_id _member_status member_name member_peer_urls member_client_urls _member_is_learner _
  local matched_member_count=0
  local -a inventory_masters ready_control_planes

  inventory_file="$(node_ansible_inventory_file "$profile")"
  target_ansible_host="$(node_inventory_value "$profile" "$inventory_node_name" ansible_host 2>/dev/null || true)"
  mapfile -t inventory_masters < <(node_inventory_group_names "$profile" master)
  mapfile -t ready_control_planes < <(node_ready_control_planes "$context")

  probe_inventory_node=""
  for inventory_master in "${inventory_masters[@]}"; do
    probe_kubernetes_node="$(node_expected_kubernetes_node_name "$profile" "$inventory_master" "$inventory_master")"
    if [[ "$probe_kubernetes_node" != "$kubernetes_node_name" ]] &&
      node_contains_line "$probe_kubernetes_node" "${ready_control_planes[@]}"; then
      probe_inventory_node="$inventory_master"
      break
    fi
  done
  [[ -n "$probe_inventory_node" ]] ||
    node_die "no alternate Ready control-plane node is available to verify etcd membership"

  printf -v etcd_tls_dir_q '%q' "$NODE_K3S_ETCD_TLS_DIR"
  read -r -d '' remote_member_list <<'EOF' || true
set -eu

etcd_tls_dir=__NODE_K3S_ETCD_TLS_DIR__
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
  remote_member_list="${remote_member_list/__NODE_K3S_ETCD_TLS_DIR__/$etcd_tls_dir_q}"

  node_log "verifying ${kubernetes_node_name} is absent from etcd membership using ${probe_inventory_node}"
  if ! filtered_remote_output="$(node_run_remote_shell "$inventory_file" "$probe_inventory_node" "$remote_member_list")"; then
    node_die "failed to verify etcd membership from ${probe_inventory_node}"
  fi

  if grep -q '^member_list_error=' <<<"$filtered_remote_output"; then
    printf 'remote_probe:\n'
    node_indent_block <<<"$filtered_remote_output"
    node_die "etcd member-list probe reported an error"
  fi

  member_lines="$(node_extract_block etcd_member_simple_begin etcd_member_simple_end <<<"$filtered_remote_output")"
  [[ -n "$member_lines" ]] || node_die "etcd member list was empty"

  while IFS= read -r member_line; do
    [[ -n "$member_line" ]] || continue
    IFS=',' read -r _member_id _member_status member_name member_peer_urls member_client_urls _member_is_learner _ <<<"$member_line"
    member_name="$(node_trim "$member_name")"
    member_peer_urls="$(node_trim "$member_peer_urls")"
    member_client_urls="$(node_trim "$member_client_urls")"

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

  if ((matched_member_count != 0)); then
    node_die "${absent_message_prefix} ${matched_member_count} member(s) for ${kubernetes_node_name}"
  fi
}
