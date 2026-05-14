#!/usr/bin/env bash
# shellcheck shell=bash

ansible_token_ref() {
  printf 'op://%s/%s/%s\n' \
    "$BOOTSTRAP_ANSIBLE_OP_VAULT" \
    "$BOOTSTRAP_ANSIBLE_OP_ITEM" \
    "$BOOTSTRAP_ANSIBLE_OP_FIELD"
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
  ansible_op_read_optional "$(ansible_token_ref)"
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

  if command -v op >/dev/null 2>&1; then
    ansible_op_signin_if_needed
  fi

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
