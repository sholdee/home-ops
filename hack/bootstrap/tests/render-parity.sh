#!/usr/bin/env bash
# render-parity.sh — drydock vs raw-render key-set parity check for bootstrap apps.
#
# Usage:
#   render-parity.sh <app> <raw-render-cmd>   assert mode: exit 0 if key sets match
#   render-parity.sh --update                 update mode: write golden key-sets for all apps
#
# In assert mode the script:
#   1. Captures the drydock key set for <app>.
#   2. Diffs it against the golden committed in tests/render-parity/<app>.keys.
#      Exit non-zero if the golden diff shows unexpected changes.
#   3. Runs the raw-render command and diffs drydock vs raw (informational tolerance audit).
#      Fails only if the diff is non-empty after applying tolerances.
#
# Tolerances applied to the drydock-vs-raw diff:
#   (a) Helm hook resources (helm.sh/hook annotation, except crd-install).
#   (b) argocd.argoproj.io/tracking-id annotation (stripped before key extraction).
#   (c) Cluster-scoped resource kinds: namespace component blanked on BOTH sides.
#
# The golden key-set (--update / assert vs golden) is drydock-only and does NOT
# apply tolerance (c) — it captures the real drydock output for fidelity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

GOLDEN_DIR="${SCRIPT_DIR}/render-parity"

# Stable drydock cache dir. The render-cache-dir MUST be outside the repository
# root (drydock rejects an in-repo render cache). Reuse BOOTSTRAP_DRYDOCK_CACHE if
# bootstrap.sh exported it; otherwise default to the same out-of-repo XDG location.
BOOTSTRAP_DRYDOCK_CACHE="${BOOTSTRAP_DRYDOCK_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/home-ops-bootstrap-drydock}"
export BOOTSTRAP_DRYDOCK_CACHE
mkdir -p \
  "${BOOTSTRAP_DRYDOCK_CACHE}/git" \
  "${BOOTSTRAP_DRYDOCK_CACHE}/charts" \
  "${BOOTSTRAP_DRYDOCK_CACHE}/remotes" \
  "${BOOTSTRAP_DRYDOCK_CACHE}/render"

# Source render helpers (provides drydock_app, helm_template_app, write_app_values)
# shellcheck source=hack/bootstrap/lib/render.sh
source "${REPO_ROOT}/hack/bootstrap/lib/render.sh"

# Namespace-blanking allowlist for the drydock-vs-raw informational diff.
# Includes both genuinely cluster-scoped kinds AND kinds that helm templates without
# a namespace (so ArgoCD fills in the app destination namespace, causing a divergence
# in the raw comparison that is NOT a real difference):
#   - Cluster-scoped: no namespace semantically.
#   - ServiceMonitor: helm emits without .metadata.namespace; ArgoCD injects it.
# Extend here if future renders surface additional namespace-injection divergences.
NAMESPACE_TOLERANT_KINDS=(
  APIService
  ClusterIssuer
  ClusterRole
  ClusterRoleBinding
  ClusterSecretStore
  CustomResourceDefinition
  GatewayClass
  IngressClass
  MutatingWebhookConfiguration
  Namespace
  PriorityClass
  ServiceMonitor
  StorageClass
  ValidatingWebhookConfiguration
)

# _namespace_tolerant_pattern — emit an awk-compatible alternation of the kind names.
_namespace_tolerant_pattern() {
  local pattern
  pattern="$(printf '%s|' "${NAMESPACE_TOLERANT_KINDS[@]}")"
  printf '%s' "${pattern%|}"
}

# blank_tolerant_namespaces <kind-pattern>
# stdin: sorted key lines (apiVersion/kind/namespace/name)
# stdout: same lines with namespace blanked for the namespace-tolerant kinds.
#
# Key format: <apiVersion>/<kind>/<namespace>/<name>
# apiVersion may itself contain one slash (e.g. apps/v1), so we split from
# the right: name=last field, namespace=second-to-last, kind=third-to-last.
blank_tolerant_namespaces() {
  local pat="$1"
  awk -v pat="$pat" '
    {
      n = split($0, parts, "/")
      kind = parts[n-2]
      if (kind ~ ("^(" pat ")$")) {
        parts[n-1] = ""
      }
      result = parts[1]
      for (i = 2; i <= n; i++) {
        result = result "/" parts[i]
      }
      print result
    }
  '
}

