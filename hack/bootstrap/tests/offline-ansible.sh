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

out="${tmp}/out"
K3S_ANSIBLE_DIR="$k3s_ansible" \
BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible \
BOOTSTRAP_ANSIBLE_OUT_DIR="$out" \
  "${ROOT}/hack/bootstrap/ansible/render-inventory.sh" --profile live >/dev/null

vars="${out}/inventory/live/group_vars/all.yml"
expected_key="$(printf '\176/%s' ansiblekey)"
test "$(yq -r '.ansible_user' "$vars")" = "ethan"
test "$(yq -r '.ansible_ssh_private_key_file' "$vars")" = "$expected_key"
test "$(yq -r '.k3s_version' "$vars")" = "v1.35.4+k3s1"
test "$(yq -r '.cilium_tag' "$vars")" = "$cilium_tag"
test "$(yq -r '.cluster_cidr' "$vars")" = "10.52.0.0/16"
test "$(yq -r '.kube_proxy_replacement' "$vars")" = "true"
test "$(yq -r '.apiserver_endpoint' "$vars")" = "192.168.99.77"
test "$(yq -r '.k3s_token' "$vars")" = "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}"
if grep -q 'sample-token' "$vars"; then
  echo "generated vars contain sample token" >&2
  exit 1
fi
if yq -r '.extra_server_args' "$vars" | grep -q -- '--disable-kube-proxy'; then
  echo "initial server args disable kube-proxy before Cilium is ready" >&2
  exit 1
fi
if ! grep -q 'ansible_disable_kube_proxy_after_cilium' "${ROOT}/hack/bootstrap/ansible/run.sh"; then
  echo "run.sh does not call the post-Cilium kube-proxy convergence playbook" >&2
  exit 1
fi
grep -q 'api.github.com/repos/k3s-io/k3s/releases/tags' "${ROOT}/hack/bootstrap/ansible/home-ops/tasks/etcdctl.yml"
grep -q 'home_ops_embedded_etcd_version' "${ROOT}/hack/bootstrap/ansible/home-ops/tasks/etcdctl.yml"
grep -q 'home_ops_etcdctl_version_effective' "${ROOT}/hack/bootstrap/ansible/home-ops/tasks/etcdctl.yml"

home_ops_out="${tmp}/home-ops-out"
BOOTSTRAP_ANSIBLE_OUT_DIR="$home_ops_out" \
  "${ROOT}/hack/bootstrap/ansible/render-inventory.sh" --profile live >/dev/null

home_ops_vars="${home_ops_out}/inventory/live/group_vars/all.yml"
test "$(yq -r '.ansible_user' "$home_ops_vars")" = "ethan"
test "$(yq -r '.k3s_version' "$home_ops_vars")" = "v1.35.4+k3s1"
test "$(yq -r '.cilium_tag' "$home_ops_vars")" = "$cilium_tag"
test "$(yq -r '.cluster_cidr' "$home_ops_vars")" = "10.52.0.0/16"
test "$(yq -r '.k3s_token' "$home_ops_vars")" = "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}"
test "$(yq -r '.home_ops_etcdctl_version_override' "$home_ops_vars")" = ""
if grep -q 'sample-token' "$home_ops_vars"; then
  echo "home-ops backend vars contain sample token" >&2
  exit 1
fi

home_ops_raw_kubeconfig="$(
  BOOTSTRAP_ANSIBLE_OUT_DIR="$home_ops_out" \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_raw_kubeconfig_file live"
)"
test "$home_ops_raw_kubeconfig" = "${home_ops_out}/kubeconfig-raw-live"

default_lima_inventory="$(
  bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_set_profile lima; ansible_inventory_dir"
)"
test "$default_lima_inventory" = "${ROOT}/hack/bootstrap/.out/ansible-lima/inventory/lima"

default_backend="$(
  bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; printf '%s\n' \"\$BOOTSTRAP_ANSIBLE_BACKEND\""
)"
test "$default_backend" = "home-ops"

