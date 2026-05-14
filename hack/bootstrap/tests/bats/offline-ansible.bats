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
  cilium_tag="$(
    yq -r '
      select(.kind == "Application" and .metadata.name == "cilium") |
      "v" + (.spec.source.targetRevision | sub("^v"; ""))
    ' "${ROOT}/apps/argocd/manifests/apps.yaml"
  )"

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

@test "k3s-ansible backend render derives home-ops live vars without preserving sample token" {
  render_k3s_ansible_inventory

  local expected_key
  expected_key="$(printf '\176/%s' ansiblekey)"
  [[ "$(yq -r '.ansible_user' "$vars")" == "ethan" ]]
  [[ "$(yq -r '.ansible_ssh_private_key_file' "$vars")" == "$expected_key" ]]
  [[ "$(yq -r '.k3s_version' "$vars")" == "v1.35.4+k3s1" ]]
  [[ "$(yq -r '.cilium_tag' "$vars")" == "$cilium_tag" ]]
  [[ "$(yq -r '.cluster_cidr' "$vars")" == "10.52.0.0/16" ]]
  [[ "$(yq -r '.kube_proxy_replacement' "$vars")" == "true" ]]
  [[ "$(yq -r '.apiserver_endpoint' "$vars")" == "192.168.99.77" ]]
  [[ "$(yq -r '.k3s_token' "$vars")" == "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}" ]]
  assert_file_not_contains "$vars" 'sample-token'
  run bash -c "yq -r '.extra_server_args' '$vars' | grep -q -- '--disable-kube-proxy'"
  assert_failure
}

