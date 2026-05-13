# shellcheck shell=bash
# shellcheck disable=SC2154

create_node_inventory() {
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
}

write_worker_status_kubectl() {
  fake_kubectl="${tmp}/kubectl"
  cat > "$fake_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

if [[ "${1:-}" == "config" && "${2:-}" == "view" ]]; then
  server="${FAKE_CLUSTER_SERVER:-https://192.168.99.77:6443}"
  cat <<JSON
{
  "contexts": [
    {
      "name": "test",
      "context": {"cluster": "test-cluster"}
    }
  ],
  "clusters": [
    {
      "name": "test-cluster",
      "cluster": {"server": "${server}"}
    }
  ]
}
JSON
  exit 0
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
}

write_control_plane_kubectl() {
  fake_control_plane_kubectl="${tmp}/kubectl-control-plane"
  cat > "$fake_control_plane_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

if [[ "${1:-}" == "config" && "${2:-}" == "view" ]]; then
  server="${FAKE_CLUSTER_SERVER:-https://192.168.99.77:6443}"
  cat <<JSON
{
  "contexts": [
    {
      "name": "test",
      "context": {"cluster": "test-cluster"}
    }
  ],
  "clusters": [
    {
      "name": "test-cluster",
      "cluster": {"server": "${server}"}
    }
  ]
}
JSON
  exit 0
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
  node_index="${node_name##*-}"
  node_ip="192.168.99.1${node_index}"
  sed -e "s/__NODE_NAME__/${node_name}/g" -e "s/__NODE_IP__/${node_ip}/g" <<'JSON'
{
  "metadata": {
    "name": "__NODE_NAME__",
    "labels": {"node-role.kubernetes.io/control-plane": "true"}
  },
  "spec": {
    "unschedulable": true
  },
  "status": {
    "addresses": [
      {"type": "InternalIP", "address": "__NODE_IP__"}
    ],
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
}

write_fake_ansible() {
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
}

write_deleted_node_longhorn_kubectl() {
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
}

write_eviction_longhorn_kubectl() {
  fake_longhorn_kubectl="${tmp}/kubectl-longhorn-eviction"
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
}

write_stale_pods_kubectl() {
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
}
