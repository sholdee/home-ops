#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing tool: $1" >&2
    exit 1
  }
}

require yq
require jq

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

inventory="${tmp}/inventory/live"
mkdir -p "${inventory}/group_vars"
cat > "${inventory}/hosts.yml" <<'EOF'
---
all:
  children:
    k3s_cluster:
      children:
        master:
          hosts:
            k3s-master-0:
              ansible_host: 192.168.99.10
              k3s_role: server
            k3s-master-1:
              ansible_host: 192.168.99.11
              k3s_role: server
            k3s-master-2:
              ansible_host: 192.168.99.12
              k3s_role: server
        node:
          hosts:
            k3s-worker-0:
              ansible_host: 192.168.99.20
              k3s_role: agent
EOF

cat > "${inventory}/group_vars/all.yml" <<'EOF'
---
ansible_user: ethan
ansible_ssh_private_key_file: ~/ansiblekey
EOF

role_master="$(
  NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-master-0"
)"
test "$role_master" = "master"

role_worker="$(
  NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-worker-0"
)"
test "$role_worker" = "node"

role_absent="$(
  NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_role live k3s-worker-9"
)"
test "$role_absent" = "absent"

worker_host="$(
  NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_value live k3s-worker-0 ansible_host"
)"
test "$worker_host" = "192.168.99.20"

expanded_key="$(
  HOME=/tmp/home \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_effective_ssh_key live k3s-worker-0"
)"
test "$expanded_key" = "/tmp/home/ansiblekey"

resolved_worker="$(
  NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_resolve_inventory_node live k3s-worker-0"
)"
test "$resolved_worker" = "$(printf 'k3s-worker-0\tnode')"

master_count="$(
  NODE_LIVE_INVENTORY_DIR="$inventory" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_inventory_group_count live master"
)"
test "$master_count" = "3"

quorum_size="$(
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_etcd_quorum_size 3"
)"
test "$quorum_size" = "2"

expected_lima_node="$(
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_expected_kubernetes_node_name lima home-ops-k3s-test-agent-1 home-ops-k3s-test-agent-1"
)"
test "$expected_lima_node" = "lima-home-ops-k3s-test-agent-1"

live_context="$(bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_context_for_profile live")"
test "$live_context" = "default"

lima_context="$(
  LIMA_CLUSTER_NAME=test-cluster \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_context_for_profile lima"
)"
test "$lima_context" = "lima-test-cluster"

exact_joining_taint="$(
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_joining_taint_from_node_json" <<'JSON'
{"spec":{"taints":[{"key":"node.home-ops.sh/joining","value":"true","effect":"NoSchedule"}]}}
JSON
)"
test "$exact_joining_taint" = "present"

invalid_joining_taint="$(
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_joining_taint_from_node_json" <<'JSON'
{"spec":{"taints":[{"key":"node.home-ops.sh/joining","value":"true","effect":"PreferNoSchedule"}]}}
JSON
)"
test "$invalid_joining_taint" = "invalid"

fake_kubectl="${tmp}/kubectl"
cat > "$fake_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

if [[ "${1:-}" == "get" && "${2:-}" == "--raw=/readyz" ]]; then
  printf 'ok\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "node/k3s-worker-0" ]]; then
  cat <<'JSON'
{
  "metadata": {
    "name": "k3s-worker-0",
    "labels": {}
  },
  "spec": {
    "taints": [
      {"key": "node.home-ops.sh/joining", "value": "true", "effect": "NoSchedule"}
    ],
    "unschedulable": true
  },
  "status": {
    "conditions": [
      {"type": "Ready", "status": "True"}
    ]
  }
}
JSON
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "pods" ]]; then
  cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "namespace": "default",
        "name": "workload",
        "ownerReferences": [{"kind": "ReplicaSet"}]
      },
      "spec": {"nodeName": "k3s-worker-0"},
      "status": {"phase": "Running"}
    },
    {
      "metadata": {
        "namespace": "kube-system",
        "name": "daemon",
        "ownerReferences": [{"kind": "DaemonSet"}]
      },
      "spec": {"nodeName": "k3s-worker-0"},
      "status": {"phase": "Running"}
    }
  ]
}
JSON
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "namespace" && "${3:-}" == "kube-system" ]]; then
  printf '{"metadata":{"name":"kube-system"}}\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "kube-system" && "${4:-}" == "pods" ]]; then
  cat <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "cilium-one"},
      "spec": {"nodeName": "k3s-worker-0"},
      "status": {
        "phase": "Running",
        "containerStatuses": [{"ready": true}]
      }
    }
  ]
}
JSON
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "crd" && "${3:-}" == "volumes.longhorn.io" ]]; then
  printf 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "volumes.longhorn.io" not found\n' >&2
  exit 1
