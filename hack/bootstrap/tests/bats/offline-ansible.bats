#!/usr/bin/env bats
# shellcheck shell=bash

load '../helpers/common.bash'

setup_file() {
  require_tools yq jq
}

setup() {
  tmp="$BATS_TEST_TMPDIR"
  k3s_ansible="${tmp}/k3s-ansible"
  mkdir -p "${k3s_ansible}/inventory/sample/group_vars"
  cilium_tag="$(bootstrap_repo_cilium_tag)"
  expected_apiserver_endpoint="$(repo_apiserver_endpoint)"
  expected_cluster_cidr="$(repo_cluster_cidr)"
  expected_k3s_version="$(repo_k3s_version)"
  expected_kube_proxy_replacement="$(repo_kube_proxy_replacement)"

  cat > "${k3s_ansible}/inventory/sample/group_vars/all.yml" <<'EOF'
---
ansible_user: ansibleuser
k3s_version: old
cilium_tag: old
system_timezone: Etc/UTC
custom_registries: false
proxmox_lxc_configure: false
k3s_token: sample-token
EOF
}

render_k3s_ansible_inventory() {
  out="${tmp}/out"
  K3S_ANSIBLE_DIR="$k3s_ansible" \
  BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible \
  BOOTSTRAP_ANSIBLE_OUT_DIR="$out" \
    "${ROOT}/hack/bootstrap/ansible/render-inventory.sh" --profile live >/dev/null
  vars="${out}/inventory/live/group_vars/all.yml"
}

render_home_ops_inventory() {
  home_ops_out="${tmp}/home-ops-out"
  BOOTSTRAP_ANSIBLE_OUT_DIR="$home_ops_out" \
    "${ROOT}/hack/bootstrap/ansible/render-inventory.sh" --profile live >/dev/null
  home_ops_vars="${home_ops_out}/inventory/live/group_vars/all.yml"
}

assert_file_contains_before() {
  local file="$1"
  local before="$2"
  local after="$3"
  if ! awk -v before="$before" -v after="$after" '
    index($0, before) && !before_line { before_line = NR }
    index($0, after) && !after_line { after_line = NR }
    END { exit !(before_line && after_line && before_line < after_line) }
  ' "$file"; then
    printf 'expected %s to contain %s before %s\n' "$file" "$before" "$after" >&2
    sed -n '1,120p' "$file" >&2 || true
    return 1
  fi
}

@test "k3s-ansible backend render derives home-ops live vars without preserving sample token" {
  render_k3s_ansible_inventory

  local expected_key
  expected_key="$(printf '\176/%s' ansiblekey)"
  [[ "$(yq -r '.ansible_user' "$vars")" == "ethan" ]]
  [[ "$(yq -r '.ansible_ssh_private_key_file' "$vars")" == "$expected_key" ]]
  [[ "$(yq -r '.k3s_version' "$vars")" == "$expected_k3s_version" ]]
  [[ "$(yq -r '.cilium_tag' "$vars")" == "$cilium_tag" ]]
  [[ "$(yq -r '.cluster_cidr' "$vars")" == "$expected_cluster_cidr" ]]
  [[ "$(yq -r '.kube_proxy_replacement' "$vars")" == "$expected_kube_proxy_replacement" ]]
  [[ "$(yq -r '.apiserver_endpoint' "$vars")" == "$expected_apiserver_endpoint" ]]
  [[ "$(yq -r '.k3s_token' "$vars")" == "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}" ]]
  assert_file_not_contains "$vars" 'sample-token'
  run bash -c "yq -r '.extra_server_args' '$vars' | grep -q -- '--disable-kube-proxy'"
  assert_failure
}

