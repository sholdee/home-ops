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
kube_proxy_replacement: true
k3s_version: v1.35.4+k3s1
EOF
}

add_inventory_worker() {
  local name="$1"
  local address="$2"
  NODE_NAME="$name" NODE_ADDRESS="$address" yq -i '
    .all.children.k3s_cluster.children.node.hosts[strenv(NODE_NAME)] = {
      "ansible_host": strenv(NODE_ADDRESS),
      "k3s_role": "agent"
    }
  ' "${inventory}/hosts.yml"
}

add_reimage_identity() {
  local name="$1"
  local pi_serial="$2"
  local disk_serial="$3"
  local disk_path="${4:-/dev/nvme0n1}"
  local group=node
  if NODE_NAME="$name" yq -e '.all.children.k3s_cluster.children.master.hosts[strenv(NODE_NAME)] != null' "${inventory}/hosts.yml" >/dev/null; then
    group=master
  fi
  NODE_NAME="$name" PI_SERIAL="$pi_serial" DISK_SERIAL="$disk_serial" DISK_PATH="$disk_path" GROUP="$group" yq -i '
    .all.children.k3s_cluster.children[strenv(GROUP)].hosts[strenv(NODE_NAME)].home_ops_reimage_pi_serial = strenv(PI_SERIAL) |
    .all.children.k3s_cluster.children[strenv(GROUP)].hosts[strenv(NODE_NAME)].home_ops_reimage_disk_serial = strenv(DISK_SERIAL) |
    .all.children.k3s_cluster.children[strenv(GROUP)].hosts[strenv(NODE_NAME)].home_ops_reimage_disk_path = strenv(DISK_PATH)
  ' "${inventory}/hosts.yml"
}

add_inventory_master() {
  local name="$1"
  local address="$2"
  NODE_NAME="$name" NODE_ADDRESS="$address" yq -i '
    .all.children.k3s_cluster.children.master.hosts[strenv(NODE_NAME)] = {
      "ansible_host": strenv(NODE_ADDRESS),
      "k3s_role": "server"
    }
  ' "${inventory}/hosts.yml"
}

write_converge_nodes_json() {
  local file="$1"
  shift
  printf '{"items":[' > "$file"
  local first=true
  local node name role ready schedulable taint version role_labels spec_fields
  for spec in "$@"; do
    IFS=: read -r name role ready schedulable taint version <<<"$spec"
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ',' >> "$file"
    fi
    if [[ "$role" == master ]]; then
      role_labels='"node-role.kubernetes.io/control-plane":"true"'
    else
      role_labels=''
    fi
    spec_fields=''
    if [[ "$schedulable" == cordoned ]]; then
      spec_fields='"unschedulable":true'
    fi
    case "$taint" in
      present)
        taints='"taints":[{"key":"node.home-ops.sh/joining","value":"true","effect":"NoSchedule"}]'
        ;;
      invalid)
        taints='"taints":[{"key":"node.home-ops.sh/joining","value":"true","effect":"PreferNoSchedule"}]'
        ;;
      *)
        taints=''
        ;;
    esac
    if [[ -n "$taints" ]]; then
      if [[ -n "$spec_fields" ]]; then
        spec_fields="${spec_fields},${taints}"
      else
        spec_fields="$taints"
      fi
    fi
    node="$(cat <<JSON
{
  "metadata": {
    "name": "${name}",
    "labels": {${role_labels}}
  },
  "spec": {${spec_fields}},
  "status": {
    "conditions": [{"type": "Ready", "status": "${ready}"}],
    "nodeInfo": {"kubeletVersion": "${version:-v1.35.4+k3s1}"}
  }
}
JSON
)"
    printf '%s' "$node" >> "$file"
  done
  printf ']}\n' >> "$file"
}

write_default_converge_nodes_json() {
  write_converge_nodes_json "$1" \
    "k3s-master-0:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-1:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-master-2:master:True:schedulable:absent:v1.35.4+k3s1" \
    "k3s-worker-0:node:True:schedulable:absent:v1.35.4+k3s1"
}

