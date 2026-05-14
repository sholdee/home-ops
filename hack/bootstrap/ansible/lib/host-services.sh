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
HOME_OPS_GITHUB_APP_ID
HOME_OPS_GITHUB_APP_INSTALLATION_ID
HOME_OPS_GITHUB_APP_PRIVATE_KEY
EOF
      ;;
    master)
      cat <<'EOF'
HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME
HOME_OPS_RPI_REPORTER_MQTT_USERNAME
HOME_OPS_RPI_REPORTER_MQTT_PASSWORD
HOME_OPS_NUT_MONITOR_SYSTEM
HOME_OPS_NUT_MONITOR_USER
HOME_OPS_NUT_MONITOR_PASSWORD
EOF
      ;;
    all)
      cat <<'EOF'
HOME_OPS_RPI_REPORTER_MQTT_HOSTNAME
HOME_OPS_RPI_REPORTER_MQTT_USERNAME
HOME_OPS_RPI_REPORTER_MQTT_PASSWORD
HOME_OPS_NUT_MONITOR_SYSTEM
HOME_OPS_NUT_MONITOR_USER
HOME_OPS_NUT_MONITOR_PASSWORD
HOME_OPS_GITHUB_APP_ID
HOME_OPS_GITHUB_APP_INSTALLATION_ID
HOME_OPS_GITHUB_APP_PRIVATE_KEY
EOF
      ;;
    *)
      ansible_die "unknown host service secret role: ${role}"
      ;;
  esac
}

ansible_host_service_needs_github_runner() {
  local role="$1"
  [[ "$role" == node || "$role" == all ]]
}

ansible_base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

ansible_github_app_private_key() {
  local private_key

  private_key="$HOME_OPS_GITHUB_APP_PRIVATE_KEY"
  if [[ "$private_key" == *"-----BEGIN "* ]]; then
    if [[ "$private_key" == *\\n* ]]; then
      printf '%b' "$private_key"
    else
      printf '%s\n' "$private_key"
    fi
  else
    printf '%s' "$private_key" | tr -d '[:space:]' | openssl base64 -d -A
  fi
}

ansible_github_app_jwt() {
  local now iat exp header payload signing_input signature key_file

  now="$(date +%s)"
  iat=$((now - 60))
  exp=$((now + 540))
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | ansible_base64url)"
  payload="$(
    jq -cn \
      --argjson iat "$iat" \
      --argjson exp "$exp" \
      --arg iss "$HOME_OPS_GITHUB_APP_ID" \
      '{iat:$iat, exp:$exp, iss:$iss}' |
      ansible_base64url
  )"
  signing_input="${header}.${payload}"

  key_file="$(mktemp "${TMPDIR:-/tmp}/home-ops-github-app-key.XXXXXX")"
  chmod 600 "$key_file"
  if ! ansible_github_app_private_key > "$key_file"; then
    rm -f "$key_file"
    ansible_die "HOME_OPS_GITHUB_APP_PRIVATE_KEY is not valid base64-encoded PEM private key data"
  fi

  if ! openssl pkey -in "$key_file" -noout >/dev/null 2>&1; then
    rm -f "$key_file"
    ansible_die "HOME_OPS_GITHUB_APP_PRIVATE_KEY is not a valid PEM private key after decoding; store the base64-encoded full PEM including BEGIN/END lines"
  fi

  if ! signature="$(
    printf '%s' "$signing_input" |
      openssl dgst -sha256 -sign "$key_file" |
      ansible_base64url
  )"; then
    rm -f "$key_file"
    ansible_die "could not sign GitHub App JWT with HOME_OPS_GITHUB_APP_PRIVATE_KEY"
  fi
  rm -f "$key_file"

  printf '%s.%s\n' "$signing_input" "$signature"
}

