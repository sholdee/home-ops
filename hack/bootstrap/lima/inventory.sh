#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

lima_require_common_tools

inventory_dir="$(lima_inventory_source_dir)"
generated_inventory_dir="$(lima_inventory_dir)"
inventory_file="${inventory_dir}/hosts.yml"
group_vars_dir="${inventory_dir}/group_vars"
mkdir -p "$group_vars_dir"

server_ip="$(lima_guest_ip "$LIMA_SERVER_NAME")"
[[ -n "$server_ip" ]] || lima_die "could not determine guest IP for ${LIMA_SERVER_NAME}"
server_iface="$(lima_guest_iface "$LIMA_SERVER_NAME")"
[[ -n "$server_iface" ]] || lima_die "could not determine guest interface for ${LIMA_SERVER_NAME}"
server_ssh_user="$(lima_ssh_option "$LIMA_SERVER_NAME" User)"
[[ -n "$server_ssh_user" ]] || lima_die "could not determine SSH user for ${LIMA_SERVER_NAME}"

write_host_vars() {
  local instance="$1"
  local role="$2"
  local ssh_config ssh_user
  ssh_config="$(lima_ssh_config_file "$instance")"
  [[ -f "$ssh_config" ]] || lima_die "could not read SSH config for ${instance}"
  ssh_user="$(lima_ssh_option "$instance" User)"
  [[ -n "$ssh_user" ]] || lima_die "could not determine SSH user for ${instance}"
  cat <<EOF
            ${instance}:
              ansible_host: lima-${instance}
              ansible_user: ${ssh_user}
              ansible_ssh_common_args: >-
                -F ${ssh_config}
                -o StrictHostKeyChecking=no
                -o UserKnownHostsFile=/dev/null
              k3s_role: ${role}
EOF
}

{
  cat <<EOF
---
all:
  children:
    k3s_cluster:
      children:
        master:
          hosts:
EOF
  for server in "${LIMA_SERVER_NAMES[@]}"; do
    write_host_vars "$server" server
  done
  cat <<EOF
        node:
          hosts:
EOF
  for agent in "${LIMA_AGENT_NAMES[@]}"; do
    write_host_vars "$agent" agent
  done
} > "$inventory_file"

cat > "${group_vars_dir}/all.yml" <<EOF
---
ansible_user: ${server_ssh_user}
systemd_dir: /etc/systemd/system
system_timezone: Etc/UTC

proxmox_lxc_configure: false
custom_registries: false

cilium_iface: ${server_iface}
enable_bpf_masquerade: true

# Lima user-mode networking does not provide a reliable L2 ARP VIP for node join.
# Live inventory still pins kube-vip to v1.1.2.
kube_vip_enabled: false
kube_vip_arp: true
kube_vip_bgp: false
apiserver_endpoint: ${server_ip}
k3s_token: homeopslimabootstrap
k3s_master_taint: ${LIMA_K3S_MASTER_TAINT}
retry_count: 45

k3s_node_ip: "{{ ansible_facts[cilium_iface]['ipv4']['address'] }}"
extra_args: >-
  --node-ip={{ k3s_node_ip }}
extra_server_args: >-
  {{ extra_args }}
  {{ '--node-taint node-role.kubernetes.io/master=true:NoSchedule' if k3s_master_taint else '' }}
  --flannel-backend=none
  --disable-network-policy
  --cluster-cidr={{ cluster_cidr }}
  --tls-san {{ apiserver_endpoint }}
  --disable servicelb
  --disable traefik
extra_agent_args: >-
  {{ extra_args }}
EOF

"${BOOTSTRAP_DIR}/ansible/render-inventory.sh" \
  --profile lima \
  --inventory-source "$inventory_dir" \
  --output-dir "$generated_inventory_dir"

lima_log "wrote inventory: $(lima_inventory_file)"