@test "home-ops backend render derives live vars and default helper paths" {
  render_home_ops_inventory

  [[ "$(yq -r '.ansible_user' "$home_ops_vars")" == "ethan" ]]
  [[ "$(yq -r '.k3s_version' "$home_ops_vars")" == "v1.35.4+k3s1" ]]
  [[ "$(yq -r '.cilium_tag' "$home_ops_vars")" == "$cilium_tag" ]]
  [[ "$(yq -r '.cluster_cidr' "$home_ops_vars")" == "10.52.0.0/16" ]]
  [[ "$(yq -r '.k3s_token' "$home_ops_vars")" == "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}" ]]
  [[ "$(yq -r '.home_ops_etcdctl_version_override' "$home_ops_vars")" == "" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_enabled' "$home_ops_vars")" == "true" ]]
  [[ "$(yq -r '.home_ops_nut_client_enabled' "$home_ops_vars")" == "true" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_update_existing' "$home_ops_vars")" == "false" ]]
  [[ "$(yq -r '.home_ops_rpi_reporter_restart_on_change' "$home_ops_vars")" == "false" ]]
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
  assert_file_contains "$ROOT/hack/bootstrap/ansible/node-worker.sh" 'ansible_require_host_service_env node'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/node-control-plane.sh" 'ansible_require_host_service_env master'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/host-services.sh" "ansible_require_host_service_env \"\$node_role\""
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/etcdctl.yml" 'api.github.com/repos/k3s-io/k3s/releases/tags'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/etcdctl.yml" 'home_ops_embedded_etcd_version'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/etcdctl.yml" 'home_ops_etcdctl_version_effective'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/k3s-agent.service.j2" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/k3s-server.service.j2" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/main.yml" 'boot-cmdline.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'pcie_port_pm=off'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/raspberry-pi-config.yml" 'ANSIBLE MANAGED BLOCK home-ops raspberry pi config'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/sysctl.yml" 'fs.inotify.max_user_watches'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/swap.yml" 'dphys-swapfile'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/node-prep/cpu-governor.yml" 'home-ops-cpu-governor'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/cilium-values.yaml.j2" "cilium_iface != 'auto'"
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/reset-server-db.yml" 'db-before-rejoin'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/node-control-plane.sh" '--join-ip ADDRESS'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/kube-proxy-disable.yml" 'disable-kube-proxy: true'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/control-plane-join.yml" 'tasks/k3s/kube-proxy-disable.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/control-plane-finalize.yml" 'tasks/k3s/kube-proxy-disable.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/playbooks/disable-kube-proxy.yml" '../home-ops/tasks/k3s/kube-proxy-disable.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/k3s/join-servers.yml" 'home_ops_kube_proxy_config.changed'
  assert_file_contains "$ROOT/hack/bootstrap/nodes/control-plane-join.sh" 'node_assert_kube_proxy_disable_dropin'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/host-services.sh" 'home-ops/host-services.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/rpi-reporter.yml" 'home_ops_rpi_reporter_update_existing'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/rpi-reporter.yml" 'fresh pinned clone'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/rpi-reporter.yml" 'no_log: true'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/nut-client.yml" 'nut-client'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/host-services/nut-client.yml" 'no_log: true'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/control-plane-join.yml" 'tasks/host-services/main.yml'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/worker-join.yml" 'tasks/host-services/main.yml'
}

@test "host service secret helper loads missing values from 1Password fields" {
  local fake_op
  fake_op="${tmp}/op"
  cat > "$fake_op" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == whoami ]]; then
  exit 0
fi
[[ "$1" == read && "$2" == -n ]] || exit 2
case "$3" in
  op://Kubernetes/host-services/HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME)
    printf 'mqtt.example.invalid'
    ;;
  op://Kubernetes/host-services/HOME_OPS_RPI_REPORTER_MQTT_USERNAME)
    printf 'reporter-user'
    ;;
  op://Kubernetes/host-services/HOME_OPS_RPI_REPORTER_MQTT_PASSWORD)
    printf 'reporter-secret'
    ;;
  op://Kubernetes/host-services/HOME_OPS_NUT_MONITOR_SYSTEM)
    printf 'ups@example.invalid'
    ;;
  op://Kubernetes/host-services/HOME_OPS_NUT_MONITOR_USER)
    printf 'nut-user'
    ;;
  op://Kubernetes/host-services/HOME_OPS_NUT_MONITOR_PASSWORD)
    printf 'nut-secret'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fake_op"

  run env PATH="${tmp}:/usr/bin:/bin" \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_require_host_service_env master; printf '%s:%s\n' \"\$HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME\" \"\$HOME_OPS_NUT_MONITOR_SYSTEM\""
  assert_success
  [[ "$output" == "mqtt.example.invalid:ups@example.invalid" ]]
  assert_output_not_contains 'reporter-secret'
  assert_output_not_contains 'nut-secret'
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
  read)
    [[ "${OP_SESSION_FAKE:-}" == "1" ]] || exit 1
    [[ "$2" == -n ]] || exit 2
    case "$3" in
      op://Kubernetes/host-services/HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME)
        printf 'mqtt.example.invalid'
        ;;
      op://Kubernetes/host-services/HOME_OPS_RPI_REPORTER_MQTT_USERNAME)
        printf 'reporter-user'
        ;;
      op://Kubernetes/host-services/HOME_OPS_RPI_REPORTER_MQTT_PASSWORD)
        printf 'reporter-secret'
        ;;
      op://Kubernetes/host-services/HOME_OPS_NUT_MONITOR_SYSTEM)
        printf 'ups@example.invalid'
        ;;
      op://Kubernetes/host-services/HOME_OPS_NUT_MONITOR_USER)
        printf 'nut-user'
        ;;
      op://Kubernetes/host-services/HOME_OPS_NUT_MONITOR_PASSWORD)
        printf 'nut-secret'
        ;;
      *)
        exit 1
        ;;
    esac
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
  assert_output_not_contains 'reporter-secret'
  assert_output_not_contains 'nut-secret'
}

@test "host service secret helper fails before playbooks when values are missing" {
  run env PATH="/usr/bin:/bin" \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_require_host_service_env node"
  assert_failure
  assert_output_contains 'missing host service secret environment values for node'
  assert_output_contains 'HOME_OPS_RPI_REPORTER_MQTT_PASSWORD'
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
