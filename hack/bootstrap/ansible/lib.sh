#!/usr/bin/env bash

ANSIBLE_BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${ANSIBLE_BOOTSTRAP_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BOOTSTRAP_DIR}/../.." && pwd)"

K3S_ANSIBLE_DIR="${K3S_ANSIBLE_DIR:-${REPO_ROOT}/../k3s-ansible}"
BOOTSTRAP_ANSIBLE_PROFILE="${BOOTSTRAP_ANSIBLE_PROFILE:-live}"
BOOTSTRAP_ANSIBLE_OUT_DIR="${BOOTSTRAP_ANSIBLE_OUT_DIR:-${BOOTSTRAP_DIR}/.out/ansible-${BOOTSTRAP_ANSIBLE_PROFILE}}"
BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR="${BOOTSTRAP_ANSIBLE_LIVE_INVENTORY_DIR:-${ANSIBLE_BOOTSTRAP_DIR}/inventory/live}"
BOOTSTRAP_ANSIBLE_OP_VAULT="${BOOTSTRAP_ANSIBLE_OP_VAULT:-Kubernetes}"
BOOTSTRAP_ANSIBLE_OP_ITEM="${BOOTSTRAP_ANSIBLE_OP_ITEM:-k3s-bootstrap}"
BOOTSTRAP_ANSIBLE_OP_FIELD="${BOOTSTRAP_ANSIBLE_OP_FIELD:-k3s_token}"
BOOTSTRAP_ANSIBLE_KUBECONTEXT="${BOOTSTRAP_ANSIBLE_KUBECONTEXT:-default}"
BOOTSTRAP_ANSIBLE_USER_KUBECONFIG="${BOOTSTRAP_ANSIBLE_USER_KUBECONFIG:-${HOME}/.kube/config}"

ansible_log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

ansible_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

ansible_require_tool() {
  command -v "$1" >/dev/null 2>&1 || ansible_die "required tool not found: $1"
}

ansible_bool() {
  [[ "${1:-}" == true ]]
}

ansible_inventory_dir() {
  local profile="${1:-$BOOTSTRAP_ANSIBLE_PROFILE}"
  printf '%s/inventory/%s\n' "$BOOTSTRAP_ANSIBLE_OUT_DIR" "$profile"
}

ansible_inventory_file() {
  local profile="${1:-$BOOTSTRAP_ANSIBLE_PROFILE}"
  printf '%s/hosts.yml\n' "$(ansible_inventory_dir "$profile")"
}

ansible_generated_vars_file() {
  local profile="${1:-$BOOTSTRAP_ANSIBLE_PROFILE}"
  printf '%s/group_vars/all.yml\n' "$(ansible_inventory_dir "$profile")"
}

ansible_kubeconfig_file() {
  local profile="${1:-$BOOTSTRAP_ANSIBLE_PROFILE}"
  printf '%s/kubeconfig-%s\n' "$BOOTSTRAP_ANSIBLE_OUT_DIR" "$profile"
}

ansible_token_ref() {
  printf 'op://%s/%s/%s\n' \
    "$BOOTSTRAP_ANSIBLE_OP_VAULT" \
    "$BOOTSTRAP_ANSIBLE_OP_ITEM" \
    "$BOOTSTRAP_ANSIBLE_OP_FIELD"
}

ansible_home_ops_cilium_tag() {
  local version
  version="$(
    yq -r '
      select(.kind == "Application" and .metadata.name == "cilium") |
      .spec.source.targetRevision
    ' "${REPO_ROOT}/apps/argocd/manifests/apps.yaml"
  )"
  [[ -n "$version" && "$version" != "null" ]] || ansible_die "could not derive Cilium targetRevision from home-ops"
  printf 'v%s\n' "${version#v}"
}