fi

printf 'unexpected fake kubectl args: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$fake_kubectl"

status_output="$(
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/status.sh" --profile live --context test k3s-worker-0
)"

grep -q '^inventory_role: node$' <<<"$status_output"
grep -q '^kubernetes_role: node$' <<<"$status_output"
grep -q '^ready: Ready$' <<<"$status_output"
grep -q '^schedulable: cordoned$' <<<"$status_output"
grep -q '^joining_taint: present$' <<<"$status_output"
grep -q 'default/workload phase=Running owner=ReplicaSet' <<<"$status_output"
grep -q 'cilium-one phase=Running ready=1/1' <<<"$status_output"
grep -q 'installed: false' <<<"$status_output"

fake_control_plane_kubectl="${tmp}/kubectl-control-plane"
cat > "$fake_control_plane_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

state_dir="${FAKE_KUBECTL_STATE_DIR:-}"

node_is_deleted() {
  [[ -n "$state_dir" && -f "${state_dir}/deleted-${1}" ]]
}

if [[ "${1:-}" == "get" && "${2:-}" == "--raw=/readyz" ]]; then
  printf 'ok\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" =~ ^node/k3s-master-[0-2]$ ]]; then
  node_name="${2#node/}"
  if node_is_deleted "$node_name"; then
    printf 'Error from server (NotFound): nodes "%s" not found\n' "$node_name" >&2
    exit 1
  fi
  sed "s/__NODE_NAME__/${node_name}/g" <<'JSON'
{
  "metadata": {
    "name": "__NODE_NAME__",
    "labels": {"node-role.kubernetes.io/control-plane": "true"}
  },
  "spec": {
    "unschedulable": true
  },
  "status": {
    "conditions": [
      {"type": "Ready", "status": "True"}
    ]
  }
}
JSON
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "pods" ]]; then
  printf '{"items":[]}\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "crd" && "${3:-}" == "volumes.longhorn.io" ]]; then
  printf 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "volumes.longhorn.io" not found\n' >&2
  exit 1
fi

if [[ "${1:-}" == "get" && "${2:-}" == "nodes" ]]; then
  cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "name": "k3s-master-0",
        "labels": {"node-role.kubernetes.io/control-plane": "true"}
      },
      "status": {"conditions": [{"type": "Ready", "status": "True"}]}
    },
    {
      "metadata": {
        "name": "k3s-master-1",
        "labels": {"node-role.kubernetes.io/control-plane": "true"}
      },
      "status": {"conditions": [{"type": "Ready", "status": "True"}]}
    },
    {
      "metadata": {
        "name": "k3s-master-2",
        "labels": {"node-role.kubernetes.io/control-plane": "true"}
      },
      "status": {"conditions": [{"type": "Ready", "status": "True"}]}
    },
    {
      "metadata": {"name": "k3s-worker-0", "labels": {}},
      "status": {"conditions": [{"type": "Ready", "status": "True"}]}
    }
  ]
}
JSON
  exit 0
fi

if [[ "${1:-}" == "drain" && "${2:-}" =~ ^k3s-master-[0-2]$ ]]; then
  printf 'node/%s drained\n' "$2"
  exit 0
fi

if [[ "${1:-}" == "delete" && "${2:-}" =~ ^node/k3s-master-[0-2]$ ]]; then
  node_name="${2#node/}"
  if [[ -n "$state_dir" ]]; then
    mkdir -p "$state_dir"
    touch "${state_dir}/deleted-${node_name}"
  fi
  printf 'node "%s" deleted\n' "$node_name"
  exit 0
