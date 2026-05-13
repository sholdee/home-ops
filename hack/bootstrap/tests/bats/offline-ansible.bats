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
    "${ROOT}/hack/bootstrap/ansible/home-ops/control-plane-join.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/control-plane-finalize.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/worker-join.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/worker-finalize.yml"; do
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
  assert_file_contains "$ROOT/hack/bootstrap/ansible/run.sh" 'ansible_disable_kube_proxy_after_cilium'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/etcdctl.yml" 'api.github.com/repos/k3s-io/k3s/releases/tags'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/etcdctl.yml" 'home_ops_embedded_etcd_version'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/etcdctl.yml" 'home_ops_etcdctl_version_effective'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/k3s-agent.service.j2" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/templates/k3s-server.service.j2" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/vars/defaults.yml" 'home_ops_node_taints'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/home-ops/tasks/reset-server-db.yml" 'db-before-rejoin'
  assert_file_contains "$ROOT/hack/bootstrap/ansible/node-control-plane.sh" '--join-ip ADDRESS'
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