ansible_write_derived_vars() {
  local output="$1"
  local cilium_app="${REPO_ROOT}/apps/argocd/manifests/apps.yaml"
  local bgp_file="${REPO_ROOT}/apps/kube-system/cilium/manifests/CiliumBGPClusterConfig.yaml"
  local kube_vip_file="${REPO_ROOT}/apps/kube-system/kube-vip/manifests/daemonset.yaml"
  local upgrade_plan="${REPO_ROOT}/apps/system-upgrade/manifests/plan.yaml"

  local k3s_version cilium_tag cluster_cidr cilium_mode cilium_datapath_mode
  local cilium_hubble cilium_bgp kube_proxy_replacement enable_bpf_masquerade
  local bpf_lb_algorithm bpf_lb_mode local_asn peer_asn peer_address lb_cidr
  local kube_vip_image kube_vip_tag apiserver_endpoint

  k3s_version="$(yq -r 'select(.kind == "Plan" and .metadata.name == "k3s-server") | .spec.version' "$upgrade_plan")"
  cilium_tag="$(ansible_home_ops_cilium_tag)"
  cluster_cidr="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.ipam.operator.clusterPoolIPv4PodCIDRList' "$cilium_app")"
  cilium_mode="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.routingMode' "$cilium_app")"
  cilium_datapath_mode="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.bpf.datapathMode' "$cilium_app")"
  cilium_hubble="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.hubble.enabled' "$cilium_app")"
  cilium_bgp="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.bgpControlPlane.enabled' "$cilium_app")"
  kube_proxy_replacement="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.kubeProxyReplacement' "$cilium_app")"
  enable_bpf_masquerade="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.bpf.masquerade' "$cilium_app")"
  bpf_lb_algorithm="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.loadBalancer.algorithm' "$cilium_app")"
  bpf_lb_mode="$(yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.helm.valuesObject.loadBalancer.mode' "$cilium_app")"

  local_asn="$(yq -r 'select(.kind == "CiliumBGPClusterConfig") | .spec.bgpInstances[0].localASN' "$bgp_file")"
  peer_asn="$(yq -r 'select(.kind == "CiliumBGPClusterConfig") | .spec.bgpInstances[0].peers[0].peerASN' "$bgp_file")"
  peer_address="$(yq -r 'select(.kind == "CiliumBGPClusterConfig") | .spec.bgpInstances[0].peers[0].peerAddress' "$bgp_file")"
  lb_cidr="$(yq -r 'select(.kind == "CiliumLoadBalancerIPPool") | .spec.blocks[0].cidr' "$bgp_file")"

  kube_vip_image="$(yq -r '.spec.template.spec.containers[] | select(.name == "kube-vip") | .image' "$kube_vip_file")"
  kube_vip_tag="$(sed -E 's/^.*:(v[^@]+).*$/\1/' <<<"$kube_vip_image")"
  apiserver_endpoint="$(yq -r '.spec.template.spec.containers[] | select(.name == "kube-vip") | .env[] | select(.name == "address") | .value' "$kube_vip_file")"

  for value_name in k3s_version cilium_tag cluster_cidr cilium_mode cilium_datapath_mode \
    cilium_hubble cilium_bgp kube_proxy_replacement enable_bpf_masquerade \
    bpf_lb_algorithm bpf_lb_mode local_asn peer_asn peer_address lb_cidr \
    kube_vip_tag apiserver_endpoint; do
    [[ -n "${!value_name}" && "${!value_name}" != "null" ]] ||
      ansible_die "could not derive ${value_name}"
  done

  cat > "$output" <<EOF
---
k3s_version: ${k3s_version}
cilium_tag: ${cilium_tag}
cluster_cidr: ${cluster_cidr}
cilium_mode: ${cilium_mode}
cilium_datapath_mode: ${cilium_datapath_mode}
cilium_hubble: ${cilium_hubble}
cilium_bgp: ${cilium_bgp}
cilium_bgp_apply_legacy_peering_policy: false
cilium_bgp_my_asn: "${local_asn}"
cilium_bgp_peer_asn: "${peer_asn}"
cilium_bgp_peer_address: ${peer_address}
cilium_bgp_lb_cidr: ${lb_cidr}
kube_proxy_replacement: ${kube_proxy_replacement}
enable_bpf_masquerade: ${enable_bpf_masquerade}
bpf_lb_algorithm: ${bpf_lb_algorithm}
bpf_lb_mode: ${bpf_lb_mode}
kube_vip_tag_version: ${kube_vip_tag}
apiserver_endpoint: ${apiserver_endpoint}
EOF
}

ansible_write_runtime_vars() {
  local output="$1"
  cat > "$output" <<'EOF'
---
k3s_token: "{{ lookup('ansible.builtin.env', 'K3S_TOKEN') }}"
EOF
}