fi

if [[ "${1:-}" == "-n" && "${2:-}" == "kube-system" && "${3:-}" == "delete" && "${4:-}" =~ ^secret/k3s-master-[0-2]\.node-password\.k3s$ ]]; then
  printf 'secret "%s" deleted\n' "${4#secret/}"
  exit 0
fi

printf 'unexpected fake control-plane kubectl args: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$fake_control_plane_kubectl"

fake_ansible="${tmp}/ansible"
cat > "$fake_ansible" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=""
skip_next=false
for arg in "$@"; do
  if $skip_next; then
    skip_next=false
    continue
  fi
  case "$arg" in
    -i)
      skip_next=true
      ;;
    --*)
      ;;
    -*)
      ;;
    *)
      target="$arg"
      break
      ;;
  esac
done
target="${target:-k3s-master-0}"
joined_args="$*"
printf '%s | CHANGED | rc=0 >>\n' "$target"

if [[ "$joined_args" == *"ansible.builtin.systemd"* ]]; then
  printf '{"changed": true}\n'
  exit 0
fi

if [[ "$joined_args" == *"etcd-snapshot save"* ]]; then
  snapshot_name="$(sed -n 's/^snapshot_name="\([^"]*\)"/\1/p' <<<"$joined_args" | sed -n '1p')"
  snapshot_name="${snapshot_name:-pre-remove-k3s-master-0-20260512T000000Z}"
  printf 'snapshot_name=%s\n' "$snapshot_name"
  printf 'Snapshot saved at /var/lib/rancher/k3s/server/db/snapshots/%s\n' "$snapshot_name"
  printf 'snapshot_list_begin\n'
  printf '%s file:///var/lib/rancher/k3s/server/db/snapshots/%s 1234 2026-05-12T00:00:00Z\n' "$snapshot_name" "$snapshot_name"
  printf 'snapshot_list_end\n'
  exit 0
fi

if [[ "$joined_args" == *"member remove"* ]]; then
  member_id="$(sed -n 's/^member_id="\([^"]*\)"/\1/p' <<<"$joined_args" | sed -n '1p')"
  member_id="${member_id:-c9e409fd1205cc0a}"
  printf 'member_remove_begin\n'
  printf 'Member %s removed from cluster\n' "$member_id"
  printf 'member_remove_end\n'
  printf 'member_list_after_begin\n'
  if [[ "$member_id" != "70594c7c481c118" ]]; then
    printf '70594c7c481c118, started, k3s-master-1-ff2e5a37, https://192.168.99.11:2380, https://192.168.99.11:2379, false\n'
  fi
  if [[ "$member_id" != "c9e409fd1205cc0a" ]]; then
    printf 'c9e409fd1205cc0a, started, k3s-master-0-b8caf5ab, https://192.168.99.10:2380, https://192.168.99.10:2379, false\n'
  fi
  if [[ "$member_id" != "ee5329b5b8ee26b3" ]]; then
    printf 'ee5329b5b8ee26b3, started, k3s-master-2-f7c0824c, https://192.168.99.12:2380, https://192.168.99.12:2379, false\n'
  fi
  printf 'member_list_after_end\n'
  exit 0
fi

removed_member_id="${FAKE_ETCD_ABSENT_MEMBER_ID:-}"
printf 'k3s_service_active=active\n'
printf 'embedded_etcd_data=present\n'
printf 'etcdctl=/usr/local/bin/etcdctl\n'
printf 'etcd_member_simple_begin\n'
if [[ "$removed_member_id" != "70594c7c481c118" ]]; then
  printf '70594c7c481c118, started, k3s-master-1-ff2e5a37, https://192.168.99.11:2380, https://192.168.99.11:2379, false\n'
fi
if [[ "$removed_member_id" != "c9e409fd1205cc0a" ]]; then
  printf 'c9e409fd1205cc0a, started, k3s-master-0-b8caf5ab, https://192.168.99.10:2380, https://192.168.99.10:2379, false\n'
fi
if [[ "$removed_member_id" != "ee5329b5b8ee26b3" ]]; then
  printf 'ee5329b5b8ee26b3, started, k3s-master-2-f7c0824c, https://192.168.99.12:2380, https://192.168.99.12:2379, false\n'
fi
printf 'etcd_member_simple_end\n'
printf 'etcd_endpoint_status_begin\n'
printf 'https://127.0.0.1:2379, c9e409fd1205cc0a, 3.6.7, 20 kB, false, false, 9, 123, 123, \n'
printf 'etcd_endpoint_status_end\n'
EOF
chmod +x "$fake_ansible"

control_plane_output="$(
  PATH="${tmp}:${PATH}" \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-status.sh" --profile live --context test k3s-master-0
)"

grep -q '^inventory_control_planes: k3s-master-0,k3s-master-1,k3s-master-2$' <<<"$control_plane_output"
grep -q '^inventory_control_plane_count: 3$' <<<"$control_plane_output"
grep -q '^ready_control_plane_count: 3$' <<<"$control_plane_output"
grep -q '^etcd_quorum_size_from_inventory: 2$' <<<"$control_plane_output"
grep -q 'embedded_etcd_data=present' <<<"$control_plane_output"

control_plane_preflight_output="$(
  PATH="${tmp}:${PATH}" \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/control-plane-delete-preflight.sh" --profile live --context test k3s-master-0
)"

grep -q '^probe_inventory_node: k3s-master-1$' <<<"$control_plane_preflight_output"
grep -q '^etcd_member_count: 3$' <<<"$control_plane_preflight_output"
grep -q '^post_remove_member_count: 2$' <<<"$control_plane_preflight_output"
grep -q '^preflight_result: pass$' <<<"$control_plane_preflight_output"
grep -q '  id: c9e409fd1205cc0a$' <<<"$control_plane_preflight_output"
grep -q 'member remove c9e409fd1205cc0a' <<<"$control_plane_preflight_output"

control_plane_drain_output="$(
  PATH="${tmp}:${PATH}" \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/drain.sh" --profile live --context test --yes k3s-master-0
)"

grep -q 'preflight_result: pass' <<<"$control_plane_drain_output"
grep -q 'drain complete: k3s-master-0' <<<"$control_plane_drain_output"

if PATH="${tmp}:${PATH}" \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
  "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-0 \
  2>"${tmp}/first-master-delete.err"; then
  echo "expected first inventory master delete to be refused" >&2
  exit 1
fi
grep -q 'first inventory master is deferred' "${tmp}/first-master-delete.err"

mkdir -p "${tmp}/control-plane-state"
control_plane_delete_output="$(
  PATH="${tmp}:${PATH}" \
  FAKE_KUBECTL_STATE_DIR="${tmp}/control-plane-state" \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-1
)"