@test "home-ops backend render derives live vars and default helper paths" {
  render_home_ops_inventory

  [[ "$(yq -r '.ansible_user' "$home_ops_vars")" == "ethan" ]]
  [[ "$(yq -r '.k3s_version' "$home_ops_vars")" == "$expected_k3s_version" ]]
  [[ "$(yq -r '.cilium_tag' "$home_ops_vars")" == "$cilium_tag" ]]
  [[ "$(yq -r '.cluster_cidr' "$home_ops_vars")" == "$expected_cluster_cidr" ]]
  [[ "$(yq -r '.k3s_token' "$home_ops_vars")" == "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}" ]]
  [[ "$(yq -r '.home_ops_etcdctl_version_override' "$home_ops_vars")" == "" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_enabled' "$home_ops_vars")" == "true" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_supplementary_groups | join(",")' "$home_ops_vars")" == "video" ]]
  [[ "$(yq -r '.home_ops_nut_client_enabled' "$home_ops_vars")" == "true" ]]
  [[ "$(yq -r '.home_ops_github_runner_enabled' "$home_ops_vars")" == "true" ]]
  [[ "$(yq -r '.home_ops_github_runner_version' "$home_ops_vars")" == "2.334.0" ]]
  [[ "$(yq -r '.home_ops_github_runner_user' "$home_ops_vars")" == "github-runner" ]]
  [[ "$(yq -r '.home_ops_github_runner_service_name' "$home_ops_vars")" == 'actions.runner.{{ home_ops_github_runner_repo_owner }}-{{ home_ops_github_runner_repo_name }}.{{ home_ops_github_runner_name }}.service' ]]
  [[ "$(yq -r '.home_ops_github_runner_service_file' "$home_ops_vars")" == '{{ systemd_dir }}/{{ home_ops_github_runner_service_name }}' ]]
  [[ "$(yq -r '.home_ops_github_runner_crictl_path' "$home_ops_vars")" == "/var/lib/rancher/k3s/data/current/bin/crictl" ]]
  [[ "$(yq -r '.home_ops_github_runner_crictl_timeout' "$home_ops_vars")" == "30s" ]]
  [[ "$(yq -r '.home_ops_k3s_embedded_registry' "$home_ops_vars")" == "true" ]]
  [[ "$(yq -r '.home_ops_k3s_etcd_expose_metrics' "$home_ops_vars")" == "true" ]]
  assert_file_contains "$home_ops_vars" '--embedded-registry'
  assert_file_contains "$home_ops_vars" '--etcd-expose-metrics'
  [[ "$(yq -r '.home_ops_rpi_reporter_update_existing' "$home_ops_vars")" == "false" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_restart_on_change' "$home_ops_vars")" == "false" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_interval_in_minutes' "$home_ops_vars")" == "2" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_fallback_domain' "$home_ops_vars")" == "home" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_mqtt_base_topic' "$home_ops_vars")" == "home/nodes" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_mqtt_keepalive' "$home_ops_vars")" == "20" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_mqtt_port' "$home_ops_vars")" == "8883" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_mqtt_tls' "$home_ops_vars")" == "true" ]]
  [[ "$(yq -r '.home_ops_nut_client_restart_on_change' "$home_ops_vars")" == "false" ]]
  [[ "$(yq -r '.cilium_iface' "$home_ops_vars")" == "auto" ]]
  [[ "$(yq -r '.k3s_node_ip' "$home_ops_vars")" == "{{ ansible_host }}" ]]
  [[ "$(yq -r '.home_ops_validate_ansible_host_ip' "$home_ops_vars")" == "true" ]]
  [[ "$(yq -r '.home_ops_fsnotify_max_user_instances' "$home_ops_vars")" == "1024" ]]
  [[ "$(yq -r '.home_ops_fsnotify_max_user_watches' "$home_ops_vars")" == "524288" ]]
  [[ "$(yq -r '.home_ops_fsnotify_max_queued_events' "$home_ops_vars")" == "65536" ]]
  assert_file_not_contains "$home_ops_vars" 'sample-token'

  local raw_kubeconfig default_lima_inventory default_backend
  raw_kubeconfig="$(
    BOOTSTRAP_ANSIBLE_OUT_DIR="$home_ops_out" \
      bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_raw_kubeconfig_file live"
  )"
  [[ "$raw_kubeconfig" == "${home_ops_out}/kubeconfig-raw-live" ]]

  default_lima_inventory="$(
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_set_profile lima; ansible_inventory_dir"
  )"
  [[ "$default_lima_inventory" == "${ROOT}/hack/bootstrap/.out/ansible-lima/inventory/lima" ]]

  default_backend="$(
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; printf '%s\n' \"\$BOOTSTRAP_ANSIBLE_BACKEND\""
  )"
  [[ "$default_backend" == "home-ops" ]]
}

@test "Ansible playbooks and K3s service templates remain syntactically valid" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible-playbook not installed"
  render_home_ops_inventory

  local playbook
  for playbook in \
    "${ROOT}/hack/bootstrap/ansible/home-ops/site.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/host-services.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/control-plane-join.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/control-plane-finalize.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/worker-join.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/worker-finalize.yml" \
    "${ROOT}/hack/bootstrap/ansible/playbooks/home-ops-prereqs.yml" \
    "${ROOT}/hack/bootstrap/ansible/playbooks/disable-kube-proxy.yml"; do
    run ansible-playbook --syntax-check -i "${home_ops_out}/inventory/live/hosts.yml" "$playbook"
    assert_success
  done

  local render_playbook rendered_service render_server_playbook rendered_server_service
  render_playbook="${tmp}/render-agent-service.yml"
  rendered_service="${tmp}/k3s-node.service"
  cat > "$render_playbook" <<EOF