ansible_live_derived_keys() {
  cat <<'EOF'
k3s_version
cilium_tag
cluster_cidr
cilium_mode
cilium_datapath_mode
cilium_hubble
cilium_bgp
cilium_bgp_apply_legacy_peering_policy
cilium_bgp_my_asn
cilium_bgp_peer_asn
cilium_bgp_peer_address
cilium_bgp_lb_cidr
kube_proxy_replacement
enable_bpf_masquerade
bpf_lb_algorithm
bpf_lb_mode
kube_vip_tag_version
apiserver_endpoint
EOF
}

ansible_check_live_derived_conflicts() {
  local overrides="$1"
  local derived="$2"
  local key override_value derived_value
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if yq -e "has(\"${key}\")" "$overrides" >/dev/null 2>&1; then
      override_value="$(yq -o=json ".${key}" "$overrides")"
      derived_value="$(yq -o=json ".${key}" "$derived")"
      [[ "$override_value" == "$derived_value" ]] ||
        ansible_die "live override conflicts with derived ${key}: ${override_value} != ${derived_value}"
    fi
  done < <(ansible_live_derived_keys)
}

ansible_render_inventory() {
  local profile="$1"
  local source_dir="$2"
  local output_dir="$3"
  local base_vars="${K3S_ANSIBLE_DIR}/inventory/sample/group_vars/all.yml"
  local source_hosts="${source_dir}/hosts.yml"
  local source_vars="${source_dir}/group_vars/all.yml"
  local derived="${output_dir}/group_vars/derived.yml"
  local runtime="${output_dir}/group_vars/runtime.yml"
  local output_vars="${output_dir}/group_vars/all.yml"

  [[ -f "$base_vars" ]] || ansible_die "missing k3s-ansible sample vars: ${base_vars}"
  [[ -f "$source_hosts" ]] || ansible_die "missing inventory hosts: ${source_hosts}"
  [[ -f "$source_vars" ]] || ansible_die "missing inventory group vars: ${source_vars}"

  mkdir -p "${output_dir}/group_vars"
  cp "$source_hosts" "${output_dir}/hosts.yml"
  ansible_write_derived_vars "$derived"

  case "$profile" in
    live)
      ansible_check_live_derived_conflicts "$source_vars" "$derived"
      ansible_write_runtime_vars "$runtime"
      # shellcheck disable=SC2016
      yq eval-all '. as $item ireduce ({}; . * $item)' \
        "$base_vars" "$source_vars" "$derived" "$runtime" > "$output_vars"
      ;;
    lima)
      # shellcheck disable=SC2016
      yq eval-all '. as $item ireduce ({}; . * $item)' \
        "$base_vars" "$derived" "$source_vars" > "$output_vars"
      ;;
    *)
      ansible_die "unknown Ansible bootstrap profile: ${profile}"
      ;;
  esac
}

ansible_first_master_name() {
  local inventory_file="$1"
  yq -r '.all.children.k3s_cluster.children.master.hosts | keys | .[0]' "$inventory_file"
}

ansible_first_master_host() {
  local inventory_file="$1"
  local host="$2"
  yq -r ".all.children.k3s_cluster.children.master.hosts.\"${host}\".ansible_host // \"${host}\"" "$inventory_file"
}

ansible_first_master_user() {
  local vars_file="$1"
  yq -r '.ansible_user // env(BOOTSTRAP_ANSIBLE_SSH_USER) // ""' "$vars_file"
}