grep -q 'snapshot_name=pre-remove-k3s-master-1-' <<<"$control_plane_delete_output"
grep -q 'Member 70594c7c481c118 removed from cluster' <<<"$control_plane_delete_output"
grep -q 'node "k3s-master-1" deleted' <<<"$control_plane_delete_output"
grep -q 'control-plane delete complete: k3s-master-1' <<<"$control_plane_delete_output"

control_plane_cleanup_output="$(
  PATH="${tmp}:${PATH}" \
  FAKE_KUBECTL_STATE_DIR="${tmp}/control-plane-state" \
  FAKE_ETCD_ABSENT_MEMBER_ID=70594c7c481c118 \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
    "${ROOT}/hack/bootstrap/nodes/delete.sh" --profile live --context test --yes k3s-master-1
)"

grep -q 'stopping k3s server on k3s-master-1 before deleted-node cleanup' <<<"$control_plane_cleanup_output"
grep -q 'verifying k3s-master-1 is absent from etcd membership using k3s-master-0' <<<"$control_plane_cleanup_output"
grep -q 'control-plane delete cleanup complete: k3s-master-1' <<<"$control_plane_cleanup_output"

fake_longhorn_kubectl="${tmp}/kubectl-longhorn"
cat > "$fake_longhorn_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

state_dir="${FAKE_KUBECTL_STATE_DIR:?}"
mode="${FAKE_LONGHORN_MODE:-cleanup}"