# keys — stdin: multi-doc yaml -> sorted resource identity keys, hooks dropped.
# Output format: apiVersion/kind/namespace/name (namespace may be empty).
# NOTE: do NOT use yq ea here — it collapses the stream into one scalar.
#
# List-type documents (kind ending in "List", e.g. ConfigMapList) are unwrapped:
# ArgoCD expands list documents into individual resources. We run yq twice — once
# for regular documents, once for list items — and merge the results. This avoids
# spurious "---" separator lines that appear when mixing yq outputs.
keys() {
  local yaml
  yaml="$(cat -)"
  {
    # Regular (non-list) documents
    printf '%s\n' "$yaml" | yq '
      select(.kind != null)
      | select(.kind | test("List$") | not)
      | select(.metadata.annotations["helm.sh/hook"] == null
            or .metadata.annotations["helm.sh/hook"] == "crd-install")
      | [.apiVersion, .kind, (.metadata.namespace // ""), .metadata.name] | join("/")' -
    # Items from list documents
    printf '%s\n' "$yaml" | yq '
      select(.kind != null)
      | select(.kind | test("List$"))
      | .items[]
      | select(.kind != null)
      | select(.metadata.annotations["helm.sh/hook"] == null
            or .metadata.annotations["helm.sh/hook"] == "crd-install")
      | [.apiVersion, .kind, (.metadata.namespace // ""), .metadata.name] | join("/")' -
  } | grep -v '^---$' | grep . | sort
}

# apply_tolerance <kind-pattern>
# stdin: sorted key lines -> stdout: lines with cluster-scoped namespace blanked.
apply_tolerance() {
  blank_tolerant_namespaces "$1"
}

# ---- Update mode ----
BOOTSTRAP_APPS=(external-secrets cert-manager gateway argocd dragonfly-operator)

update_goldens() {
  printf 'Updating golden key-sets for all bootstrap apps...\n' >&2
  local app
  for app in "${BOOTSTRAP_APPS[@]}"; do
    printf '  [%s] running drydock_app...\n' "$app" >&2
    # Render to a temp file first so a silent empty render never clobbers a
    # committed golden (an empty golden would make assert_parity spuriously pass).
    local tmp count
    tmp="$(mktemp)"
    drydock_app "$app" | keys > "$tmp"
    count="$(wc -l < "$tmp" | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
      rm -f "$tmp"
      printf 'ERROR: [%s] drydock produced zero keys -- refusing to write an empty golden\n' "$app" >&2
      return 1
    fi
    mv "$tmp" "${GOLDEN_DIR}/${app}.keys"
    printf '  [%s] wrote %s keys\n' "$app" "$count" >&2
  done
  printf 'Golden key-sets updated in %s\n' "$GOLDEN_DIR" >&2
}

# ---- Assert mode ----
assert_parity() {
  local app="$1"
  local raw_cmd="$2"

  local golden="${GOLDEN_DIR}/${app}.keys"
  if [[ ! -f "$golden" ]]; then
    printf 'ERROR: golden key-set missing for app "%s": %s\n' "$app" "$golden" >&2
    printf 'Run render-parity.sh --update to generate it.\n' >&2
    return 1
  fi

  local pat
  pat="$(_namespace_tolerant_pattern)"

  # Step 1 — drydock side FIRST (worktree must be clean; no apps/<app>/charts present)
  printf '[%s] rendering via drydock...\n' "$app" >&2
  local drydock_keys
  drydock_keys="$(drydock_app "$app" | keys)"

  # Step 3b — assert drydock output matches committed golden
  printf '[%s] checking against golden key-set...\n' "$app" >&2
  local golden_diff
  golden_diff="$(diff \
    <(printf '%s\n' "$drydock_keys") \
    <(cat "$golden") \
    || true)"

  if [[ -n "$golden_diff" ]]; then
    printf 'FAIL [%s]: drydock output differs from committed golden:\n' "$app" >&2
    printf '%s\n' "$golden_diff" >&2
    return 1
  fi
  printf '[%s] golden: PASS\n' "$app" >&2

  # Step 2 — raw render side (may dirty worktree with apps/<app>/charts)
  printf '[%s] running raw render: %s\n' "$app" "$raw_cmd" >&2
  local raw_keys
  raw_keys="$(eval "$raw_cmd" | keys | apply_tolerance "$pat")"

  # Clean up charts extracted by kustomize --enable-helm
  rm -rf "${REPO_ROOT}/apps/${app}/charts"

  # Step 3 — informational diff: drydock vs raw (with tolerance applied to both sides)
  local drydock_keys_tolerant
  drydock_keys_tolerant="$(printf '%s\n' "$drydock_keys" | apply_tolerance "$pat")"

  local raw_diff
  raw_diff="$(diff \
    <(printf '%s\n' "$drydock_keys_tolerant") \
    <(printf '%s\n' "$raw_keys") \
    || true)"

  if [[ -n "$raw_diff" ]]; then
    printf 'FAIL [%s]: drydock vs raw diff (after tolerances) is non-empty:\n' "$app" >&2
    printf '%s\n' "$raw_diff" >&2
    return 1
  fi
  printf '[%s] drydock-vs-raw: PASS\n' "$app" >&2
}

# ---- Entry point ----
case "${1:-}" in
  --update)
    update_goldens
    ;;
  "")
    printf 'Usage: %s <app> <raw-render-cmd>\n' "$0" >&2
    printf '       %s --update\n' "$0" >&2
    exit 2
    ;;
  *)
    if [[ $# -lt 2 ]]; then
      printf 'Usage: %s <app> <raw-render-cmd>\n' "$0" >&2
      exit 2
    fi
    assert_parity "$1" "$2"
    ;;
esac