---
- name: Render K3s agent service template
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_python_interpreter: "{{ ansible_playbook_python }}"
    home_ops_k3s_binary_path: /usr/local/bin/k3s
    home_ops_agent_args: "--server https://example.invalid:6443 --token-file /token"
    home_ops_node_taints:
      - node.home-ops.sh/joining=true:NoSchedule
  tasks:
    - name: Render agent service
      ansible.builtin.template:
        src: ${ROOT}/hack/bootstrap/ansible/home-ops/templates/k3s-agent.service.j2
        dest: ${rendered_service}
        mode: "0644"
EOF
  run ansible-playbook -i localhost, "$render_playbook"
  assert_success
  assert_file_contains "$rendered_service" '--node-taint node.home-ops.sh/joining=true:NoSchedule'
  assert_file_contains "$rendered_service" 'KillMode=process'
  assert_file_not_contains "$rendered_service" 'NoScheduleKillMode'

  render_server_playbook="${tmp}/render-server-service.yml"
  rendered_server_service="${tmp}/k3s.service"
  cat > "$render_server_playbook" <<EOF
---
- name: Render K3s server service template
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_python_interpreter: "{{ ansible_playbook_python }}"
    home_ops_k3s_binary_path: /usr/local/bin/k3s
    home_ops_k3s_exec_args: "--server https://example.invalid:6443 --token-file /token"
    home_ops_node_taints:
      - node.home-ops.sh/joining=true:NoSchedule
  tasks:
    - name: Render server service
      ansible.builtin.template:
        src: ${ROOT}/hack/bootstrap/ansible/home-ops/templates/k3s-server.service.j2
        dest: ${rendered_server_service}
        mode: "0644"
EOF
  run ansible-playbook -i localhost, "$render_server_playbook"
  assert_success
  assert_file_contains "$rendered_server_service" '--node-taint node.home-ops.sh/joining=true:NoSchedule'
  assert_file_contains "$rendered_server_service" 'KillMode=process'
  assert_file_not_contains "$rendered_server_service" 'NoScheduleKillMode'

  local render_rpi_reporter_playbook rendered_rpi_reporter_service
  render_rpi_reporter_playbook="${tmp}/render-rpi-reporter-service.yml"
  rendered_rpi_reporter_service="${tmp}/isp-rpi-reporter.service"
  cat > "$render_rpi_reporter_playbook" <<EOF
---
- name: Render RPi reporter service template
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - ${ROOT}/hack/bootstrap/ansible/home-ops/vars/defaults.yml
  vars:
    ansible_python_interpreter: "{{ ansible_playbook_python }}"
  tasks:
    - name: Render RPi reporter service
      ansible.builtin.template:
        src: ${ROOT}/hack/bootstrap/ansible/home-ops/templates/isp-rpi-reporter.service.j2
        dest: ${rendered_rpi_reporter_service}
        mode: "0644"
EOF
  run ansible-playbook -i localhost, "$render_rpi_reporter_playbook"
  assert_success
  assert_file_contains "$rendered_rpi_reporter_service" 'User=daemon'
  assert_file_contains "$rendered_rpi_reporter_service" 'Group=daemon'
  assert_file_contains "$rendered_rpi_reporter_service" 'SupplementaryGroups=video'

  local render_crictl_playbook rendered_crictl_wrapper
  render_crictl_playbook="${tmp}/render-crictl-wrapper.yml"
  rendered_crictl_wrapper="${tmp}/home-ops-crictl"
  cat > "$render_crictl_playbook" <<EOF
---
- name: Render GitHub runner crictl wrapper
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - ${ROOT}/hack/bootstrap/ansible/home-ops/vars/defaults.yml
  vars:
    ansible_python_interpreter: "{{ ansible_playbook_python }}"
  tasks:
    - name: Render crictl wrapper
      ansible.builtin.template:
        src: ${ROOT}/hack/bootstrap/ansible/home-ops/templates/home-ops-crictl.j2
        dest: ${rendered_crictl_wrapper}
        mode: "0755"
EOF
  run ansible-playbook -i localhost, "$render_crictl_playbook"
  assert_success
  assert_file_contains "$rendered_crictl_wrapper" 'timeout=30s'
  assert_file_contains "$rendered_crictl_wrapper" "--timeout \"\$timeout\""
}