if [[ "${1:-}" == "get" && "${2:-}" == "--raw=/readyz" ]]; then
  printf 'ok\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "crd" && "${3:-}" == "volumes.longhorn.io" ]]; then
  printf '{"metadata":{"name":"volumes.longhorn.io"}}\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "node/deleted-node" ]]; then
  printf 'Error from server (NotFound): nodes "deleted-node" not found\n' >&2
  exit 1
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "nodes.longhorn.io/deleted-node" ]]; then
  if [[ -f "${state_dir}/longhorn-node-deleted" ]]; then
    printf 'Error from server (NotFound): nodes.longhorn.io "deleted-node" not found\n' >&2
    exit 1
  fi
  cat <<'JSON'
{
  "metadata": {"name": "deleted-node"},
  "spec": {"allowScheduling": false, "evictionRequested": true},
  "status": {
    "conditions": [
      {"type": "Ready", "status": "False", "reason": "KubernetesNodeGone"},
      {"type": "Schedulable", "status": "False", "reason": "KubernetesNodeCordoned"}
    ]
  }
}
JSON
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "volumes.longhorn.io" ]]; then
  if [[ "$mode" == blockers ]]; then
    cat <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "volume-a"},
      "spec": {"numberOfReplicas": 2, "nodeID": "deleted-node"},
      "status": {"state": "attaching", "robustness": "unknown", "currentNodeID": ""}
    }
  ]
}
JSON
  else
    cat <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "volume-a"},
      "spec": {"numberOfReplicas": 2, "nodeID": "other-a"},
      "status": {"state": "attached", "robustness": "healthy", "currentNodeID": "other-a"}
    }
  ]
}
JSON
  fi
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "engines.longhorn.io" ]]; then
  if [[ "$mode" == blockers ]]; then
    cat <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "volume-a-e-0"},
      "spec": {"volumeName": "volume-a", "nodeID": "deleted-node", "desireState": "running"},
      "status": {"currentState": "stopped", "currentNodeID": "", "ownerID": "other-a"}
    },
    {
      "metadata": {"name": "volume-b-e-0"},
      "spec": {"volumeName": "volume-b", "nodeID": "other-a", "desireState": "running"},
      "status": {"currentState": "stopped", "currentNodeID": "", "ownerID": "deleted-node"}
    }
  ]
}
JSON
  else
    printf '{"items":[]}\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "replicas.longhorn.io" ]]; then
  if [[ -f "${state_dir}/stale-replica-deleted" || "$mode" == blockers ]]; then
    printf '{"items":[]}\n'
  else
    cat <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "stale-replica", "labels": {"longhornnode": "deleted-node", "longhornvolume": "volume-a"}},
      "spec": {"nodeID": "deleted-node", "volumeName": "volume-a", "desireState": "stopped", "failedAt": "2026-05-12T00:00:00Z"},
      "status": {"currentState": "stopped", "started": false, "instanceManagerName": "", "healthyAt": "2026-05-11T00:00:00Z"}
    },
    {
      "metadata": {"name": "healthy-a", "labels": {"longhornnode": "other-a", "longhornvolume": "volume-a"}},
      "spec": {"nodeID": "other-a", "volumeName": "volume-a", "desireState": "running", "failedAt": "", "healthyAt": "2026-05-12T00:00:00Z"},
      "status": {"currentState": "running", "started": true, "instanceManagerName": "im-a"}
    },
    {
      "metadata": {"name": "healthy-b", "labels": {"longhornnode": "other-b", "longhornvolume": "volume-a"}},
      "spec": {"nodeID": "other-b", "volumeName": "volume-a", "desireState": "running", "failedAt": "", "healthyAt": "2026-05-12T00:00:00Z"},
      "status": {"currentState": "running", "started": true, "instanceManagerName": "im-b"}
    }
  ]
}
JSON
  fi
  exit 0
fi

if [[ "${1:-}" == "-n" && "${2:-}" == "longhorn-system" && "${3:-}" == "delete" && "${4:-}" == "replicas.longhorn.io" && "${5:-}" == "stale-replica" ]]; then
  touch "${state_dir}/stale-replica-deleted"
  printf 'replica.longhorn.io "stale-replica" deleted\n'
  exit 0
