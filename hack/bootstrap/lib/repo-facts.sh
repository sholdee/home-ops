#!/usr/bin/env bash
# shellcheck shell=bash

bootstrap_repo_root() {
  if [[ -n "${REPO_ROOT:-}" ]]; then
    printf '%s\n' "$REPO_ROOT"
  elif [[ -n "${ROOT:-}" ]]; then
    printf '%s\n' "$ROOT"
  else
    printf 'ERROR: REPO_ROOT is not set\n' >&2
    return 1
  fi
}

bootstrap_repo_yq() {
  "${BOOTSTRAP_YQ_BIN:-${NODE_YQ_BIN:-${ANSIBLE_YQ_BIN:-yq}}}" "$@"
}

bootstrap_repo_fact_required() {
  local name="$1"
  local value="$2"
  [[ -n "$value" && "$value" != "null" ]] || {
    printf 'ERROR: could not derive %s from home-ops manifests\n' "$name" >&2
    return 1
  }
  printf '%s\n' "$value"
}

bootstrap_repo_apps_manifest() {
  printf '%s/apps/argocd/manifests/apps.yaml\n' "$(bootstrap_repo_root)"
}

bootstrap_repo_cilium_bgp_manifest() {
  printf '%s/apps/kube-system/cilium/manifests/CiliumBGPClusterConfig.yaml\n' "$(bootstrap_repo_root)"
}

bootstrap_repo_kube_vip_manifest() {
  printf '%s/apps/kube-system/kube-vip/manifests/daemonset.yaml\n' "$(bootstrap_repo_root)"
}

bootstrap_repo_upgrade_plan_manifest() {
  printf '%s/apps/system-upgrade/manifests/plan.yaml\n' "$(bootstrap_repo_root)"
}

bootstrap_repo_k3s_version() {
  local value
  value="$(bootstrap_repo_yq -r 'select(.kind == "Plan" and .metadata.name == "k3s-server") | .spec.version' "$(bootstrap_repo_upgrade_plan_manifest)")"
  bootstrap_repo_fact_required k3s_version "$value"
}

bootstrap_repo_cilium_helm_value() {
  local expression="$1"
  bootstrap_repo_yq -r "
    select(.kind == \"Application\" and .metadata.name == \"cilium\") |
    .spec.source.helm.valuesObject.${expression}
  " "$(bootstrap_repo_apps_manifest)"
}

bootstrap_repo_cilium_target_revision() {
  local value
  value="$(bootstrap_repo_yq -r 'select(.kind == "Application" and .metadata.name == "cilium") | .spec.source.targetRevision' "$(bootstrap_repo_apps_manifest)")"
  bootstrap_repo_fact_required cilium_target_revision "$value"
}

bootstrap_repo_cilium_tag() {
  local value
  value="$(bootstrap_repo_cilium_target_revision)"
  printf 'v%s\n' "${value#v}"
}

bootstrap_repo_cluster_cidr() {
  local value
  value="$(bootstrap_repo_yq -r '
    select(.kind == "Application" and .metadata.name == "cilium") |
    .spec.source.helm.valuesObject.ipam.operator.clusterPoolIPv4PodCIDRList |
    .[0] // .
  ' "$(bootstrap_repo_apps_manifest)")"
  bootstrap_repo_fact_required cluster_cidr "$value"
}

bootstrap_repo_kube_proxy_replacement() {
  local value
  value="$(bootstrap_repo_cilium_helm_value kubeProxyReplacement)"
  bootstrap_repo_fact_required kube_proxy_replacement "$value"
}

bootstrap_repo_cilium_routing_mode() {
  bootstrap_repo_fact_required cilium_mode "$(bootstrap_repo_cilium_helm_value routingMode)"
}

bootstrap_repo_cilium_datapath_mode() {
  bootstrap_repo_fact_required cilium_datapath_mode "$(bootstrap_repo_cilium_helm_value bpf.datapathMode)"
}

bootstrap_repo_cilium_hubble_enabled() {
  bootstrap_repo_fact_required cilium_hubble "$(bootstrap_repo_cilium_helm_value hubble.enabled)"
}

bootstrap_repo_cilium_bgp_enabled() {
  bootstrap_repo_fact_required cilium_bgp "$(bootstrap_repo_cilium_helm_value bgpControlPlane.enabled)"
}

bootstrap_repo_cilium_bpf_masquerade() {
  bootstrap_repo_fact_required enable_bpf_masquerade "$(bootstrap_repo_cilium_helm_value bpf.masquerade)"
}

bootstrap_repo_cilium_load_balancer_algorithm() {
  bootstrap_repo_fact_required bpf_lb_algorithm "$(bootstrap_repo_cilium_helm_value loadBalancer.algorithm)"
}

bootstrap_repo_cilium_load_balancer_mode() {
  bootstrap_repo_fact_required bpf_lb_mode "$(bootstrap_repo_cilium_helm_value loadBalancer.mode)"
}

bootstrap_repo_cilium_local_asn() {
  bootstrap_repo_fact_required local_asn "$(bootstrap_repo_yq -r 'select(.kind == "CiliumBGPClusterConfig") | .spec.bgpInstances[0].localASN' "$(bootstrap_repo_cilium_bgp_manifest)")"
}

bootstrap_repo_cilium_peer_asn() {
  bootstrap_repo_fact_required peer_asn "$(bootstrap_repo_yq -r 'select(.kind == "CiliumBGPClusterConfig") | .spec.bgpInstances[0].peers[0].peerASN' "$(bootstrap_repo_cilium_bgp_manifest)")"
}

bootstrap_repo_cilium_peer_address() {
  bootstrap_repo_fact_required peer_address "$(bootstrap_repo_yq -r 'select(.kind == "CiliumBGPClusterConfig") | .spec.bgpInstances[0].peers[0].peerAddress' "$(bootstrap_repo_cilium_bgp_manifest)")"
}

bootstrap_repo_cilium_lb_cidr() {
  bootstrap_repo_fact_required lb_cidr "$(bootstrap_repo_yq -r 'select(.kind == "CiliumLoadBalancerIPPool") | .spec.blocks[0].cidr' "$(bootstrap_repo_cilium_bgp_manifest)")"
}

bootstrap_repo_kube_vip_image() {
  bootstrap_repo_fact_required kube_vip_image "$(bootstrap_repo_yq -r '.spec.template.spec.containers[] | select(.name == "kube-vip") | .image' "$(bootstrap_repo_kube_vip_manifest)")"
}

bootstrap_repo_kube_vip_tag() {
  local image tag
  image="$(bootstrap_repo_kube_vip_image)"
  tag="$(sed -E 's/^.*:(v[^@]+).*$/\1/' <<<"$image")"
  bootstrap_repo_fact_required kube_vip_tag "$tag"
}

bootstrap_repo_apiserver_endpoint() {
  local value
  value="$(bootstrap_repo_yq -r '.spec.template.spec.containers[] | select(.name == "kube-vip") | .env[] | select(.name == "address") | .value' "$(bootstrap_repo_kube_vip_manifest)")"
  bootstrap_repo_fact_required apiserver_endpoint "$value"
}