@test "home-ops backend wires K3s registry mirrors before K3s start and join" {
  local defaults expected_mirrors actual_mirrors playbook
  defaults="${ROOT}/hack/bootstrap/ansible/home-ops/vars/defaults.yml"
  expected_mirrors="docker.io,ecr-public.aws.com,ghcr.io,oci.external-secrets.io,quay.io,registry.k8s.io"
  actual_mirrors="$(yq -r '.home_ops_k3s_registry_mirrors | keys | sort | join(",")' "$defaults")"

  [[ "$(yq -r '.home_ops_k3s_registries_file' "$defaults")" == '{{ home_ops_k3s_config_dir }}/registries.yaml' ]]
  [[ "$(yq -r '.home_ops_k3s_embedded_registry' "$defaults")" == "true" ]]
  [[ "$actual_mirrors" == "$expected_mirrors" ]]

  for playbook in site control-plane-join control-plane-finalize worker-join worker-finalize; do
    assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/${playbook}.yml" 'tasks/k3s/registries.yml'
  done
  assert_file_contains_before "$ROOT/hack/bootstrap/ansible/home-ops/site.yml" 'tasks/k3s/registries.yml' 'tasks/k3s/first-server.yml'
  assert_file_contains_before "$ROOT/hack/bootstrap/ansible/home-ops/site.yml" 'tasks/k3s/registries.yml' 'tasks/k3s/join-servers.yml'
  assert_file_contains_before "$ROOT/hack/bootstrap/ansible/home-ops/site.yml" 'tasks/k3s/registries.yml' 'tasks/k3s/join-agents.yml'
  assert_file_contains_before "$ROOT/hack/bootstrap/ansible/home-ops/control-plane-join.yml" 'tasks/k3s/registries.yml' 'tasks/k3s/join-servers.yml'
  assert_file_contains_before "$ROOT/hack/bootstrap/ansible/home-ops/control-plane-finalize.yml" 'tasks/k3s/registries.yml' 'tasks/k3s/join-servers.yml'
  assert_file_contains_before "$ROOT/hack/bootstrap/ansible/home-ops/worker-join.yml" 'tasks/k3s/registries.yml' 'tasks/k3s/join-agents.yml'
  assert_file_contains_before "$ROOT/hack/bootstrap/ansible/home-ops/worker-finalize.yml" 'tasks/k3s/registries.yml' 'tasks/k3s/join-agents.yml'

  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/registries.yml" 'templates/registries.yaml.j2'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/registries.yml" 'home_ops_k3s_registries_file'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/registries.yml" 'register: home_ops_k3s_registries_config'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" '--embedded-registry'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/registries.yaml.j2" 'mirrors:'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/registries.yaml.j2" 'home_ops_k3s_registry_mirrors'
}

@test "K3s service tasks do not restart already-running nodes for config drift" {
  local first_server join_agents join_servers task

  first_server="${ROOT}/hack/bootstrap/ansible/home-ops/tasks/k3s/first-server.yml"
  join_agents="${ROOT}/hack/bootstrap/ansible/home-ops/tasks/k3s/join-agents.yml"
  join_servers="${ROOT}/hack/bootstrap/ansible/home-ops/tasks/k3s/join-servers.yml"

  for task in \
    "$first_server" \
    "$join_agents" \
    "$join_servers"; do
    assert_file_contains "$task" 'state: started'
    assert_file_not_contains "$task" "'restarted'"
  done

  assert_file_not_contains "$first_server" 'state: restarted'
  assert_file_not_contains "$join_agents" 'state: restarted'
  [[ "$(grep -c 'state: restarted' "$join_servers")" == "1" ]]
  assert_file_contains "$join_servers" 'Restart fresh joining K3s server after kube-proxy disable config'
  assert_file_contains "$join_servers" 'not (home_ops_k3s_installed | default(false) | bool)'
  assert_file_contains "$join_servers" 'home_ops_kube_proxy_config.changed | default(false) | bool'
}

