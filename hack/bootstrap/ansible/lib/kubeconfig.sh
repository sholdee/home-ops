#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154

ansible_prepare_kubeconfig() {
  local profile="$1"
  local raw_kubeconfig
  local kubeconfig
  raw_kubeconfig="$(ansible_raw_kubeconfig_file "$profile")"
  kubeconfig="$(ansible_kubeconfig_file "$profile")"
  [[ -f "$raw_kubeconfig" ]] || ansible_die "missing kubeconfig from ${BOOTSTRAP_ANSIBLE_BACKEND} run: ${raw_kubeconfig}"
  mkdir -p "$(dirname "$kubeconfig")"
  cp "$raw_kubeconfig" "$kubeconfig"
  BOOTSTRAP_ANSIBLE_KUBECONTEXT="$BOOTSTRAP_ANSIBLE_KUBECONTEXT" yq -i '
    .clusters[0].name = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    .users[0].name = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    .contexts[0].name = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    .contexts[0].context.cluster = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    .contexts[0].context.user = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT) |
    ."current-context" = strenv(BOOTSTRAP_ANSIBLE_KUBECONTEXT)
  ' "$kubeconfig"
  printf '%s\n' "$kubeconfig"
}

ansible_import_kubeconfig() {
  local profile="$1"
  local kubeconfig kubeconfig_env target tmp previous_context
  kubeconfig="$(ansible_prepare_kubeconfig "$profile")"
  kubeconfig_env="${KUBECONFIG:-$BOOTSTRAP_ANSIBLE_USER_KUBECONFIG}"
  target="${kubeconfig_env%%:*}"
  mkdir -p "$(dirname "$target")"
  touch "$target"
  chmod 0600 "$target" >/dev/null 2>&1 || true
  previous_context="$(kubectl --kubeconfig "$target" config current-context 2>/dev/null || true)"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  KUBECONFIG="${kubeconfig}:${kubeconfig_env}" kubectl config view --flatten > "$tmp"
  if [[ -n "$previous_context" ]]; then
    kubectl --kubeconfig "$tmp" config use-context "$previous_context" >/dev/null
  fi
  chmod 0600 "$tmp"
  mv "$tmp" "$target"
  ansible_log "imported kube context ${BOOTSTRAP_ANSIBLE_KUBECONTEXT} into ${target}"
}
