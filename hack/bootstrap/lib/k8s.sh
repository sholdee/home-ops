#!/usr/bin/env bash

kubectl_cmd() {
  local args=()
  if [[ -n "${KUBECONFIG_PATH:-}" ]]; then
    args+=(--kubeconfig "$KUBECONFIG_PATH")
  fi
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    args+=(--context "$KUBE_CONTEXT")
  fi
  kubectl "${args[@]}" "$@"
}

helm_cluster_cmd() {
  local args=()
  if [[ -n "${KUBECONFIG_PATH:-}" ]]; then
    args+=(--kubeconfig "$KUBECONFIG_PATH")
  fi
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    args+=(--kube-context "$KUBE_CONTEXT")
  fi
  helm "${args[@]}" "$@"
}

apply_stream() {
  local args=(apply --server-side --field-manager="${FIELD_MANAGER}" -f -)
  if bool "$DRY_RUN"; then
    args=(apply --server-side --dry-run=server --field-manager="${FIELD_MANAGER}" -f -)
  fi
  kubectl_cmd "${args[@]}"
}

apply_file() {
  local file="$1"
  if bool "$DRY_RUN"; then
    local output status
    set +e
    output="$(kubectl_cmd apply --server-side --dry-run=server --field-manager="${FIELD_MANAGER}" -f "$file" 2>&1)"
    status=$?
    set -e
    printf '%s\n' "$output"
    if [[ "$status" -eq 0 ]]; then
      return
    fi
    if [[ "$output" == *'namespaces "'*' not found'* ]]; then
      log "server dry-run hit missing namespace; retrying ${file} with client dry-run"
      kubectl_cmd apply --dry-run=client -f "$file"
      return
    fi
    return "$status"
  else
    kubectl_cmd apply --server-side --field-manager="${FIELD_MANAGER}" -f "$file"
  fi
}

apply_secret_stream() {
  if bool "$DRY_RUN"; then
    kubectl_cmd apply --server-side --force-conflicts --dry-run=server --field-manager="${FIELD_MANAGER}" -f -
  else
    kubectl_cmd apply --server-side --force-conflicts --field-manager="${FIELD_MANAGER}" -f -
  fi
}

remove_client_apply_annotation() {
  local namespace="$1"
  local name="$2"
  if bool "$DRY_RUN"; then
    return
  fi
  kubectl_cmd -n "$namespace" annotate "secret/${name}" kubectl.kubernetes.io/last-applied-configuration- >/dev/null 2>&1 || true
}

ensure_namespace() {
  local namespace="$1"
  cat <<EOF | apply_stream
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
EOF
}

wait_deployment() {
  local namespace="$1"
  local name="$2"
  if bool "$DRY_RUN"; then
    log "dry-run: skip wait for deployment/${name} in ${namespace}"
    return
  fi
  kubectl_cmd -n "$namespace" rollout status "deployment/${name}" --timeout=180s
}

wait_statefulset() {
  local namespace="$1"
  local name="$2"
  if bool "$DRY_RUN"; then
    log "dry-run: skip wait for statefulset/${name} in ${namespace}"
    return
  fi
  kubectl_cmd -n "$namespace" rollout status "statefulset/${name}" --timeout=180s
}

wait_crd() {
  local name="$1"
  if bool "$DRY_RUN"; then
    log "dry-run: skip wait for crd/${name}"
    return
  fi
  kubectl_cmd wait --for=condition=Established "crd/${name}" --timeout=180s
}

crd_exists() {
  kubectl_cmd get "crd/$1" >/dev/null 2>&1
}

wait_secret() {
  local namespace="$1"
  local name="$2"
  if bool "$DRY_RUN"; then
    log "dry-run: skip wait for secret/${name} in ${namespace}"
    return
  fi
  local i
  for ((i = 0; i < 60; i++)); do
    if kubectl_cmd -n "$namespace" get "secret/${name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  die "timed out waiting for secret/${name} in ${namespace}"
}

wait_secret_keys() {
  local namespace="$1"
  local name="$2"
  shift 2
  if bool "$DRY_RUN"; then
    log "dry-run: skip wait for secret/${name} keys in ${namespace}"
    return
  fi
  local i key secret_json
  for ((i = 0; i < 60; i++)); do
    local all_present=true
    secret_json="$(kubectl_cmd -n "$namespace" get "secret/${name}" -o json 2>/dev/null || true)"
    for key in "$@"; do
      if [[ -z "$secret_json" ]] ||
        ! jq -e --arg key "$key" '.data[$key] // empty' <<<"$secret_json" >/dev/null 2>&1; then
        all_present=false
        break
      fi
    done
    if [[ "$all_present" == true ]]; then
      return 0
    fi
    sleep 5
  done
  die "timed out waiting for secret/${name} keys in ${namespace}: $*"
}

delete_secret_unless_cert_manager_issuer() {
  local namespace="$1"
  local name="$2"
  local issuer="$3"
  if bool "$DRY_RUN"; then
    log "dry-run: skip stale cert-manager issuer check for secret/${name} in ${namespace}"
    return 1
  fi
  local actual
  actual="$(
    kubectl_cmd -n "$namespace" get "secret/${name}" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/issuer-name}' 2>/dev/null || true
  )"
  if [[ -z "$actual" ]]; then
    if kubectl_cmd -n "$namespace" get "secret/${name}" >/dev/null 2>&1; then
      log "deleting stale secret/${name} in ${namespace}; missing cert-manager issuer ${issuer}"
      kubectl_cmd -n "$namespace" delete "secret/${name}" --ignore-not-found
      return 0
    fi
    return 1
  fi
  if [[ "$actual" != "$issuer" ]]; then
    log "deleting stale secret/${name} in ${namespace}; issuer ${actual} != ${issuer}"
    kubectl_cmd -n "$namespace" delete "secret/${name}" --ignore-not-found
    return 0
  fi
  return 1
}

wait_certificate_ready() {
  local namespace="$1"
  local name="$2"
  if bool "$DRY_RUN"; then
    log "dry-run: skip wait for certificate/${name} in ${namespace}"
    return
  fi
  kubectl_cmd -n "$namespace" wait --for=condition=Ready "certificate/${name}" --timeout=180s
}

wait_clustersecretstore_ready() {
  local name="$1"
  if bool "$DRY_RUN"; then
    log "dry-run: skip wait for clustersecretstore/${name}"
    return
  fi
  local status i
  for ((i = 0; i < 60; i++)); do
    status="$(kubectl_cmd get clustersecretstore "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "$status" == "True" ]]; then
      return 0
    fi
    sleep 5
  done
  die "timed out waiting for clustersecretstore/${name} Ready"
}

print_target_cluster() {
  local context server
  context="$(kubectl_cmd config current-context)"
  server="$(kubectl_cmd config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  log "target context: ${context}"
  log "api server: ${server}"
}