if command -v ansible-playbook >/dev/null 2>&1; then
  for playbook in \
    "${ROOT}/hack/bootstrap/ansible/home-ops/site.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/control-plane-join.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/control-plane-finalize.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/worker-join.yml" \
    "${ROOT}/hack/bootstrap/ansible/home-ops/worker-finalize.yml"; do
    ansible-playbook --syntax-check \
      -i "${home_ops_out}/inventory/live/hosts.yml" \
      "$playbook" >/dev/null
  done

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
  ansible-playbook -i localhost, "$render_playbook" >/dev/null
  grep -q -- '--node-taint node.home-ops.sh/joining=true:NoSchedule' "$rendered_service"
  grep -q '^KillMode=process$' "$rendered_service"
  if grep -q -- 'NoScheduleKillMode' "$rendered_service"; then
    echo "rendered K3s agent service joined taint args to the next unit key" >&2
    exit 1
  fi

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
  ansible-playbook -i localhost, "$render_server_playbook" >/dev/null
  grep -q -- '--node-taint node.home-ops.sh/joining=true:NoSchedule' "$rendered_server_service"
  grep -q '^KillMode=process$' "$rendered_server_service"
  if grep -q -- 'NoScheduleKillMode' "$rendered_server_service"; then
    echo "rendered K3s server service joined taint args to the next unit key" >&2
    exit 1
  fi
fi

grep -q 'home_ops_node_taints' "${ROOT}/hack/bootstrap/ansible/home-ops/templates/k3s-agent.service.j2"
grep -q 'home_ops_node_taints' "${ROOT}/hack/bootstrap/ansible/home-ops/templates/k3s-server.service.j2"
grep -q 'home_ops_node_taints' "${ROOT}/hack/bootstrap/ansible/home-ops/vars/defaults.yml"
grep -q 'db-before-rejoin' "${ROOT}/hack/bootstrap/ansible/home-ops/tasks/reset-server-db.yml"
grep -q -- '--join-ip ADDRESS' "${ROOT}/hack/bootstrap/ansible/node-control-plane.sh"

conflict_source="${tmp}/conflict-source"
mkdir -p "${conflict_source}/group_vars"
cp "${ROOT}/hack/bootstrap/ansible/inventory/live/hosts.yml" "${conflict_source}/hosts.yml"
cat > "${conflict_source}/group_vars/all.yml" <<'EOF'
---
ansible_user: ethan
apiserver_endpoint: 1.2.3.4
EOF

if K3S_ANSIBLE_DIR="$k3s_ansible" \
  BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible \
  BOOTSTRAP_ANSIBLE_OUT_DIR="${tmp}/conflict-out" \
  "${ROOT}/hack/bootstrap/ansible/render-inventory.sh" \
    --profile live \
    --inventory-source "$conflict_source" >/dev/null 2>&1; then
  echo "expected derived value conflict" >&2
  exit 1
fi

token_ref="$(
  BOOTSTRAP_ANSIBLE_OP_VAULT=Vault \
  BOOTSTRAP_ANSIBLE_OP_ITEM=Item \
  BOOTSTRAP_ANSIBLE_OP_FIELD=Field \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_token_ref"
)"
test "$token_ref" = "op://Vault/Item/Field"

expanded_key="$(
  HOME=/tmp/home \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_expand_path '~/ansiblekey'"
)"
test "$expanded_key" = "/tmp/home/ansiblekey"

new_item="$(
  BOOTSTRAP_ANSIBLE_OP_ITEM=Item \
  BOOTSTRAP_ANSIBLE_OP_FIELD=k3s_token \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_new_token_item_json test-token"
)"
test "$(jq -r '.title' <<<"$new_item")" = "Item"
test "$(jq -r '.category' <<<"$new_item")" = "SECURE_NOTE"
test "$(jq -r '.fields[] | select(.id == "k3s_token") | .type' <<<"$new_item")" = "CONCEALED"
test "$(jq -r '.fields[] | select(.id == "k3s_token") | .value' <<<"$new_item")" = "test-token"

updated_item="$(
  BOOTSTRAP_ANSIBLE_OP_FIELD=k3s_token \
    bash -c "source '${ROOT}/hack/bootstrap/ansible/lib.sh'; ansible_update_token_item_json new-token" <<'EOF'
{"title":"Item","category":"PASSWORD","fields":[{"id":"password","label":"password","type":"CONCEALED","value":"existing-password"},{"id":"k3s_token","label":"k3s_token","type":"CONCEALED","value":"old-token"}]}
EOF
)"
test "$(jq -r '.category' <<<"$updated_item")" = "PASSWORD"
test "$(jq -r '.fields[] | select(.id == "password") | .value' <<<"$updated_item")" = "existing-password"
test "$(jq -r '.fields[] | select(.id == "k3s_token") | .value' <<<"$updated_item")" = "new-token"

echo "offline ansible test passed"
