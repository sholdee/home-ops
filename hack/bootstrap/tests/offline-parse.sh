#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing tool: $1" >&2
    exit 1
  }
}

require yq
require kustomize

test "$(yq -r 'select(.kind == "Application" and .metadata.name == "dragonfly-operator") | .spec.source.chart' "$ROOT/apps/argocd/manifests/apps.yaml")" = "dragonfly-operator"
test "$(yq -r 'select(.kind == "Application" and .metadata.name == "grafana-operator") | .spec.source.chart' "$ROOT/apps/argocd/manifests/apps.yaml")" = "grafana-operator"
test "$(yq -r 'select(.kind == "ApplicationSet" and .metadata.name == "k3s-apps") | .spec.generators[0].git.directories[0].path' "$ROOT/apps/argocd/manifests/app-set.yaml")" = "apps/*"
test "$(yq -r '.helmCharts[] | select(.name == "argo-cd") | .version' "$ROOT/apps/argocd/kustomization.yaml")" != "null"
test "$(yq -r '.helmCharts[] | select(.name == "external-secrets") | .version' "$ROOT/apps/external-secrets/kustomization.yaml")" != "null"
test "$(yq -r '.helmCharts[] | select(.name == "gateway-helm") | .version' "$ROOT/apps/envoy-gateway-system/kustomization.yaml")" != "null"
test "$(yq -r '.helmCharts[] | select(.name == "kube-prometheus-stack") | .version' "$ROOT/apps/monitoring/kustomization.yaml")" != "null"

if grep -q '/spec/plugins/0/isWALArchiver' "$ROOT/hack/bootstrap/phases/wait-argocd.sh"; then
  echo "lima-apps CNPG restore patches must remove active Cluster plugins instead of only disabling WAL archiving" >&2
  exit 1
fi

grep -q 'path: /spec/plugins' "$ROOT/hack/bootstrap/phases/wait-argocd.sh"
grep -q 'lima-deny-cnpg-active-plugins' "$ROOT/hack/bootstrap/phases/wait-argocd.sh"
grep -q 'object.spec.plugins.size() == 0' "$ROOT/hack/bootstrap/phases/wait-argocd.sh"
grep -q 'CNPG active Cluster plugin exists' "$ROOT/hack/bootstrap/lima/validate.sh"

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  bad_count="$(
    yq ea -r '
      [.[] | select(type == "!!map") | select(.kind == "ScheduledBackup" and .apiVersion == "postgresql.cnpg.io/v1" and .spec.target != "primary")]
      | length
    ' "$file"
  )"
  [[ "$bad_count" == "0" ]] || {
    echo "ScheduledBackup resources must set spec.target: primary: $file" >&2
    exit 1
  }
done < <(find "$ROOT/apps" -path '*/charts/*' -prune -o -name '*.yaml' -type f -print)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - $ROOT/apps/argocd/manifests/namespace.yaml
  - $ROOT/components/dragonfly/dragonfly.yaml
patches:
  - target:
      group: dragonflydb.io
      version: v1alpha1
      kind: Dragonfly
      name: dragonfly
    patch: |-
      - op: add
        path: /spec/authentication
        value:
          passwordFromSecret:
            name: argocd-dragonfly-auth
            key: redis-password
EOF

kustomize build --load-restrictor LoadRestrictionsNone "$tmp" >/dev/null
echo "offline parse test passed"