@test "static Ansible lifecycle invariants are present" {
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib.sh" "source \"\${ANSIBLE_BOOTSTRAP_DIR}/lib/inventory.sh\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib.sh" "source \"\${ANSIBLE_BOOTSTRAP_DIR}/lib/op.sh\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib.sh" "source \"\${ANSIBLE_BOOTSTRAP_DIR}/lib/token.sh\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib.sh" "source \"\${ANSIBLE_BOOTSTRAP_DIR}/lib/host-services.sh\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib.sh" "source \"\${ANSIBLE_BOOTSTRAP_DIR}/lib/playbooks.sh\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/op.sh" 'op signin --force'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/op.sh" 'BOOTSTRAP_ANSIBLE_OP_SIGNIN_TTY:-/dev/tty'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/token.sh" 'ansible_op_read_optional'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/run.sh" 'ansible_disable_kube_proxy_after_cilium'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/run.sh" 'ansible_require_host_service_env all'
  assert_file_not_contains "$ROOT/hack/bootstrap/ansible/node-worker.sh" 'ansible_require_host_service_env node'
  assert_file_not_contains "$ROOT/hack/bootstrap/ansible/node-control-plane.sh" 'ansible_require_host_service_env master'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/host-services.sh" "ansible_require_host_service_env \"\$node_role\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/etcdctl.yml" 'api.github.com/repos/k3s-io/k3s/releases/tags'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/etcdctl.yml" 'home_ops_embedded_etcd_version'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/etcdctl.yml" 'home_ops_etcdctl_version_effective'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/k3s-agent.service.j2" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/k3s-server.service.j2" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/main.yml" 'firstboot.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/firstboot.yml" '/usr/local/sbin/home-ops-firstboot'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/firstboot.yml" '/var/lib/home-ops/firstboot-complete'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/main.yml" 'package-space.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/package-space.yml" 'df -B1 --output=size,avail /'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/package-space.yml" 'df -B1 --output=avail /var/cache/apt'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/package-space.yml" 'home_ops_min_rootfs_size_bytes'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/package-space.yml" 'firstboot root filesystem growth did not run'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/main.yml" 'boot-cmdline.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/main.yml" '../node-prep/raspberry-pi.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/main.yml" 'home_ops_raspberry_pi | default(false) | bool'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'conntrack'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'cryptsetup'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'dnsutils'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'dmsetup'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'ethtool'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'htop'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'kmod'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'lsof'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'nano'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'nvme-cli'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'smartmontools'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'strace'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'tcpdump'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'home_ops_kernel_modules'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'home_ops_optional_kernel_modules'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'dm_crypt'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/kernel.yml" 'home_ops_kernel_modules'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/kernel.yml" 'home_ops_optional_kernel_modules'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/playbooks/home-ops-prereqs.yml" '../home-ops/tasks/node-prep/kernel.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'pcie_port_pm=off'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/raspberry-pi-config.yml" 'ANSIBLE MANAGED BLOCK home-ops raspberry pi config'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/sysctl.yml" 'fs.inotify.max_user_watches'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/swap.yml" 'dphys-swapfile'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/cpu-governor.yml" 'home-ops-cpu-governor'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/cilium-values.yaml.j2" "cilium_iface != 'auto'"
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/network/cilium.yml" 'Install bootstrap Cilium when absent'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/network/cilium.yml" 'when: home_ops_cilium_daemonset.rc != 0'
  assert_file_not_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/network/cilium.yml" 'cilium upgrade'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/reset-server-db.yml" 'db-before-rejoin'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/node-control-plane.sh" '--join-ip ADDRESS'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/kube-proxy-disable.yml" 'disable-kube-proxy: true'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/control-plane-join.yml" 'tasks/k3s/kube-proxy-disable.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/control-plane-finalize.yml" 'tasks/k3s/kube-proxy-disable.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/playbooks/disable-kube-proxy.yml" '../home-ops/tasks/k3s/kube-proxy-disable.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/join-servers.yml" 'home_ops_kube_proxy_config.changed | default(false) | bool'
  assert_file_contains "$ROOT/hack/bootstrap/nodes/control-plane-join.sh" 'node_assert_kube_proxy_disable_dropin'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/host-services.sh" 'home-ops/host-services.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/rpi-reporter.yml" 'home_ops_rpi_reporter_update_existing'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/rpi-reporter.yml" 'fresh pinned clone'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/rpi-reporter.yml" 'no_log: true'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/nut-client.yml" 'nut-client'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/nut-client.yml" 'no_log: true'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/main.yml" 'github-actions-runner.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'actions/runners/registration-token'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'bin/installdependencies.sh'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'checksum: "sha256:{{ home_ops_github_runner_checksum }}"'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'home_ops_github_runner_registration_token.json.token'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" '- sudo'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" '- "{{ home_ops_github_runner_user }}"'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'home_ops_github_runner_sudoers_file'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'home_ops_github_runner_service_file'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'Uninstall the legacy runner service first'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'no_log: true'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/github-actions-runner.yml" 'home-ops-crictl.j2'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/home-ops-crictl.j2" 'unsupported home-ops-crictl command'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" 'HOME_OPS_GITHUB_APP_ID'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" 'HOME_OPS_GITHUB_APP_INSTALLATION_ID'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" 'HOME_OPS_GITHUB_APP_PRIVATE_KEY'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" "op item get \"\$BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_ITEM\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" 'ansible_github_app_installation_access_token'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" 'permissions: {administration: "write"}'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" "mktemp \"\${TMPDIR:-/tmp}/home-ops-github-app-key.XXXXXX\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" 'openssl base64 -d -A'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" 'HOME_OPS_GITHUB_APP_PRIVATE_KEY is not valid base64-encoded PEM private key data'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/lib/host-services.sh" 'could not create GitHub App JWT for host services'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'home_ops_github_runner_access_token'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/inventory/live/group_vars/all.yml" 'home_ops_github_runner_enabled: true'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/site.yml" 'tasks/host-services/main.yml'
  assert_file_not_contains "$ROOT/hack/bootstrap/ansible/home-ops/control-plane-join.yml" 'tasks/host-services/main.yml'
  assert_file_not_contains "$ROOT/hack/bootstrap/ansible/home-ops/worker-join.yml" 'tasks/host-services/main.yml'
}

