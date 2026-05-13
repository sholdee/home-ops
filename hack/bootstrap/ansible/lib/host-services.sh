#!/usr/bin/env bash
# shellcheck shell=bash

ansible_host_service_secret_ref() {
  local field="$1"
  printf 'op://%s/%s/%s\n' \
    "$BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_VAULT" \
    "$BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_ITEM" \
    "$field"
}

ansible_host_service_secret_vars() {
  local role="$1"
  case "$role" in
    node)
      cat <<'EOF'
HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME
HOME_OPS_RPI_REPORTER_MQTT_USERNAME
HOME_OPS_RPI_REPORTER_MQTT_PASSWORD
EOF
      ;;
    master|all)
      cat <<'EOF'
HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME
HOME_OPS_RPI_REPORTER_MQTT_USERNAME
HOME_OPS_RPI_REPORTER_MQTT_PASSWORD
HOME_OPS_NUT_MONITOR_SYSTEM
HOME_OPS_NUT_MONITOR_USER
HOME_OPS_NUT_MONITOR_PASSWORD
EOF
      ;;
    *)
      ansible_die "unknown host service secret role: ${role}"
      ;;
  esac
}

ansible_load_host_service_secrets_from_op() {
  local var value ref needs_op=false

  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    if [[ -z "${!var:-}" ]]; then
      needs_op=true
      break
    fi
  done < <(ansible_host_service_secret_vars all)

  ansible_bool "$needs_op" || return

  command -v op >/dev/null 2>&1 || return 0
  ansible_op_signin_if_needed

  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    [[ -z "${!var:-}" ]] || continue

    ref="$(ansible_host_service_secret_ref "$var")"
    value="$(ansible_op_read_optional "$ref" || true)"
    [[ -n "$value" ]] || continue
    export "${var}=${value}"
  done < <(ansible_host_service_secret_vars all)
}

ansible_require_host_service_env() {
  local role="$1"
  local var missing=()

  ansible_load_host_service_secrets_from_op

  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done < <(ansible_host_service_secret_vars "$role")

  if ((${#missing[@]} > 0)); then
    {
      printf 'ERROR: missing host service secret environment values for %s:\n' "$role"
      printf '  - %s\n' "${missing[@]}"
      printf 'Create fields with these exact names in %s, or export them before running Ansible.\n' \
        "op://${BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_VAULT}/${BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_ITEM}"
    } >&2
    exit 1
  fi
}
