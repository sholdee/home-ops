#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=hack/bootstrap/nodes/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: hack/bootstrap/nodes/control-plane-status.sh [options] NODE

Options:
  --profile NAME   Node lifecycle profile: live or lima. Defaults to live.
  --context NAME   Kubernetes context. Defaults to the profile context.
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
    {print}
  '
}

profile=live
context=""

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

node_assert_api_reachable "$context"
node_json="$(node_node_json_if_present "$context" "$kubernetes_node_name")"
[[ -n "$node_json" ]] || node_die "Kubernetes node is absent: ${kubernetes_node_name}"
node_assert_kubernetes_control_plane "$node_json" "$kubernetes_node_name"

mapfile -t inventory_masters < <(node_inventory_group_names "$profile" master)
mapfile -t ready_control_planes < <(node_ready_control_planes "$context")
inventory_master_count="${#inventory_masters[@]}"
ready_control_plane_count="${#ready_control_planes[@]}"
quorum_size="$(node_etcd_quorum_size "$inventory_master_count")"

printf 'profile: %s\n' "$profile"
printf 'context: %s\n' "$context"
printf 'inventory: %s\n' "$inventory_file"
printf 'inventory_node: %s\n' "$inventory_node_name"
printf 'kubernetes_node: %s\n' "$kubernetes_node_name"
printf 'inventory_control_planes: %s\n' "$(join_csv "${inventory_masters[@]}")"
printf 'inventory_control_plane_count: %s\n' "$inventory_master_count"
printf 'ready_control_planes: %s\n' "$(join_csv "${ready_control_planes[@]}")"
printf 'ready_control_plane_count: %s\n' "$ready_control_plane_count"
printf 'etcd_quorum_size_from_inventory: %s\n' "$quorum_size"
if ((inventory_master_count >= 3 && ready_control_plane_count > quorum_size)); then
  printf 'single_control_plane_outage_budget: available\n'
else
  printf 'single_control_plane_outage_budget: unavailable\n'
fi

read -r -d '' remote_probe <<'EOF' || true
set -eu

printf 'hostname=%s\n' "$(hostname)"
if command -v k3s >/dev/null 2>&1; then
  k3s --version | sed -n '1s/^/k3s_version=/p'
else
  printf 'k3s_version=missing\n'
fi

if command -v systemctl >/dev/null 2>&1; then
  printf 'k3s_service_active=%s\n' "$(systemctl is-active k3s 2>/dev/null || true)"
  printf 'k3s_service_enabled=%s\n' "$(systemctl is-enabled k3s 2>/dev/null || true)"
else
  printf 'k3s_service_active=unknown_no_systemctl\n'
  printf 'k3s_service_enabled=unknown_no_systemctl\n'
fi

etcd_tls_dir=/var/lib/rancher/k3s/server/tls/etcd
etcd_data_dir=/var/lib/rancher/k3s/server/db/etcd
sqlite_db=/var/lib/rancher/k3s/server/db/state.db

if [ -d "$etcd_tls_dir" ]; then
  printf 'etcd_tls_dir=present\n'
else
  printf 'etcd_tls_dir=absent\n'
fi

if [ -d "$etcd_data_dir/member" ]; then
  printf 'embedded_etcd_data=present\n'
elif [ -d "$etcd_data_dir" ]; then
  printf 'embedded_etcd_data=partial\n'
else
  printf 'embedded_etcd_data=absent\n'
fi

if [ -f "$sqlite_db" ]; then
  printf 'sqlite_state_db=present\n'
else
  printf 'sqlite_state_db=absent\n'
fi

etcd_listeners=unknown_no_ss
if command -v ss >/dev/null 2>&1; then
  etcd_listeners="$(ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}' | grep -E '(:|\])23(79|80)$' | paste -sd ',' - || true)"
  printf 'etcd_listeners=%s\n' "${etcd_listeners:-none}"
  if [ -z "$etcd_listeners" ]; then
    etcd_listeners=none
  fi
else
  printf 'etcd_listeners=unknown_no_ss\n'
fi

etcdctl_path="$(command -v etcdctl 2>/dev/null || true)"
if [ -n "$etcdctl_path" ]; then
  printf 'etcdctl=%s\n' "$etcdctl_path"
  etcdctl_version="$("$etcdctl_path" version 2>/dev/null | sed -n '1p' || true)"
  printf 'etcdctl_version=%s\n' "${etcdctl_version:-unknown}"
else
  printf 'etcdctl=absent\n'
fi

if [ -n "$etcdctl_path" ] &&
  [ "$etcd_listeners" != "none" ] &&
  [ "$etcd_listeners" != "unknown_no_ss" ] &&
  [ -f "$etcd_tls_dir/server-ca.crt" ] &&
  [ -f "$etcd_tls_dir/client.crt" ] &&
  [ -f "$etcd_tls_dir/client.key" ]; then
  printf 'etcd_member_list_begin\n'
  "$etcdctl_path" \
    --endpoints=https://127.0.0.1:2379 \
    --dial-timeout=3s \
    --command-timeout=5s \
    --cacert="$etcd_tls_dir/server-ca.crt" \
    --cert="$etcd_tls_dir/client.crt" \
    --key="$etcd_tls_dir/client.key" \
    member list -w table || printf 'etcd_member_list_error=%s\n' "$?"
  printf 'etcd_member_list_end\n'
else
  printf 'etcd_member_list=skipped_missing_etcdctl_listener_or_certs\n'
fi
EOF

printf '\nremote_probe:\n'
if remote_output="$(
  ANSIBLE_HOST_KEY_CHECKING=False \
  ANSIBLE_PYTHON_INTERPRETER=auto_silent \
    ansible -i "$inventory_file" "$inventory_node_name" \
      --become \
      -m ansible.builtin.shell \
      -a "$remote_probe" 2>&1
)"; then
  filter_ansible_probe_output "$inventory_node_name" <<<"$remote_output" | indent_block
else
  indent_block <<<"$remote_output"
  node_die "control-plane remote probe failed for ${inventory_node_name}"
fi
