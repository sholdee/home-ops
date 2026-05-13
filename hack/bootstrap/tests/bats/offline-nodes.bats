#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2154

load '../helpers/common.bash'
load '../helpers/nodes.bash'

setup_file() {
  require_tools yq jq
}

setup() {
  tmp="$BATS_TEST_TMPDIR"
  create_node_inventory
}

@test "node inventory helpers resolve roles, values, contexts, and quorum size" {
  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-master-0"
  assert_success
  [[ "$output" == "master" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-worker-0"
  assert_success
  [[ "$output" == "node" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-worker-9"
  assert_success
  [[ "$output" == "absent" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_value live k3s-worker-0 ansible_host"
  assert_success
  [[ "$output" == "192.168.99.20" ]]

  run env HOME=/tmp/home NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_effective_ssh_key live k3s-worker-0"
  assert_success
  [[ "$output" == "/tmp/home/ansiblekey" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_resolve_inventory_node live k3s-worker-0"
  assert_success
  [[ "$output" == "$(printf 'k3s-worker-0\tnode')" ]]

  run env NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_group_count live master"
  assert_success
  [[ "$output" == "3" ]]

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_etcd_quorum_size 3"
  assert_success
  [[ "$output" == "2" ]]

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_expected_kubernetes_node_name lima home-ops-k3s-test-agent-1 home-ops-k3s-test-agent-1"
  assert_success
  [[ "$output" == "lima-home-ops-k3s-test-agent-1" ]]

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_context_for_profile live"
  assert_success
  [[ "$output" == "default" ]]

  run env LIMA_CLUSTER_NAME=test-cluster \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_context_for_profile lima"
  assert_success
  [[ "$output" == "lima-test-cluster" ]]
}

@test "joining taint parser distinguishes present and invalid taints" {
  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_joining_taint_from_node_json" <<'JSON'
{"spec":{"taints":[{"key":"node.home-ops.sh/joining","value":"true","effect":"NoSchedule"}]}}
JSON
  assert_success
  [[ "$output" == "present" ]]

  run bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_joining_taint_from_node_json" <<'JSON'
{"spec":{"taints":[{"key":"node.home-ops.sh/joining","value":"true","effect":"PreferNoSchedule"}]}}
JSON
  assert_success
  [[ "$output" == "invalid" ]]
}

@test "worker status command reports inventory, Kubernetes, Cilium, and Longhorn absence" {
  write_worker_status_kubectl

  run env NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/status.sh" --profile live --context test k3s-worker-0
  assert_success
  assert_output_contains 'inventory_role: node'
  assert_output_contains 'kubernetes_role: node'
  assert_output_contains 'ready: Ready'
  assert_output_contains 'schedulable: cordoned'
  assert_output_contains 'joining_taint: present'
  assert_output_contains 'default/workload phase=Running owner=ReplicaSet'
  assert_output_contains 'cilium-one phase=Running ready=1/1'
  assert_output_contains 'installed: false'
}

@test "control-plane status, preflight, and alternate join IP use healthy peer state" {
  write_control_plane_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-status.sh" --profile live --context test k3s-master-0
  assert_success
  assert_output_contains 'inventory_control_planes: k3s-master-0,k3s-master-1,k3s-master-2'
  assert_output_contains 'inventory_control_plane_count: 3'
  assert_output_contains 'ready_control_plane_count: 3'
  assert_output_contains 'etcd_quorum_size_from_inventory: 2'
  assert_output_contains 'embedded_etcd_data=present'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-delete-preflight.sh" --profile live --context test k3s-master-0
  assert_success
  assert_output_contains 'probe_inventory_node: k3s-master-1'
  assert_output_contains 'etcd_member_count: 3'
  assert_output_contains 'post_remove_member_count: 2'
  assert_output_contains 'preflight_result: pass'
  assert_output_contains '  id: c9e409fd1205cc0a'
  assert_output_contains 'member remove c9e409fd1205cc0a'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_alternate_ready_control_plane_internal_ip live test k3s-master-0"
  assert_success
  [[ "$output" == "192.168.99.11" ]]
}

@test "control-plane Ansible wrapper passes temporary join IP only for join action" {
  local fake_bootstrap
  fake_bootstrap="${tmp}/fake-bootstrap"
  mkdir -p "${fake_bootstrap}/ansible"
  cat > "${fake_bootstrap}/ansible/node-control-plane.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${FAKE_NODE_CONTROL_PLANE_ARGS:?}"
test "${NODE_CONTROL_PLANE_ANSIBLE_INTERNAL:-}" = true
EOF
  chmod +x "${fake_bootstrap}/ansible/node-control-plane.sh"

  run env FAKE_NODE_CONTROL_PLANE_ARGS="${tmp}/node-control-plane.args" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; BOOTSTRAP_DIR='${fake_bootstrap}'; node_run_control_plane_ansible_action live k3s-master-0 join 192.168.99.11"
  assert_success
  assert_file_contains "${tmp}/node-control-plane.args" '--join-ip 192.168.99.11'

  run env FAKE_NODE_CONTROL_PLANE_ARGS="${tmp}/node-control-plane-finalize.args" NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; BOOTSTRAP_DIR='${fake_bootstrap}'; node_run_control_plane_ansible_action live k3s-master-0 finalize"
  assert_success
  assert_file_not_contains "${tmp}/node-control-plane-finalize.args" '--join-ip'
}

@test "control-plane drain and delete enforce stable API and cleanup semantics" {
  write_control_plane_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/drain.sh" --profile live --context test --yes k3s-master-0
  assert_success
  assert_output_contains 'preflight_result: pass'
  assert_output_contains 'drain complete: k3s-master-0'

  run env PATH="${tmp}:${PATH}" FAKE_CLUSTER_SERVER=https://192.168.99.10:6443 NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-0
  assert_failure
  assert_output_contains 'live first-master lifecycle requires a stable API endpoint'

  mkdir -p "${tmp}/first-control-plane-state"
  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/first-control-plane-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-0
  assert_success
  assert_output_contains 'first inventory master selected; live context must remain reachable through the stable API endpoint'
  assert_output_contains 'snapshot_name=pre-remove-k3s-master-0-'
  assert_output_contains 'Member c9e409fd1205cc0a removed from cluster'
  assert_output_contains 'node "k3s-master-0" deleted'
  assert_output_contains 'control-plane delete complete: k3s-master-0'

  mkdir -p "${tmp}/control-plane-state"
  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/control-plane-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-1
  assert_success
  assert_output_contains 'snapshot_name=pre-remove-k3s-master-1-'
  assert_output_contains 'Member 70594c7c481c118 removed from cluster'
  assert_output_contains 'node "k3s-master-1" deleted'
  assert_output_contains 'control-plane delete complete: k3s-master-1'

  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/control-plane-state" FAKE_ETCD_ABSENT_MEMBER_ID=70594c7c481c118 NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-1
  assert_success
  assert_output_contains 'stopping k3s server on k3s-master-1 before deleted-node cleanup'
  assert_output_contains 'verifying k3s-master-1 is absent from etcd membership using k3s-master-0'
  assert_output_contains 'control-plane delete cleanup complete: k3s-master-1'

  mkdir -p "${tmp}/blocked-control-plane-cleanup-state"
  touch "${tmp}/blocked-control-plane-cleanup-state/deleted-k3s-master-1"
  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/blocked-control-plane-cleanup-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-1
  assert_failure
  assert_output_contains 'refusing deleted-node cleanup because etcd still has 1 member(s) for k3s-master-1'
}

@test "control-plane join/uncordon and etcd membership checks fail closed" {
  write_control_plane_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-join.sh" --profile live --context test --yes k3s-master-0
  assert_failure
  assert_output_contains 'Kubernetes node already exists'

  mkdir -p "${tmp}/first-control-plane-state"
  touch "${tmp}/first-control-plane-state/deleted-k3s-master-0"
  run env PATH="${tmp}:${PATH}" FAKE_KUBECTL_STATE_DIR="${tmp}/first-control-plane-state" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-uncordon.sh" --profile live --context test --yes k3s-master-0
  assert_failure
  assert_output_contains 'Kubernetes node is absent'

  run env PATH="${tmp}:${PATH}" FAKE_ETCD_ABSENT_MEMBER_ID=70594c7c481c118 NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_control_plane_etcd_member_absent live test k3s-master-1 k3s-master-1"
  assert_success
  assert_output_contains 'verifying k3s-master-1 is absent from etcd membership using k3s-master-0'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_control_plane_etcd_member_absent live test k3s-master-1 k3s-master-1"
  assert_failure
  assert_output_contains 'etcd still has 1 member(s) for k3s-master-1'
}

@test "Longhorn deleted-node cleanup deletes only safe stale state and reports blockers" {
  write_deleted_node_longhorn_kubectl
  mkdir -p "${tmp}/longhorn-state"

  run env FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_cleanup_longhorn_deleted_node test deleted-node 1"
  assert_success
  assert_output_contains 'deleting safe stale Longhorn replica stale-replica'
  assert_output_contains 'replica.longhorn.io "stale-replica" deleted'
  assert_output_contains 'node.longhorn.io "deleted-node" deleted'

  run env FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" FAKE_LONGHORN_MODE=blockers NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test deleted-node"
  assert_failure
  assert_output_contains 'reason=volume-still-targets-node'
  assert_output_contains 'reason=engine-still-targets-node'
  assert_output_matches 'volume-b-e-0.*owner=deleted-node.*reason=engine-still-targets-node'
}

@test "Longhorn eviction helper fails clearly when Longhorn is absent" {
  write_control_plane_kubectl
  write_fake_ansible

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/longhorn-evict.sh" --profile live --context test --yes k3s-master-0
  assert_failure
  assert_output_contains 'Longhorn is not installed in test'

  run env PATH="${tmp}:${PATH}" NODE_LIVE_INVENTORY_DIR="$inventory" NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/longhorn-evict.sh" --profile live --context test --yes k3s-master-2
  assert_failure
  assert_output_contains 'Longhorn is not installed in test'
}

@test "Longhorn eviction and delete readiness checks enforce replica safety" {
  write_eviction_longhorn_kubectl

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_eviction_feasible test k3s-worker-0"
  assert_failure
  assert_output_contains 'max volume replicas=3, eligible storage nodes after removing target=2'

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_node_report test k3s-worker-0"
  assert_success
  assert_output_contains 'allowScheduling=false evictionRequested=true'

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_scheduling_problem test k3s-worker-0"
  assert_success
  [[ -z "$output" ]]

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_replica_delete_blockers test k3s-worker-0"
  assert_success
  [[ -z "$output" ]]

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test k3s-worker-0"
  assert_success

  run env LONGHORN_REPLICA_CASE=insufficient NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test k3s-worker-0"
  assert_failure
  assert_output_contains 'reason=insufficient-healthy-replicas-elsewhere'

  run env NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_restore_longhorn_scheduling test k3s-worker-0"
  assert_success
  assert_output_contains 'node.longhorn.io/k3s-worker-0 patched'
}

@test "stale pods bound to deleted nodes are force deleted" {
  write_stale_pods_kubectl

  run env STALE_PODS_STATE="$stale_pods_state" NODE_KUBECTL_BIN="$fake_stale_pods_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_cleanup_pods_for_deleted_node test k3s-worker-0"
  assert_success
  [[ ! -e "$stale_pods_state" ]]
}

@test "node lifecycle command help paths remain available" {
  local script
  for script in \
    hack/bootstrap/nodes/drain.sh \
    hack/bootstrap/nodes/control-plane-status.sh \
    hack/bootstrap/nodes/control-plane-delete-preflight.sh \
    hack/bootstrap/nodes/control-plane-delete.sh \
    hack/bootstrap/nodes/control-plane-join.sh \
    hack/bootstrap/nodes/control-plane-uncordon.sh \
    hack/bootstrap/nodes/delete.sh \
    hack/bootstrap/nodes/longhorn-evict.sh \
    hack/bootstrap/nodes/join.sh \
    hack/bootstrap/nodes/uncordon.sh \
    hack/bootstrap/nodes/refresh-ssh-host-key.sh \
    hack/bootstrap/ansible/node-control-plane.sh; do
    run "${ROOT}/${script}" --help
    assert_success
  done
}
