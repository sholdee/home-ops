#!/usr/bin/env bash
# shellcheck shell=bash

ansible_op_signin_if_needed() {
  local op_args=()
  if [[ -n "$BOOTSTRAP_ANSIBLE_OP_ACCOUNT" ]]; then
    op_args=(--account "$BOOTSTRAP_ANSIBLE_OP_ACCOUNT")
  fi

  op whoami "${op_args[@]}" >/dev/null 2>&1 && return

  local signin_tty="${BOOTSTRAP_ANSIBLE_OP_SIGNIN_TTY:-/dev/tty}"
  [[ -r "$signin_tty" && -w "$signin_tty" ]] ||
    ansible_die "1Password CLI is not signed in and no controlling terminal is available; run 'eval \"\$(op signin)\"' first"

  ansible_log "1Password CLI is not signed in; starting interactive op signin" >&2
  local signin
  signin="$(op signin --force "${op_args[@]}" <"$signin_tty")" || ansible_die "op signin failed"
  # op signin writes shell exports to stdout. Evaluate them without logging.
  eval "$signin"
}

ansible_op_read_optional() {
  local ref="$1"
  local op_args=()
  if [[ -n "$BOOTSTRAP_ANSIBLE_OP_ACCOUNT" ]]; then
    op_args=(--account "$BOOTSTRAP_ANSIBLE_OP_ACCOUNT")
  fi

  command -v op >/dev/null 2>&1 || return 1
  ansible_op_signin_if_needed
  op read -n "${op_args[@]}" "$ref" 2>/dev/null
}

ansible_op_read_required() {
  local ref="$1"
  local op_args=()
  if [[ -n "$BOOTSTRAP_ANSIBLE_OP_ACCOUNT" ]]; then
    op_args=(--account "$BOOTSTRAP_ANSIBLE_OP_ACCOUNT")
  fi

  command -v op >/dev/null 2>&1 || ansible_die "required tool not found: op"
  ansible_op_signin_if_needed
  op read -n "${op_args[@]}" "$ref"
}
