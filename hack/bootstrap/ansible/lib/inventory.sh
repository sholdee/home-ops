#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154

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
  cluster_cidr="$(yq -r '
    select(.kind == "Application" and .metadata.name == "cilium") |
    .spec.source.helm.valuesObject.ipam.operator.clusterPoolIPv4PodCIDRList |
    .[0] // .
  ' "$cilium_app")"
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
  local home_ops_defaults="${BOOTSTRAP_DIR}/ansible/home-ops/vars/defaults.yml"
  local source_hosts="${source_dir}/hosts.yml"
  local source_vars="${source_dir}/group_vars/all.yml"
  local derived="${output_dir}/group_vars/derived.yml"
  local runtime="${output_dir}/group_vars/runtime.yml"
  local output_vars="${output_dir}/group_vars/all.yml"

  [[ -f "$source_hosts" ]] || ansible_die "missing inventory hosts: ${source_hosts}"
  [[ -f "$source_vars" ]] || ansible_die "missing inventory group vars: ${source_vars}"

  mkdir -p "${output_dir}/group_vars"
  cp "$source_hosts" "${output_dir}/hosts.yml"
  ansible_write_derived_vars "$derived"

  case "$profile" in
    live)
      ansible_check_live_derived_conflicts "$source_vars" "$derived"
      ansible_write_runtime_vars "$runtime"
      case "$BOOTSTRAP_ANSIBLE_BACKEND" in
        k3s-ansible)
          [[ -f "$base_vars" ]] || ansible_die "missing k3s-ansible sample vars: ${base_vars}"
          # shellcheck disable=SC2016
          yq eval-all '. as $item ireduce ({}; . * $item)' \
            "$base_vars" "$source_vars" "$derived" "$runtime" > "$output_vars"
          ;;
        home-ops)
          [[ -f "$home_ops_defaults" ]] || ansible_die "missing home-ops backend defaults: ${home_ops_defaults}"
          # shellcheck disable=SC2016
          yq eval-all '. as $item ireduce ({}; . * $item)' \
            "$home_ops_defaults" "$source_vars" "$derived" "$runtime" > "$output_vars"
          ;;
        *)
          ansible_die "unknown Ansible backend: ${BOOTSTRAP_ANSIBLE_BACKEND}"
          ;;
      esac
      ;;
    lima)
      case "$BOOTSTRAP_ANSIBLE_BACKEND" in
        k3s-ansible)
          [[ -f "$base_vars" ]] || ansible_die "missing k3s-ansible sample vars: ${base_vars}"
          # shellcheck disable=SC2016
          yq eval-all '. as $item ireduce ({}; . * $item)' \
            "$base_vars" "$derived" "$source_vars" > "$output_vars"
          ;;
        home-ops)
          [[ -f "$home_ops_defaults" ]] || ansible_die "missing home-ops backend defaults: ${home_ops_defaults}"
          # shellcheck disable=SC2016
          yq eval-all '. as $item ireduce ({}; . * $item)' \
            "$home_ops_defaults" "$derived" "$source_vars" > "$output_vars"
          ;;
        *)
          ansible_die "unknown Ansible backend: ${BOOTSTRAP_ANSIBLE_BACKEND}"
          ;;
      esac
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

ansible_print_summary() {
  local profile="$1"
  local inventory_dir="$2"
  local vars_file="${inventory_dir}/group_vars/all.yml"
  local inventory_file="${inventory_dir}/hosts.yml"

  ansible_log "Ansible bootstrap profile: ${profile}"
  ansible_log "Ansible bootstrap backend: ${BOOTSTRAP_ANSIBLE_BACKEND}"
  if [[ "$BOOTSTRAP_ANSIBLE_BACKEND" == k3s-ansible ]]; then
    ansible_log "k3s-ansible checkout: ${K3S_ANSIBLE_DIR}"
  fi
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