fi

if [[ "${1:-}" == "-n" && "${2:-}" == "longhorn-system" && "${3:-}" == "delete" && "${4:-}" == "nodes.longhorn.io/deleted-node" ]]; then
  [[ -f "${state_dir}/stale-replica-deleted" ]] || exit 1
  touch "${state_dir}/longhorn-node-deleted"
  printf 'node.longhorn.io "deleted-node" deleted\n'
  exit 0
fi

printf 'unexpected fake Longhorn kubectl args: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$fake_longhorn_kubectl"

mkdir -p "${tmp}/longhorn-state"
longhorn_cleanup_output="$(
  FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" \
  NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_cleanup_longhorn_deleted_node test deleted-node 1"
)"
grep -q 'deleting safe stale Longhorn replica stale-replica' <<<"$longhorn_cleanup_output"
grep -q 'replica.longhorn.io "stale-replica" deleted' <<<"$longhorn_cleanup_output"
grep -q 'node.longhorn.io "deleted-node" deleted' <<<"$longhorn_cleanup_output"

if FAKE_KUBECTL_STATE_DIR="${tmp}/longhorn-state" \
  FAKE_LONGHORN_MODE=blockers \
  NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test deleted-node" \
  >"${tmp}/longhorn-blockers.out" \
  2>"${tmp}/longhorn-blockers.err"; then
  echo "expected Longhorn target-node blockers to fail delete safety" >&2
  exit 1
fi
grep -q 'reason=volume-still-targets-node' "${tmp}/longhorn-blockers.err"
grep -q 'reason=engine-still-targets-node' "${tmp}/longhorn-blockers.err"
grep -q 'volume-b-e-0.*owner=deleted-node.*reason=engine-still-targets-node' "${tmp}/longhorn-blockers.err"

if PATH="${tmp}:${PATH}" \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
  "${ROOT}/hack/bootstrap/nodes/longhorn-evict.sh" --profile live --context test --yes k3s-master-0 \
  2>"${tmp}/first-master-longhorn-evict.err"; then
  echo "expected first inventory master Longhorn eviction to be refused" >&2
  exit 1
fi
grep -q 'first inventory master is deferred' "${tmp}/first-master-longhorn-evict.err"

if PATH="${tmp}:${PATH}" \
  NODE_LIVE_INVENTORY_DIR="$inventory" \
  NODE_KUBECTL_BIN="$fake_control_plane_kubectl" \
  "${ROOT}/hack/bootstrap/nodes/longhorn-evict.sh" --profile live --context test --yes k3s-master-2 \
  >"${tmp}/control-plane-longhorn-evict.out" \
  2>"${tmp}/control-plane-longhorn-evict.err"; then
  echo "expected control-plane Longhorn eviction to fail when Longhorn is absent" >&2
  exit 1
fi
grep -q 'Longhorn is not installed in test' "${tmp}/control-plane-longhorn-evict.err"

"${ROOT}/hack/bootstrap/nodes/drain.sh" --help >/dev/null
"${ROOT}/hack/bootstrap/nodes/control-plane-status.sh" --help >/dev/null
"${ROOT}/hack/bootstrap/nodes/control-plane-delete-preflight.sh" --help >/dev/null
"${ROOT}/hack/bootstrap/nodes/control-plane-delete.sh" --help >/dev/null
"${ROOT}/hack/bootstrap/nodes/delete.sh" --help >/dev/null
"${ROOT}/hack/bootstrap/nodes/longhorn-evict.sh" --help >/dev/null
"${ROOT}/hack/bootstrap/nodes/join.sh" --help >/dev/null
"${ROOT}/hack/bootstrap/nodes/uncordon.sh" --help >/dev/null
"${ROOT}/hack/bootstrap/nodes/refresh-ssh-host-key.sh" --help >/dev/null

fake_longhorn_kubectl="${tmp}/kubectl-longhorn"
cat > "$fake_longhorn_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

