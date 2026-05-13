#!/usr/bin/env bats
# shellcheck shell=bash

load '../helpers/common.bash'

setup_file() {
  require_tools yq kustomize
}

@test "argocd app manifests expose expected chart/application sources" {
  [[ "$(yq -r 'select(.kind == "Application" and .metadata.name == "dragonfly-operator") | .spec.source.chart' "$ROOT/apps/argocd/manifests/apps.yaml")" == "dragonfly-operator" ]]
  [[ "$(yq -r 'select(.kind == "Application" and .metadata.name == "grafana-operator") | .spec.source.chart' "$ROOT/apps/argocd/manifests/apps.yaml")" == "grafana-operator" ]]
  [[ "$(yq -r 'select(.kind == "ApplicationSet" and .metadata.name == "k3s-apps") | .spec.generators[0].git.directories[0].path' "$ROOT/apps/argocd/manifests/app-set.yaml")" == "apps/*" ]]
  [[ "$(yq -r '.helmCharts[] | select(.name == "argo-cd") | .version' "$ROOT/apps/argocd/kustomization.yaml")" != "null" ]]
  [[ "$(yq -r '.helmCharts[] | select(.name == "external-secrets") | .version' "$ROOT/apps/external-secrets/kustomization.yaml")" != "null" ]]
  [[ "$(yq -r '.helmCharts[] | select(.name == "gateway-helm") | .version' "$ROOT/apps/envoy-gateway-system/kustomization.yaml")" != "null" ]]
  [[ "$(yq -r '.helmCharts[] | select(.name == "kube-prometheus-stack") | .version' "$ROOT/apps/monitoring/kustomization.yaml")" != "null" ]]
}

@test "lima app bootstrap removes active CNPG plugins instead of only disabling WAL archiving" {
  assert_file_not_contains "$ROOT/hack/bootstrap/lima/apps.sh" '/spec/plugins/0/isWALArchiver'
  assert_file_contains "$ROOT/hack/bootstrap/lima/apps.sh" 'path: /spec/plugins'
  assert_file_contains "$ROOT/hack/bootstrap/lima/apps.sh" 'lima-deny-cnpg-active-plugins'
  assert_file_contains "$ROOT/hack/bootstrap/lima/apps.sh" 'object.spec.plugins.size() == 0'
  assert_file_contains "$ROOT/hack/bootstrap/lima/validate.sh" 'CNPG active Cluster plugin exists'
}

@test "CNPG scheduled backups target primary" {
  local file bad_count
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
      return 1
    }
  done < <(find "$ROOT/apps" -path '*/charts/*' -prune -o -name '*.yaml' -type f -print)
}

@test "dragonfly component can be patched for ArgoCD authentication" {
  local tmp
  tmp="$BATS_TEST_TMPDIR/kustomize"
  mkdir -p "$tmp"
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

  run kustomize build --load-restrictor LoadRestrictionsNone "$tmp"
  assert_success
}
