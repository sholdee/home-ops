# shellcheck shell=bash

node_validate_profile() {
  case "$1" in
    live|lima)
      ;;
    *)
      node_die "unknown node lifecycle profile: ${1}"
      ;;
  esac
}

node_context_for_profile() {
  local profile="$1"
  case "$profile" in
    live)
      printf '%s\n' default
      ;;
    lima)
      printf 'lima-%s\n' "$LIMA_CLUSTER_NAME"
      ;;
    *)
      node_die "unknown node lifecycle profile: ${profile}"
      ;;
  esac
}

node_inventory_dir() {
  local profile="$1"
  case "$profile" in
    live)
      printf '%s\n' "$NODE_LIVE_INVENTORY_DIR"
      ;;
    lima)
      printf '%s\n' "$NODE_LIMA_INVENTORY_DIR"
      ;;
    *)
      node_die "unknown node lifecycle profile: ${profile}"
      ;;
  esac
}

node_inventory_file() {
  printf '%s/hosts.yml\n' "$(node_inventory_dir "$1")"
}

node_group_vars_file() {
  printf '%s/group_vars/all.yml\n' "$(node_inventory_dir "$1")"
}

node_ansible_inventory_file() {
  node_inventory_file "$1"
}

node_inventory_exists() {
  [[ -f "$(node_inventory_file "$1")" ]]
}

node_inventory_group_has() {
  local profile="$1"
  local group="$2"
  local node="$3"
  local inventory
  inventory="$(node_inventory_file "$profile")"
  [[ -f "$inventory" ]] || return 1
  NODE_NAME="$node" "$NODE_YQ_BIN" -r \
    ".all.children.k3s_cluster.children.${group}.hosts | has(strenv(NODE_NAME))" \
    "$inventory" 2>/dev/null | grep -Fxq true
}

node_inventory_role() {
  local profile="$1"
  local node="$2"
  local in_master=false
  local in_node=false
  if node_inventory_group_has "$profile" master "$node"; then
    in_master=true
  fi
  if node_inventory_group_has "$profile" node "$node"; then
    in_node=true
  fi

  case "${in_master}:${in_node}" in
    true:false)
      printf '%s\n' master
      ;;
    false:true)
      printf '%s\n' node
      ;;
    false:false)
      printf '%s\n' absent
      ;;
    true:true)
      printf '%s\n' conflict
      ;;
  esac
}

node_resolve_inventory_node() {
  local profile="$1"
  local input_node="$2"
  local inventory_node="$input_node"
  local inventory_role

  inventory_role="$(node_inventory_role "$profile" "$inventory_node")"
  if [[ "$inventory_role" == absent && "$profile" == lima && "$input_node" == lima-* ]]; then
    local inventory_candidate="${input_node#lima-}"
    local inventory_candidate_role
    inventory_candidate_role="$(node_inventory_role "$profile" "$inventory_candidate")"
    if [[ "$inventory_candidate_role" != absent ]]; then
      inventory_node="$inventory_candidate"
      inventory_role="$inventory_candidate_role"
    fi
  fi

  printf '%s\t%s\n' "$inventory_node" "$inventory_role"
}

node_expected_kubernetes_node_name() {
  local profile="$1"
  local inventory_node="$2"
  local input_node="$3"

  if [[ "$profile" == lima ]]; then
    if [[ "$input_node" == lima-* ]]; then
      printf '%s\n' "$input_node"
    else
      printf 'lima-%s\n' "$inventory_node"
    fi
    return
  fi

  printf '%s\n' "$inventory_node"
}

node_inventory_value() {
  local profile="$1"
  local node="$2"
  local key="$3"
  local role
  local inventory
  role="$(node_inventory_role "$profile" "$node")"
  [[ "$role" == master || "$role" == node ]] || return 1
  inventory="$(node_inventory_file "$profile")"
  NODE_NAME="$node" "$NODE_YQ_BIN" -r \
    ".all.children.k3s_cluster.children.${role}.hosts[strenv(NODE_NAME)].${key} // \"\"" \
    "$inventory"
}

node_inventory_group_names() {
  local profile="$1"
  local group="$2"
  local inventory
  inventory="$(node_inventory_file "$profile")"
  [[ -f "$inventory" ]] || return 0
  "$NODE_YQ_BIN" -r \
    ".all.children.k3s_cluster.children.${group}.hosts // {} | keys | .[]" \
    "$inventory"
}

node_first_inventory_master() {
  node_inventory_group_names "$1" master | sed -n '1p'
}

node_is_first_inventory_master() {
  local profile="$1"
  local inventory_node="$2"
  local first_inventory_master
  first_inventory_master="$(node_first_inventory_master "$profile")"
  [[ -n "$first_inventory_master" && "$inventory_node" == "$first_inventory_master" ]]
}

node_inventory_group_count() {
  local profile="$1"
  local group="$2"
  local inventory
  inventory="$(node_inventory_file "$profile")"
  [[ -f "$inventory" ]] || {
    printf '0\n'
    return 0
  }
  "$NODE_YQ_BIN" -r \
    ".all.children.k3s_cluster.children.${group}.hosts // {} | length" \
    "$inventory"
}

node_etcd_quorum_size() {
  local member_count="$1"
  ((member_count > 0)) || {
    printf '0\n'
    return 0
  }
  printf '%s\n' $((member_count / 2 + 1))
}

node_group_var() {
  local profile="$1"
  local key="$2"
  local group_vars
  group_vars="$(node_group_vars_file "$profile")"
  [[ -f "$group_vars" ]] || return 1
  "$NODE_YQ_BIN" -r ".${key}" "$group_vars"
}

node_effective_ansible_user() {
  local profile="$1"
  local node="$2"
  local value
  value="$(node_inventory_value "$profile" "$node" ansible_user 2>/dev/null || true)"
  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  value="$(node_group_var "$profile" ansible_user 2>/dev/null || true)"
  [[ -n "$value" && "$value" != "null" ]] && printf '%s\n' "$value"
}

node_effective_ssh_key() {
  local profile="$1"
  local node="$2"
  local value
  local home_prefix
  home_prefix="$(printf '%s/' '~')"
  value="$(node_inventory_value "$profile" "$node" ansible_ssh_private_key_file 2>/dev/null || true)"
  if [[ -z "$value" || "$value" == "null" ]]; then
    value="$(node_group_var "$profile" ansible_ssh_private_key_file 2>/dev/null || true)"
  fi
  [[ -n "$value" && "$value" != "null" ]] || return 0
  if [[ "${value:0:2}" == "$home_prefix" ]]; then
    printf '%s/%s\n' "$HOME" "${value:2}"
  else
    printf '%s\n' "$value"
  fi
}
