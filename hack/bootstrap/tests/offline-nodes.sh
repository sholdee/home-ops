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

"${ROOT}/hack/bootstrap/nodes/drain.sh" --help >/dev/null
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