if [[ "${1:-}" == "get" && "${2:-}" == "crd" && "${3:-}" == "volumes.longhorn.io" ]]; then
  printf '{"metadata":{"name":"volumes.longhorn.io"}}\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "volumes.longhorn.io" ]]; then
  cat <<'JSON'
{
  "items": [
    {"metadata": {"name": "vol-a"}, "spec": {"numberOfReplicas": 3}, "status": {"state": "detached", "robustness": "healthy", "currentNodeID": ""}}
  ]
}
JSON
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "replicas.longhorn.io" ]]; then
  if [[ "${LONGHORN_REPLICA_CASE:-safe}" == "insufficient" ]]; then
    cat <<'JSON'
{
  "items": [
    {"metadata": {"name": "vol-a-r-target"}, "spec": {"nodeID": "k3s-worker-0", "volumeName": "vol-a", "desireState": "stopped", "failedAt": "2026-05-12T19:47:53Z", "healthyAt": "2026-05-12T18:06:04Z"}, "status": {"currentState": "stopped", "started": false, "instanceManagerName": ""}},
    {"metadata": {"name": "vol-a-r-one"}, "spec": {"nodeID": "k3s-worker-1", "volumeName": "vol-a", "desireState": "running", "failedAt": "", "healthyAt": "2026-05-12T19:48:52Z"}, "status": {"currentState": "running", "started": true, "instanceManagerName": "im-one"}},
    {"metadata": {"name": "vol-a-r-two"}, "spec": {"nodeID": "k3s-worker-2", "volumeName": "vol-a", "desireState": "running", "failedAt": "", "healthyAt": "2026-05-12T19:48:52Z"}, "status": {"currentState": "running", "started": true, "instanceManagerName": "im-two"}}
  ]
}
JSON
  else
    cat <<'JSON'
{
  "items": [
    {"metadata": {"name": "vol-a-r-target"}, "spec": {"nodeID": "k3s-worker-0", "volumeName": "vol-a", "desireState": "stopped", "failedAt": "2026-05-12T19:47:53Z", "healthyAt": "2026-05-12T18:06:04Z"}, "status": {"currentState": "stopped", "started": false, "instanceManagerName": ""}},
    {"metadata": {"name": "vol-a-r-one"}, "spec": {"nodeID": "k3s-worker-1", "volumeName": "vol-a", "desireState": "running", "failedAt": "", "healthyAt": "2026-05-12T19:48:52Z"}, "status": {"currentState": "running", "started": true, "instanceManagerName": "im-one"}},
    {"metadata": {"name": "vol-a-r-two"}, "spec": {"nodeID": "k3s-worker-2", "volumeName": "vol-a", "desireState": "running", "failedAt": "", "healthyAt": "2026-05-12T19:48:52Z"}, "status": {"currentState": "running", "started": true, "instanceManagerName": "im-two"}},
    {"metadata": {"name": "vol-a-r-three"}, "spec": {"nodeID": "k3s-worker-3", "volumeName": "vol-a", "desireState": "running", "failedAt": "", "healthyAt": "2026-05-12T19:48:52Z"}, "status": {"currentState": "running", "started": true, "instanceManagerName": "im-three"}}
  ]
}
JSON
  fi
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "engines.longhorn.io" ]]; then
  printf '{"items":[]}\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "nodes.longhorn.io/k3s-worker-0" ]]; then
  cat <<'JSON'
{
  "metadata": {"name": "k3s-worker-0"},
  "spec": {"allowScheduling": false, "evictionRequested": true},
  "status": {"conditions": [{"type": "Ready", "status": "True"}, {"type": "Schedulable", "status": "False"}]}
}
JSON
  exit 0
fi

if [[ "${1:-}" == "-n" && "${2:-}" == "longhorn-system" && "${3:-}" == "patch" && "${4:-}" == "nodes.longhorn.io/k3s-worker-0" ]]; then
  printf 'node.longhorn.io/k3s-worker-0 patched\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == "nodes.longhorn.io" ]]; then
  cat <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "k3s-worker-0"},
      "spec": {"allowScheduling": true},
      "status": {"conditions": [{"type": "Ready", "status": "True"}, {"type": "Schedulable", "status": "True"}]}
    },
    {
      "metadata": {"name": "k3s-worker-1"},
      "spec": {"allowScheduling": true},
      "status": {"conditions": [{"type": "Ready", "status": "True"}, {"type": "Schedulable", "status": "True"}]}
    },
    {
      "metadata": {"name": "k3s-worker-2"},
      "spec": {"allowScheduling": true},
      "status": {"conditions": [{"type": "Ready", "status": "True"}, {"type": "Schedulable", "status": "True"}]}
    }
  ]
}
JSON
  exit 0