ansible_github_app_installation_access_token() {
  local api_url api_version jwt body response response_body response_status token message

  api_url="${HOME_OPS_GITHUB_API_URL:-https://api.github.com}"
  api_version="${HOME_OPS_GITHUB_API_VERSION:-2022-11-28}"
  if ! jwt="$(ansible_github_app_jwt)"; then
    ansible_die "could not create GitHub App JWT for host services"
  fi
  body="$(
    jq -cn \
      --arg repo "${HOME_OPS_GITHUB_RUNNER_REPO_NAME:-home-ops}" \
      '{repositories: [$repo], permissions: {administration: "write"}}'
  )"

  if ! response="$(
    curl -sS \
      --request POST \
      --url "${api_url}/app/installations/${HOME_OPS_GITHUB_APP_INSTALLATION_ID}/access_tokens" \
      --header "Accept: application/vnd.github+json" \
      --header "Authorization: Bearer ${jwt}" \
      --header "X-GitHub-Api-Version: ${api_version}" \
      --data "$body" \
      --write-out $'\n%{http_code}'
  )"; then
    ansible_die "could not mint GitHub App installation access token for host services"
  fi
  response_status="${response##*$'\n'}"
  response_body="${response%$'\n'*}"

  if [[ "$response_status" != 201 ]]; then
    message="$(
      jq -r '
        .message as $message |
        (.errors // [] | map(.message // .code // tostring) | join("; ")) as $errors |
        [$message, $errors] | map(select(. != null and . != "")) | join(": ")
      ' <<<"$response_body" 2>/dev/null || printf '%s' "$response_body"
    )"
    if [[ "$message" == *"permissions requested are not granted"* ]]; then
      message="${message} Grant the GitHub App repository Administration permission as Read and write, then update or reinstall the app installation for sholdee/home-ops."
    fi
    ansible_die "GitHub App installation access token request failed (${response_status}): ${message}"
  fi

  if ! token="$(jq -er '.token // empty' <<<"$response_body")"; then
    ansible_die "GitHub App installation access token response did not include a token"
  fi

  printf '%s\n' "$token"
}

ansible_prepare_github_runner_access_token() {
  [[ -z "${HOME_OPS_GITHUB_RUNNER_ACCESS_TOKEN:-}" ]] || return

  ansible_require_tool curl
  ansible_require_tool jq
  ansible_require_tool openssl
  ansible_log "minting GitHub App installation token for runner registration"
  HOME_OPS_GITHUB_RUNNER_ACCESS_TOKEN="$(ansible_github_app_installation_access_token)"
  export HOME_OPS_GITHUB_RUNNER_ACCESS_TOKEN
}

ansible_load_host_service_secrets_from_op() {
  local role="${1:-all}"
  local var value item_json needs_op=false
  local op_args=()

  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    if [[ -z "${!var:-}" ]]; then
      needs_op=true
      break
    fi
  done < <(ansible_host_service_secret_vars "$role")

  ansible_bool "$needs_op" || return

  command -v op >/dev/null 2>&1 || return 0
  if [[ -n "${BOOTSTRAP_ANSIBLE_HOST_SERVICES_ITEM_JSON:-}" ]]; then
    item_json="$BOOTSTRAP_ANSIBLE_HOST_SERVICES_ITEM_JSON"
  else
    ansible_op_signin_if_needed
    if [[ -n "$BOOTSTRAP_ANSIBLE_OP_ACCOUNT" ]]; then
      op_args=(--account "$BOOTSTRAP_ANSIBLE_OP_ACCOUNT")
    fi

    item_json="$(
      op item get "$BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_ITEM" \
        --vault "$BOOTSTRAP_ANSIBLE_HOST_SERVICES_OP_VAULT" \
        --format json \
        "${op_args[@]}" 2>/dev/null || true
    )"
    BOOTSTRAP_ANSIBLE_HOST_SERVICES_ITEM_JSON="$item_json"
  fi
  [[ -n "$item_json" ]] || return 0

  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    [[ -z "${!var:-}" ]] || continue

    value="$(
      jq -r --arg field "$var" '
        [
          .fields[]? |
          select((.label // "") == $field or (.id // "") == $field) |
          .value // empty
        ] |
        .[0] // empty
      ' <<<"$item_json"
    )"
    [[ -n "$value" ]] || continue
    export "${var}=${value}"
  done < <(ansible_host_service_secret_vars "$role")
}

ansible_require_host_service_env() {
  local role="$1"
  local var missing=()

  ansible_load_host_service_secrets_from_op "$role"

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

  if ansible_host_service_needs_github_runner "$role"; then
    ansible_prepare_github_runner_access_token
  fi
}
