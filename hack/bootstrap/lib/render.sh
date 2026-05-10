#!/usr/bin/env bash

chart_value() {
  local file="$1"
  local chart_name="$2"
  local expr="$3"
  yq -r ".helmCharts[] | select(.name == \"${chart_name}\") | ${expr}" "$file"
}

app_value() {
  local app_name="$1"
  local expr="$2"
  yq -r "select(.kind == \"Application\" and .metadata.name == \"${app_name}\") | ${expr}" \
    "${REPO_ROOT}/apps/argocd/manifests/apps.yaml"
}

render_kustomize_app() {
  local app_path="$1"
  kustomize build --enable-helm "${REPO_ROOT}/${app_path}"
}

is_oci_repo() {
  local repo="$1"
  [[ "$repo" == oci://* || "$repo" == ghcr.io/* ]]
}

helm_repo_args() {
  local repo="$1"
  if [[ "$repo" == oci://* ]]; then
    return 0
  fi
  printf -- '--repo\n%s\n' "$repo"
}

helm_chart_ref() {
  local repo="$1"
  local chart="$2"
  if [[ "$repo" == oci://* ]]; then
    printf '%s/%s' "$repo" "$chart"
  elif [[ "$repo" == ghcr.io/* ]]; then
    printf 'oci://%s/%s' "$repo" "$chart"
  else
    printf '%s' "$chart"
  fi
}

helm_show_crds() {
  local chart="$1"
  local repo="$2"
  local version="$3"
  local ref
  ref="$(helm_chart_ref "$repo" "$chart")"
  if is_oci_repo "$repo"; then
    helm show crds "$ref" --version "$version"
  else
    helm show crds "$ref" --repo "$repo" --version "$version"
  fi
}

helm_template_crds() {
  local release="$1"
  local chart="$2"
  local repo="$3"
  local version="$4"
  local namespace="$5"
  local values_file="${6:-}"
  local ref args
  ref="$(helm_chart_ref "$repo" "$chart")"

  args=(template "$release" "$ref" --version "$version" --namespace "$namespace")
  if ! is_oci_repo "$repo"; then
    args+=(--repo "$repo")
  fi
  if [[ -n "$values_file" ]]; then
    args+=(-f "$values_file")
  fi

  helm "${args[@]}" | yq 'select(.kind == "CustomResourceDefinition")'
}

helm_template_chart() {
  local release="$1"
  local chart="$2"
  local repo="$3"
  local version="$4"
  local namespace="$5"
  local values_file="$6"
  local ref
  ref="$(helm_chart_ref "$repo" "$chart")"

  if is_oci_repo "$repo"; then
    helm template "$release" "$ref" --version "$version" --namespace "$namespace" --no-hooks -f "$values_file"
  else
    helm template "$release" "$chart" --repo "$repo" --version "$version" --namespace "$namespace" --no-hooks -f "$values_file"
  fi
}

helm_template_kustomization_chart() {
  local file="$1"
  local chart_name="$2"
  local chart repo version release namespace values_rel values_file file_dir
  chart="$(chart_value "$file" "$chart_name" '.name')"
  repo="$(chart_value "$file" "$chart_name" '.repo')"
  version="$(chart_value "$file" "$chart_name" '.version')"
  release="$(chart_value "$file" "$chart_name" '.releaseName')"
  namespace="$(chart_value "$file" "$chart_name" '.namespace')"
  values_rel="$(chart_value "$file" "$chart_name" '.valuesFile')"
  file_dir="$(cd "$(dirname "$file")" && pwd)"
  if [[ "$values_rel" == /* ]]; then
    values_file="$values_rel"
  else
    values_file="${file_dir}/${values_rel}"
  fi

  helm_template_chart "$release" "$chart" "$repo" "$version" "$namespace" "$values_file"
}

helm_template_app() {
  local app_name="$1"
  local values_file="$2"
  local chart repo version release namespace
  chart="$(app_value "$app_name" '.spec.source.chart')"
  repo="$(app_value "$app_name" '.spec.source.repoURL')"
  version="$(app_value "$app_name" '.spec.source.targetRevision')"
  release="$(app_value "$app_name" '.spec.source.helm.releaseName // .metadata.name')"
  namespace="$(app_value "$app_name" '.spec.destination.namespace')"
  helm_template_chart "$release" "$chart" "$repo" "$version" "$namespace" "$values_file"
}

write_app_values() {
  local app_name="$1"
  local output="$2"
  yq "select(.kind == \"Application\" and .metadata.name == \"${app_name}\") | .spec.source.helm.valuesObject // {}" \
    "${REPO_ROOT}/apps/argocd/manifests/apps.yaml" > "$output"
}

write_cert_manager_chart_overlay() {
  local dir="$1"
  local version repo
  version="$(chart_value "${REPO_ROOT}/apps/cert-manager/kustomization.yaml" cert-manager '.version')"
  repo="$(chart_value "${REPO_ROOT}/apps/cert-manager/kustomization.yaml" cert-manager '.repo')"
  cat > "${dir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cert-manager
resources:
  - ${REPO_ROOT}/apps/cert-manager/manifests/namespace.yaml
helmCharts:
  - name: cert-manager
    repo: ${repo}
    version: ${version}
    releaseName: cert-manager
    namespace: cert-manager
    valuesFile: ${REPO_ROOT}/apps/cert-manager/manifests/values.yaml
EOF
}

write_argocd_dependencies_overlay() {
  local dir="$1"
  cat > "${dir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - ${REPO_ROOT}/apps/argocd/manifests/namespace.yaml
  - ${REPO_ROOT}/apps/argocd/manifests/externalsecret.yaml
  - ${REPO_ROOT}/apps/argocd/manifests/dragonfly-operator-rbac.yaml
  - ${REPO_ROOT}/components/dragonfly/dragonfly.yaml
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
}