fi

printf 'unexpected fake Longhorn kubectl args: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$fake_longhorn_kubectl"

if NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_eviction_feasible test k3s-worker-0" \
  2>"${tmp}/longhorn-evict.err"; then
  echo "expected Longhorn eviction feasibility to fail for 3 replicas on 2 remaining nodes" >&2
  exit 1
fi
grep -q 'max volume replicas=3, eligible storage nodes after removing target=2' "${tmp}/longhorn-evict.err"

longhorn_node_report="$(
  NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_node_report test k3s-worker-0"
)"
grep -q 'allowScheduling=false evictionRequested=true' <<<"$longhorn_node_report"

longhorn_scheduling_problem="$(
  NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_scheduling_problem test k3s-worker-0"
)"
test -z "$longhorn_scheduling_problem"

longhorn_replica_delete_blockers="$(
  NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_longhorn_replica_delete_blockers test k3s-worker-0"
)"
test -z "$longhorn_replica_delete_blockers"

NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test k3s-worker-0"

if LONGHORN_REPLICA_CASE=insufficient \
  NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_assert_longhorn_empty_for_delete test k3s-worker-0" \
  2>"${tmp}/longhorn-delete.err"; then
  echo "expected Longhorn delete readiness to fail without enough healthy replicas elsewhere" >&2
  exit 1
fi
grep -q 'reason=insufficient-healthy-replicas-elsewhere' "${tmp}/longhorn-delete.err"

restore_scheduling_output="$(
  NODE_KUBECTL_BIN="$fake_longhorn_kubectl" \
    bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_restore_longhorn_scheduling test k3s-worker-0"
)"
grep -q 'node.longhorn.io/k3s-worker-0 patched' <<<"$restore_scheduling_output"

fake_stale_pods_kubectl="${tmp}/kubectl-stale-pods"
stale_pods_state="${tmp}/stale-pods-present"
touch "$stale_pods_state"
cat > "$fake_stale_pods_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

if [[ "${1:-}" == "get" && "${2:-}" == "node/k3s-worker-0" ]]; then
  printf 'Error from server (NotFound): nodes "k3s-worker-0" not found\n' >&2
  exit 1
fi

if [[ "${1:-}" == "get" && "${2:-}" == "pods" && "${3:-}" == "-A" ]]; then
  if [[ -f "${STALE_PODS_STATE}" ]]; then
    cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "namespace": "kube-system",
        "name": "cilium-old",
        "ownerReferences": [{"kind": "DaemonSet"}]
      },
      "spec": {"nodeName": "k3s-worker-0"},
      "status": {"phase": "Running"}
    },
    {
      "metadata": {
        "namespace": "longhorn-system",
        "name": "longhorn-old",
        "ownerReferences": [{"kind": "DaemonSet"}]
      },
      "spec": {"nodeName": "k3s-worker-0"},
      "status": {"phase": "Running"}
    }
  ]
}
JSON
  else
    printf '{"items":[]}\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "-n" && "${3:-}" == "delete" && "${4:-}" == "pod" ]]; then
  rm -f "${STALE_PODS_STATE}"
  printf 'pod "%s" force deleted\n' "${5:-unknown}"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "crd" && "${3:-}" == "volumes.longhorn.io" ]]; then
  printf 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "volumes.longhorn.io" not found\n' >&2
  exit 1
fi

printf 'unexpected fake stale-pods kubectl args: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$fake_stale_pods_kubectl"

STALE_PODS_STATE="$stale_pods_state" \
NODE_KUBECTL_BIN="$fake_stale_pods_kubectl" \
  bash -c "source '${ROOT}/hack/bootstrap/nodes/lib.sh'; node_cleanup_pods_for_deleted_node test k3s-worker-0"
test ! -e "$stale_pods_state"

echo "offline node lifecycle test passed"