@test "host service secret helper loads missing values from 1Password fields" {
  local fake_op
  fake_op="${tmp}/op"
cat > "$fake_op" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == whoami ]]; then
  exit 0
fi
[[ "$1" == item && "$2" == get && "$3" == host-services ]] || exit 2
cat <<'JSON'
{
  "fields": [
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME", "label": "HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME", "value": "mqtt.example.invalid"},
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_USERNAME", "label": "HOME_OPS_RPI_REPORTER_MQTT_USERNAME", "value": "reporter-user"},
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_PASSWORD", "label": "HOME_OPS_RPI_REPORTER_MQTT_PASSWORD", "value": "reporter-secret"},
    {"id": "HOME_OPS_NUT_MONITOR_SYSTEM", "label": "HOME_OPS_NUT_MONITOR_SYSTEM", "value": "ups@example.invalid"},
    {"id": "HOME_OPS_NUT_MONITOR_USER", "label": "HOME_OPS_NUT_MONITOR_USER", "value": "nut-user"},
    {"id": "HOME_OPS_NUT_MONITOR_PASSWORD", "label": "HOME_OPS_NUT_MONITOR_PASSWORD", "value": "nut-secret"}
  ]
}
JSON
EOF
  chmod +x "$fake_op"

  run env PATH="${tmp}:/usr/bin:/bin" \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_require_host_service_env master; printf '%s:%s\n' \"\$HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME\" \"\$HOME_OPS_NUT_MONITOR_SYSTEM\""
  assert_success
  [[ "$output" == "mqtt.example.invalid:ups@example.invalid" ]]
  assert_output_not_contains 'reporter-secret'
  assert_output_not_contains 'nut-secret'
}

@test "host service secret helper reads host-services item once for node fields" {
  local fake_op calls
  fake_op="${tmp}/op"
  calls="${tmp}/op-calls"
  cat > "$fake_op" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >>"$OP_CALLS"
if [[ "$1" == whoami ]]; then
  exit 0
fi
[[ "$1" == item && "$2" == get && "$3" == host-services ]] || exit 2
cat <<'JSON'
{
  "fields": [
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME", "label": "HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME", "value": "mqtt.example.invalid"},
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_USERNAME", "label": "HOME_OPS_RPI_REPORTER_MQTT_USERNAME", "value": "reporter-user"},
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_PASSWORD", "label": "HOME_OPS_RPI_REPORTER_MQTT_PASSWORD", "value": "reporter-secret"},
    {"id": "HOME_OPS_GITHUB_APP_ID", "label": "HOME_OPS_GITHUB_APP_ID", "value": "12345"},
    {"id": "HOME_OPS_GITHUB_APP_INSTALLATION_ID", "label": "HOME_OPS_GITHUB_APP_INSTALLATION_ID", "value": "987"},
    {"id": "HOME_OPS_GITHUB_APP_PRIVATE_KEY", "label": "HOME_OPS_GITHUB_APP_PRIVATE_KEY", "value": "private-key"}
  ]
}
JSON
EOF
  chmod +x "$fake_op"

  run env PATH="${tmp}:/usr/bin:/bin" OP_CALLS="$calls" HOME_OPS_GITHUB_RUNNER_ACCESS_TOKEN="already-minted" \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_require_host_service_env node; ansible_require_host_service_env node; printf '%s:%s\n' \"\$HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME\" \"\$HOME_OPS_GITHUB_APP_INSTALLATION_ID\""

  assert_success
  [[ "$output" == "mqtt.example.invalid:987" ]]
  [[ "$(grep -c '^item get host-services$' "$calls")" == "1" ]]
  assert_output_not_contains 'reporter-secret'
  assert_output_not_contains 'private-key'
}

