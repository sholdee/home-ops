#!/usr/bin/env bash

setup_report_dir() {
  local timestamp
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  REPORT_DIR="${BOOTSTRAP_DIR}/.out/bootstrap-${timestamp}"
  mkdir -p "${REPORT_DIR}/rendered"
}

write_inventory() {
  local file="${REPORT_DIR}/inventory.json"
  cat > "$file" <<EOF
{
  "repoRoot": "${REPO_ROOT}",
  "dryRun": ${DRY_RUN},
  "profile": "${BOOTSTRAP_PROFILE}",
  "fieldManager": "${FIELD_MANAGER}",
  "opVault": "${OP_VAULT}",
  "opItem": "${OP_ITEM}",
  "opField": "${OP_FIELD}",
  "opAccount": "${BOOTSTRAP_OP_ACCOUNT}",
  "seedSecretStdin": ${SEED_SECRET_STDIN}
}
EOF
}

save_render_if_safe() {
  local name="$1"
  local file="$2"
  if [[ -n "$(yq -r 'select(.kind == "Secret") | .kind' "$file")" ]]; then
    log "not saving render ${name}: contains Secret resources"
    return
  fi
  cp "$file" "${REPORT_DIR}/rendered/${name}.yaml"
}
