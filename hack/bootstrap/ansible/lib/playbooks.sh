#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154

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
  local raw_kubeconfig
  case "$BOOTSTRAP_ANSIBLE_BACKEND" in
    k3s-ansible)
      ansible_log "running k3s-ansible site.yml"
      (
        cd "$K3S_ANSIBLE_DIR" || exit
        ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "$inventory_file" site.yml
      )
      ;;
    home-ops)
      ansible_log "running home-ops Ansible site.yml"
      raw_kubeconfig="$(ansible_raw_kubeconfig_file "$BOOTSTRAP_ANSIBLE_PROFILE")"
      mkdir -p "$(dirname "$raw_kubeconfig")"
      ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
        -i "$inventory_file" \
        "${ANSIBLE_BOOTSTRAP_DIR}/home-ops/site.yml" \
        --extra-vars "home_ops_kubeconfig_output=${raw_kubeconfig}"
      ;;
    *)
      ansible_die "unknown Ansible backend: ${BOOTSTRAP_ANSIBLE_BACKEND}"
      ;;
  esac
}

ansible_disable_kube_proxy_after_cilium() {
  local inventory_file="$1"
  ansible_log "converging post-Cilium K3s kube-proxy state"
  ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
    -i "$inventory_file" \
    "${ANSIBLE_BOOTSTRAP_DIR}/playbooks/disable-kube-proxy.yml"
}