@test "host service secret helper signs in once in the parent shell before reading fields" {
  local fake_op calls
  fake_op="${tmp}/op"
  calls="${tmp}/op-calls"
  cat > "$fake_op" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$OP_CALLS"
case "$1" in
  whoami)
    [[ "${OP_SESSION_FAKE:-}" == "1" ]]
    ;;
  signin)
    printf 'export OP_SESSION_FAKE=1\n'
    ;;
  item)
    [[ "${OP_SESSION_FAKE:-}" == "1" ]] || exit 1
    [[ "$2" == get && "$3" == host-services ]] || exit 2
    cat <<'JSON'
{
  "fields": [
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME", "label": "HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME", "value": "mqtt.example.invalid"},
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_USERNAME", "label": "HOME_OPS_RPI_REPORTER_MQTT_USERNAME", "value": "reporter-user"},
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_PASSWORD", "label": "HOME_OPS_RPI_REPORTER_MQTT_PASSWORD", "value": "reporter-secret"},
    {"id": "HOME_OPS_NUT_MONITOR_SYSTEM", "label": "HOME_OPS_NUT_MONITOR_SYSTEM", "value": "ups@example.invalid"},
    {"id": "HOME_OPS_NUT_MONITOR_USER", "label": "HOME_OPS_NUT_MONITOR_USER", "value": "nut-user"},
    {"id": "HOME_OPS_NUT_MONITOR_PASSWORD", "label": "HOME_OPS_NUT_MONITOR_PASSWORD", "value": "nut-secret"}
  ]
}
JSON
    ;;
  *)
    exit 2
    ;;
esac
EOF
  chmod +x "$fake_op"

  run env PATH="${tmp}:/usr/bin:/bin" OP_CALLS="$calls" BOOTSTRAP_ANSIBLE_OP_SIGNIN_TTY=/dev/null \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_require_host_service_env master; printf '%s:%s\n' \"\$HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME\" \"\$HOME_OPS_NUT_MONITOR_SYSTEM\""
  assert_success
  assert_output_contains 'mqtt.example.invalid:ups@example.invalid'
  [[ "$(grep -c '^signin$' "$calls")" == "1" ]]
  [[ "$(grep -c '^item$' "$calls")" == "1" ]]
  assert_output_not_contains 'reporter-secret'
  assert_output_not_contains 'nut-secret'
}

@test "host service secret helper mints GitHub App token for worker runner registration" {
  command -v openssl >/dev/null 2>&1 || skip "openssl not installed"

  local fake_op fake_curl curl_args private_key
  fake_op="${tmp}/op"
  fake_curl="${tmp}/curl"
  curl_args="${tmp}/curl-args"
  private_key="$(openssl genrsa 2048 2>/dev/null | openssl base64 -A)"
cat > "$fake_op" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == whoami ]]; then
  exit 0
fi
[[ "$1" == item && "$2" == get && "$3" == host-services ]] || exit 2
cat <<JSON
{
  "fields": [
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME", "label": "HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME", "value": "mqtt.example.invalid"},
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_USERNAME", "label": "HOME_OPS_RPI_REPORTER_MQTT_USERNAME", "value": "reporter-user"},
    {"id": "HOME_OPS_RPI_REPORTER_MQTT_PASSWORD", "label": "HOME_OPS_RPI_REPORTER_MQTT_PASSWORD", "value": "reporter-secret"},
    {"id": "HOME_OPS_GITHUB_APP_ID", "label": "HOME_OPS_GITHUB_APP_ID", "value": "12345"},
    {"id": "HOME_OPS_GITHUB_APP_INSTALLATION_ID", "label": "HOME_OPS_GITHUB_APP_INSTALLATION_ID", "value": "987"},
    {"id": "HOME_OPS_GITHUB_APP_PRIVATE_KEY", "label": "HOME_OPS_GITHUB_APP_PRIVATE_KEY", "value": "${TEST_GITHUB_APP_PRIVATE_KEY}"}
  ]
}
JSON
EOF
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS"
printf '{"token":"installation-token","expires_at":"2026-05-14T05:00:00Z"}\n201'
EOF
  chmod +x "$fake_op" "$fake_curl"

  run env PATH="${tmp}:${PATH}" CURL_ARGS="$curl_args" TEST_GITHUB_APP_PRIVATE_KEY="$private_key" \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_require_host_service_env node; printf '%s:%s\n' \"\$HOME_OPS_GITHUB_RUNNER_ACCESS_TOKEN\" \"\$HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME\""
  assert_success
  assert_output_contains 'installation-token:mqtt.example.invalid'
  assert_output_not_contains 'reporter-secret'
  assert_file_contains "$curl_args" '/app/installations/987/access_tokens'
  assert_file_contains "$curl_args" 'Authorization: Bearer '
  assert_file_contains "$curl_args" '"repositories":["home-ops"]'
  assert_file_contains "$curl_args" '"administration":"write"'
}