ansible_expand_path() {
  local path="$1"
  case "$path" in
    \~)
      printf '%s\n' "$HOME"
      ;;
    \~/*)
      printf '%s/%s\n' "$HOME" "${path#"~/"}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

ansible_ssh_key_file() {
  local vars_file="$1"
  local key_file
  key_file="$(yq -r '.ansible_ssh_private_key_file // .ansible_private_key_file // ""' "$vars_file")"
  [[ -n "$key_file" && "$key_file" != "null" ]] || return 0
  ansible_expand_path "$key_file"
}

ansible_read_remote_token_if_exists() {
  local inventory_dir="$1"
  local inventory_file="${inventory_dir}/hosts.yml"
  local vars_file="${inventory_dir}/group_vars/all.yml"
  local first_master host address user key_file ssh_args

  first_master="$(ansible_first_master_name "$inventory_file")"
  [[ -n "$first_master" && "$first_master" != "null" ]] || ansible_die "inventory has no master hosts"
  address="$(ansible_first_master_host "$inventory_file" "$first_master")"
  user="$(ansible_first_master_user "$vars_file")"
  [[ -n "$user" && "$user" != "null" ]] || ansible_die "ansible_user is required for token checks"
  host="${user}@${address}"
  key_file="$(ansible_ssh_key_file "$vars_file")"
  ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  if [[ -n "$key_file" ]]; then
    ssh_args+=(-i "$key_file")
  fi

  ssh "${ssh_args[@]}" "$host" \
    'if sudo -n test -f /var/lib/rancher/k3s/server/token; then sudo -n cat /var/lib/rancher/k3s/server/token; fi'
}

ansible_read_token_from_op() {
  op read -n "$(ansible_token_ref)" 2>/dev/null
}

ansible_new_token_item_json() {
  local token="$1"
  jq -n \
    --arg title "$BOOTSTRAP_ANSIBLE_OP_ITEM" \
    --arg field "$BOOTSTRAP_ANSIBLE_OP_FIELD" \
    --arg token "$token" \
    '{
      title: $title,
      category: "SECURE_NOTE",
      fields: [
        {
          id: $field,
          label: $field,
          type: "CONCEALED",
          value: $token
        }
      ]
    }'
}

ansible_update_token_item_json() {
  local token="$1"
  jq \
    --arg field "$BOOTSTRAP_ANSIBLE_OP_FIELD" \
    --arg token "$token" \
    '
      def token_field: {
        id: $field,
        label: $field,
        type: "CONCEALED",
        value: $token
      };

      .fields = (
        (.fields // []) as $fields |
        if any($fields[]?; .id == $field or .label == $field) then
          [
            $fields[] |
            if .id == $field or .label == $field then
              . + {
                label: (.label // $field),
                type: "CONCEALED",
                value: $token
              }
            else
              .
            end
          ]
        else
          $fields + [token_field]
        end
      )
    '
}

ansible_write_token_to_op() {
  local token="$1"
  local item_json

  if op item get "$BOOTSTRAP_ANSIBLE_OP_ITEM" --vault "$BOOTSTRAP_ANSIBLE_OP_VAULT" >/dev/null 2>&1; then
    item_json="$(
      op item get "$BOOTSTRAP_ANSIBLE_OP_ITEM" \
        --vault "$BOOTSTRAP_ANSIBLE_OP_VAULT" \
        --format json |
        ansible_update_token_item_json "$token"
    )"
    printf '%s\n' "$item_json" |
      op item edit "$BOOTSTRAP_ANSIBLE_OP_ITEM" --vault "$BOOTSTRAP_ANSIBLE_OP_VAULT" >/dev/null
  else
    item_json="$(ansible_new_token_item_json "$token")"
    printf '%s\n' "$item_json" |
      op item create --vault "$BOOTSTRAP_ANSIBLE_OP_VAULT" - >/dev/null
  fi
}

ansible_generate_token() {
  openssl rand -hex 32
}

ansible_prepare_live_token() {
  local inventory_dir="$1"
  local op_token remote_token
  op_token="$(ansible_read_token_from_op || true)"
  remote_token="$(ansible_read_remote_token_if_exists "$inventory_dir")"

  if [[ -n "$op_token" && -n "$remote_token" && "$op_token" != "$remote_token" ]]; then
    ansible_die "1Password k3s token does not match existing first control-plane node token; run explicit token import if this cluster predates the wrapper"
  fi

  if [[ -n "$op_token" ]]; then
    printf '%s\n' "$op_token"
    return
  fi

  if [[ -n "$remote_token" ]]; then
    ansible_die "existing cluster token found but 1Password token is missing; run hack/bootstrap/ansible/import-token.sh explicitly"
  fi

  op_token="$(ansible_generate_token)"
  ansible_write_token_to_op "$op_token"
  ansible_log "generated and persisted new k3s token at $(ansible_token_ref)" >&2
  printf '%s\n' "$op_token"
}

ansible_print_summary() {
  local profile="$1"
  local inventory_dir="$2"
  local vars_file="${inventory_dir}/group_vars/all.yml"
  local inventory_file="${inventory_dir}/hosts.yml"

  ansible_log "Ansible bootstrap profile: ${profile}"
  ansible_log "k3s-ansible checkout: ${K3S_ANSIBLE_DIR}"
  ansible_log "inventory: ${inventory_file}"
  ansible_log "first control-plane host: $(ansible_first_master_name "$inventory_file")"
  ansible_log "hosts:"
  # shellcheck disable=SC2016
  yq -r '
    .all.children.k3s_cluster.children |
    to_entries[] |
    .key as $group |
    .value.hosts |
    keys[] |
    "  - " + $group + "/" + .
  ' "$inventory_file"
  ansible_log "derived core values:"
  # shellcheck disable=SC2016
  yq -r '
    {
      "k3s_version": .k3s_version,
      "cilium_tag": .cilium_tag,
      "cluster_cidr": .cluster_cidr,
      "cilium_mode": .cilium_mode,
      "cilium_datapath_mode": .cilium_datapath_mode,
      "cilium_bgp": .cilium_bgp,
      "kube_vip_tag_version": .kube_vip_tag_version,
      "apiserver_endpoint": .apiserver_endpoint
    } |
    to_entries[] |
    "  - " + .key + ": " + (.value | tostring)
  ' "$vars_file"
}

ansible_confirm_live_run() {
  local yes="$1"
  local inventory_dir="$2"
  local run_kube_bootstrap="$3"
  if ansible_bool "$yes"; then
    return
  fi

  ansible_print_summary live "$inventory_dir"
  ansible_log "will run Kubernetes bootstrap after Ansible: ${run_kube_bootstrap}"
  printf 'Type "bootstrap live cluster" to continue: ' >&2
  local answer
  read -r answer
  [[ "$answer" == "bootstrap live cluster" ]] || ansible_die "confirmation failed"
}

ansible_prepare_kubeconfig() {
  local profile="$1"
  local raw_kubeconfig="${K3S_ANSIBLE_DIR}/kubeconfig"
  local kubeconfig
  kubeconfig="$(ansible_kubeconfig_file "$profile")"
  [[ -f "$raw_kubeconfig" ]] || ansible_die "missing kubeconfig from k3s-ansible run: ${raw_kubeconfig}"
  mkdir -p "$(dirname "$kubeconfig")"
  cp "$raw_kubeconfig" "$kubeconfig"
  BOOTSTRAP_ANSIBLE_KUBECONTEXT="$BOOTSTRAP_ANSIBLE_KUBECONTEXT" yq -i '
    .clusters[0].name = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    .users[0].name = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    .contexts[0].name = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    .contexts[0].context.cluster = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    .contexts[0].context.user = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    ."current-context" = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT)
  ' "$kubeconfig"
  printf '%s\n' "$kubeconfig"
}

ansible_import_kubeconfig() {
  local profile="$1"
  local kubeconfig kubeconfig_env target tmp previous_context
  kubeconfig="$(ansible_prepare_kubeconfig "$profile")"
  kubeconfig_env="${KUBECONFIG:-$BOOTSTRAP_ANSIBLE_USER_KUBECONFIG}"
  target="${kubeconfig_env%%:*}"
  mkdir -p "$(dirname "$target")"
  touch "$target"
  chmod 0600 "$target" >/dev/null 2>&1 || true
  previous_context="$(kubectl --kubeconfig "$target" config current-context 2>/dev/null || true)"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  KUBECONFIG="${kubeconfig}:${kubeconfig_env}" kubectl config view --flatten > "$tmp"
  if [[ -n "$previous_context" ]]; then
    kubectl --kubeconfig "$tmp" config use-context "$previous_context" >/dev/null
  fi
  chmod 0600 "$tmp"
  mv "$tmp" "$target"
  ansible_log "imported kube context ${BOOTSTRAP_ANSIBLE_KUBECONTEXT} into ${target}"
}

ansible_install_collections() {
  ansible_log "installing k3s-ansible collections"
  ansible-galaxy collection install -r "${K3S_ANSIBLE_DIR}/collections/requirements.yml"
}

ansible_run_prereqs() {
  local inventory_file="$1"
  ansible_log "running home-ops node prerequisite playbook"
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
    -i "$inventory_file" \
    "${ANSIBLE_BOOTSTRAP_DIR}/playbooks/home-ops-prereqs.yml"
}

ansible_run_site() {
  local inventory_file="$1"
  ansible_log "running k3s-ansible site.yml"
  (
    cd "$K3S_ANSIBLE_DIR" || exit
    ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "$inventory_file" site.yml
  )
}
