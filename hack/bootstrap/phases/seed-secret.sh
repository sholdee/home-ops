#!/usr/bin/env bash

ensure_namespace external-secrets

op_ref="op://${OP_VAULT}/${OP_ITEM}/${OP_FIELD}"
log "reading seed secret from ${op_ref}"

op_args=()
if [[ -n "${BOOTSTRAP_OP_ACCOUNT:-}" ]]; then
  op_args+=(--account "$BOOTSTRAP_OP_ACCOUNT")
fi

op_signin_if_needed() {
  bool "$SEED_SECRET_STDIN" && return
  op whoami "${op_args[@]}" >/dev/null 2>&1 && return

  [[ -t 0 ]] || die "1Password CLI is not signed in and stdin is not interactive; run 'eval \"\$(op signin)\"' first, or pipe the seed Secret with --seed-secret-stdin"

  log "1Password CLI is not signed in; starting interactive op signin"
  local signin
  signin="$(op signin --force "${op_args[@]}")" || die "op signin failed"
  # op signin writes shell exports to stdout. Evaluate them without logging.
  eval "$signin"
  op whoami "${op_args[@]}" >/dev/null 2>&1 || die "op signin completed but op whoami still failed"
}

op_read_seed_secret() {
  if bool "$SEED_SECRET_STDIN"; then
    cat
    return
  fi
  op_signin_if_needed
  op read "${op_args[@]}" "$op_ref"
}

normalize_seed_secret() {
  yq -o=json | jq '
    def b64_json_type: try (@base64d | fromjson | type) catch null;
    def double_b64_json_type: try (@base64d | @base64d | fromjson | type) catch null;
    def string_data_to_data:
      if .kind == "Secret" and ((.stringData? // {}) | type) == "object" and ((.stringData? // {}) != {}) then
        .data = ((.data // {}) + (.stringData | with_entries(.value |= @base64))) |
        del(.stringData)
      else
        .
      end;

    (if .kind != "Secret" then
       .
    elif (.stringData?["1password-credentials.json"]? | b64_json_type) != null then
      .data = (.data // {}) |
      .data["1password-credentials.json"] = .stringData["1password-credentials.json"] |
      del(.stringData["1password-credentials.json"]) |
      if (.stringData // {}) == {} then del(.stringData) else . end
    elif (.data?["1password-credentials.json"]? | double_b64_json_type) != null then
      .data["1password-credentials.json"] = (.data["1password-credentials.json"] | @base64d)
    else
      .
    end) | string_data_to_data
  ' | yq -P
}

op_read_seed_secret | normalize_seed_secret | yq -e '
  select(
    .kind == "Secret" and
    .metadata.name == "op-credentials" and
    .metadata.namespace == "external-secrets" and
    (((.data // {}) | has("token")) or ((.stringData // {}) | has("token"))) and
    (((.data // {}) | has("1password-credentials.json")) or ((.stringData // {}) | has("1password-credentials.json")))
  )
' 2>/dev/null | apply_secret_stream || die "could not read or validate seed Secret; verify 'op read ${op_ref} >/dev/null' works, or pipe it with --seed-secret-stdin"

remove_client_apply_annotation external-secrets op-credentials