@test "host service secret helper fails before playbooks when values are missing" {
  run env PATH="/usr/bin:/bin" \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_require_host_service_env node"
  assert_failure
  assert_output_contains 'missing host service secret environment values for node'
  assert_output_contains 'HOME_OPS_RPI_REPORTER_MQTT_PASSWORD'
  assert_output_contains 'HOME_OPS_GITHUB_APP_ID'
  assert_output_contains 'HOME_OPS_GITHUB_APP_INSTALLATION_ID'
  assert_output_contains 'HOME_OPS_GITHUB_APP_PRIVATE_KEY'
  assert_output_contains 'op://Kubernetes/host-services'
}

@test "render inventory fails on derived value conflicts" {
  local conflict_source
  conflict_source="${tmp}/conflict-source"
  mkdir -p "${conflict_source}/group_vars"
  cp "${ROOT}/hack/bootstrap/ansible/inventory/live/hosts.yml" "${conflict_source}/hosts.yml"
  cat > "${conflict_source}/group_vars/all.yml" <<'EOF'
---
ansible_user: ethan
apiserver_endpoint: 1.2.3.4
EOF

  run env K3S_ANSIBLE_DIR="$k3s_ansible" \
    BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible \
    BOOTSTRAP_ANSIBLE_OUT_DIR="${tmp}/conflict-out" \
    "${ROOT}/hack/bootstrap/ansible/render-inventory.sh" \
      --profile live \
      --inventory-source "$conflict_source"
  assert_failure
}

@test "1Password token helper functions build and update expected item JSON" {
  local token_ref expanded_key new_item updated_item
  token_ref="$(
    BOOTSTRAP_ANSIBLE_OP_VAULT=Vault \
    BOOTSTRAP_ANSIBLE_OP_ITEM=Item \
    BOOTSTRAP_ANSIBLE_OP_FIELD=Field \
      bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_token_ref"
  )"
  [[ "$token_ref" == "op://Vault/Item/Field" ]]

  expanded_key="$(
    HOME=/tmp/home \
      bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_expand_path '~/ansiblekey'"
  )"
  [[ "$expanded_key" == "/tmp/home/ansiblekey" ]]

  new_item="$(
    BOOTSTRAP_ANSIBLE_OP_ITEM=Item \
    BOOTSTRAP_ANSIBLE_OP_FIELD=k3s_token \
      bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_new_token_item_json test-token"
  )"
  [[ "$(jq -r '.title' <<<"$new_item")" == "Item" ]]
  [[ "$(jq -r '.category' <<<"$new_item")" == "SECURE_NOTE" ]]
  [[ "$(jq -r '.fields[] | select(.id == "k3s_token") | .type' <<<"$new_item")" == "CONCEALED" ]]
  [[ "$(jq -r '.fields[] | select(.id == "k3s_token") | .value' <<<"$new_item")" == "test-token" ]]

  updated_item="$(
    BOOTSTRAP_ANSIBLE_OP_FIELD=k3s_token \
      bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_update_token_item_json new-token" <<'EOF'
{"title":"Item","category":"PASSWORD","fields":[{"id":"password","label":"password","type":"CONCEALED","value":"existing-password"},{"id":"k3s_token","label":"k3s_token","type":"CONCEALED","value":"old-token"}]}
EOF
  )"
  [[ "$(jq -r '.category' <<<"$updated_item")" == "PASSWORD" ]]
  [[ "$(jq -r '.fields[] | select(.id == "password") | .value' <<<"$updated_item")" == "existing-password" ]]
  [[ "$(jq -r '.fields[] | select(.id == "k3s_token") | .value' <<<"$updated_item")" == "new-token" ]]
}
