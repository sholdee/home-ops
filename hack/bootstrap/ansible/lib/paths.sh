#!/usr/bin/env bash
# shellcheck shell=bash

ansible_inventory_dir() {
  local profile="${1:-$BOOTSTRAP_ANSIBLE_PROFILE}"
  printf '%s/inventory/%s\n' "$BOOTSTRAP_ANSIBLE_OUT_DIR" "$profile"
}

ansible_set_profile() {
  BOOTSTRAP_ANSIBLE_PROFILE="$1"
  export BOOTSTRAP_ANSIBLE_PROFILE
  if ansible_bool "$BOOTSTRAP_ANSIBLE_OUT_DIR_DEFAULTED"; then
    BOOTSTRAP_ANSIBLE_OUT_DIR="${BOOTSTRAP_DIR}/.out/ansible-${BOOTSTRAP_ANSIBLE_PROFILE}"
    export BOOTSTRAP_ANSIBLE_OUT_DIR
  fi
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

ansible_home_ops_raw_kubeconfig_file() {
  local profile="${1:-$BOOTSTRAP_ANSIBLE_PROFILE}"
  printf '%s/kubeconfig-raw-%s\n' "$BOOTSTRAP_ANSIBLE_OUT_DIR" "$profile"
}

ansible_raw_kubeconfig_file() {
  local profile="${1:-$BOOTSTRAP_ANSIBLE_PROFILE}"
  case "$BOOTSTRAP_ANSIBLE_BACKEND" in
    k3s-ansible)
      printf '%s/kubeconfig\n' "$K3S_ANSIBLE_DIR"
      ;;
    home-ops)
      ansible_home_ops_raw_kubeconfig_file "$profile"
      ;;
    *)
      ansible_die "unknown Ansible backend: ${BOOTSTRAP_ANSIBLE_BACKEND}"
      ;;
  esac
}