write_converge_kubectl() {
  fake_converge_kubectl="${tmp}/kubectl-converge"
  cat > "$fake_converge_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

if [[ "${1:-}" == "config" && "${2:-}" == "current-context" ]]; then
  printf '%s\n' "${FAKE_CURRENT_CONTEXT:-test}"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "--raw=/readyz" ]]; then
  printf 'ok\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "nodes" ]]; then
  cat "${FAKE_CONVERGE_NODES_JSON:?}"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "crd" && "${3:-}" == "volumes.longhorn.io" ]]; then
  if [[ "${FAKE_LONGHORN_INSTALLED:-false}" == true ]]; then
    printf '{"metadata":{"name":"volumes.longhorn.io"}}\n'
    exit 0
  fi
  printf 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "volumes.longhorn.io" not found\n' >&2
  exit 1
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "longhorn-system" && "${4:-}" == nodes.longhorn.io/* ]]; then
  node="${4#nodes.longhorn.io/}"
  allow=true
  if [[ "${FAKE_LONGHORN_DISABLED_NODE:-}" == "$node" ]]; then
    allow=false
  fi
  printf '{"metadata":{"name":"%s"},"spec":{"allowScheduling":%s},"status":{"conditions":[{"type":"Ready","status":"True"},{"type":"Schedulable","status":"True"}]}}\n' "$node" "$allow"
  exit 0
fi

printf 'unexpected fake converge kubectl args: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "$fake_converge_kubectl"
}

write_fake_join_script() {
  fake_join_script="${tmp}/join.sh"
  cat > "$fake_join_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_JOIN_CALLS:?}"
EOF
  chmod +x "$fake_join_script"
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

if [[ "$joined_args" == *"ansible.builtin.copy"* ]]; then
  printf '{"changed": true}\n'
  exit 0
fi

if [[ "$joined_args" == *"disk_path="* && "$joined_args" == *"raspberry_pi"* ]]; then
  printf 'hostname=%s\n' "$target"
  printf 'pi_model=%s\n' "${FAKE_REIMAGE_PI_MODEL:-Raspberry Pi 5 Model B Rev 1.0}"
  printf 'raspberry_pi=%s\n' "${FAKE_REIMAGE_IS_PI:-true}"
  printf 'pi_serial=%s\n' "${FAKE_REIMAGE_PI_SERIAL:-10000000deadbeef}"
  printf 'mac_addresses=%s\n' "${FAKE_REIMAGE_MACS:-dc:a6:32:00:00:01}"
  printf 'disk_present=%s\n' "${FAKE_REIMAGE_DISK_PRESENT:-true}"
  printf 'disk_path=%s\n' "${FAKE_REIMAGE_DISK_PATH:-/dev/nvme0n1}"
  printf 'disk_model=%s\n' "${FAKE_REIMAGE_DISK_MODEL:-Samsung SSD}"
  printf 'disk_serial=%s\n' "${FAKE_REIMAGE_DISK_SERIAL:-nvme-deadbeef}"
  printf 'disk_size_bytes=%s\n' "${FAKE_REIMAGE_DISK_SIZE:-500107862016}"
  printf 'boot_firmware_mounted=%s\n' "${FAKE_REIMAGE_BOOT_MOUNTED:-true}"
  exit 0
fi

if [[ "$joined_args" == *"reimage_stage=present"* ]]; then
  printf 'manifest_begin\n'
  staged_inventory_node="${FAKE_REIMAGE_STAGED_INVENTORY_NODE:-k3s-worker-0}"
  staged_kubernetes_node="${FAKE_REIMAGE_STAGED_KUBERNETES_NODE:-k3s-worker-0}"
  staged_target_disk="${FAKE_REIMAGE_STAGED_TARGET_DISK:-/dev/nvme0n1}"
  staged_target_disk_serial="${FAKE_REIMAGE_STAGED_DISK_SERIAL:-nvme-deadbeef}"
  staged_pi_serial="${FAKE_REIMAGE_STAGED_PI_SERIAL:-10000000deadbeef}"
  staged_stage_dir="${FAKE_REIMAGE_STAGED_STAGE_DIR:-/boot/firmware/home-ops-reimage}"
  cat <<JSON
{
  "schemaVersion": "home-ops.node-reimage-stage/v1",
  "inventoryNode": "${staged_inventory_node}",
  "kubernetesNode": "${staged_kubernetes_node}",
  "targetDisk": "${staged_target_disk}",
  "targetDiskSerial": "${staged_target_disk_serial}",
  "raspberryPiSerial": "${staged_pi_serial}",
  "stageDir": "${staged_stage_dir}"
}
JSON
  printf 'manifest_end\n'
  printf 'reimage_stage=present\n'
  exit 0
fi

if [[ "$joined_args" == *"manifest.json"* || "$joined_args" == *"tryboot.txt"* ]]; then
  printf 'staged_file=true\n'
  exit 0
fi

if [[ "$joined_args" == *"0 tryboot"* ]]; then
  if [[ -n "${FAKE_REBOOT_STATE_DIR:-}" ]]; then
    mkdir -p "$FAKE_REBOOT_STATE_DIR"
    touch "${FAKE_REBOOT_STATE_DIR}/tryboot-rebooted-${target}"
  fi
  printf 'tryboot_reboot_scheduled=true\n'
  exit 0
fi

if [[ "$joined_args" == *"systemctl reboot"* ]]; then
  if [[ -n "${FAKE_REBOOT_STATE_DIR:-}" ]]; then
    mkdir -p "$FAKE_REBOOT_STATE_DIR"
    touch "${FAKE_REBOOT_STATE_DIR}/rebooted-${target}"
  fi
  printf 'reboot_scheduled=true\n'
  exit 0
fi

if [[ "$joined_args" == *"90-home-ops-kube-proxy.yaml"* ]]; then
  if [[ "${FAKE_KUBE_PROXY_DROPIN:-present}" == missing ]]; then
    printf 'kube_proxy_disable_dropin=missing\n'
    exit 2
  fi
  printf 'kube_proxy_disable_dropin=present\n'
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

write_reimage_kubectl() {
  fake_reimage_kubectl="${tmp}/kubectl-reimage"
  cat > "$fake_reimage_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

if [[ "${1:-}" == "get" && "${2:-}" == "--raw=/readyz" ]]; then
  printf 'ok\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" =~ ^node/k3s-(worker|master)-[0-9]+$ ]]; then
  node_name="${2#node/}"
  if [[ "${FAKE_REIMAGE_NODE_ABSENT:-false}" == true ]]; then
    printf 'Error from server (NotFound): nodes "%s" not found\n' "$node_name" >&2
    exit 1
  fi
  printf '{"metadata":{"name":"%s","labels":{}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}\n' "$node_name"
  exit 0
fi

printf 'unexpected fake reimage kubectl args: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "$fake_reimage_kubectl"
}

write_reboot_kubectl() {
  fake_reboot_kubectl="${tmp}/kubectl-reboot"
  cat > "$fake_reboot_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--context" ]]; then
  shift 2
fi

state_dir="${FAKE_REBOOT_STATE_DIR:?}"

if [[ "${1:-}" == "config" && "${2:-}" == "view" ]]; then
  cat <<'JSON'
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
      "cluster": {"server": "https://192.168.99.77:6443"}
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
  boot_id="boot-before"
  if [[ -f "${state_dir}/rebooted-k3s-worker-0" ]]; then
    boot_id="boot-after"
  fi
  sed -e "s/__BOOT_ID__/${boot_id}/g" <<'JSON'
{
  "metadata": {
    "name": "k3s-worker-0",
    "labels": {}
  },
  "spec": {
    "unschedulable": true
  },
  "status": {
    "conditions": [
      {"type": "Ready", "status": "True"}
    ],
    "nodeInfo": {
      "bootID": "__BOOT_ID__"
    }
  }
}
JSON
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "pods" ]]; then
  printf '{"items":[]}\n'
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "-n" && "${3:-}" == "kube-system" && "${4:-}" == "pods" ]]; then
  cat <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "cilium-worker"},
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

printf 'unexpected fake reboot kubectl args: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "$fake_reboot_kubectl"
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
