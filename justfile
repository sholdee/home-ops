kind_cluster := env_var_or_default("KIND_CLUSTER", "home-ops-bootstrap")
kind_context := "kind-" + kind_cluster
helm_api_version := "grafana.integreatly.org/v1beta1/GrafanaDashboard"

# Show available just tasks and their descriptions.
default:
    @just --list

# Run full local validation, including pre-commit and bootstrap script tests.
check:
    just pre-commit
    just bootstrap-test

# Run every pre-commit hook against the repository.
pre-commit:
    pre-commit run --all-files

# Render one top-level app directory with the same Kustomize Helm settings used by CI.
app-build $app:
    #!/usr/bin/env bash
    set -euo pipefail
    case "${app}" in
      ""|.*|*/*|*[^A-Za-z0-9_-]*)
        echo "ERROR: app must be a top-level directory name under apps/" >&2
        exit 2
        ;;
    esac
    dir="apps/${app}"
    if [[ ! -f "${dir}/kustomization.yaml" ]]; then
      echo "ERROR: ${dir}/kustomization.yaml does not exist" >&2
      exit 2
    fi
    trap 'rm -rf "${dir}/charts"' EXIT
    rm -rf "${dir}/charts"
    kustomize build --enable-helm --helm-api-versions '{{ helm_api_version }}' "${dir}"

# Server-side dry-run one top-level app with ArgoCD's field manager.
app-dry-run $app $context='default':
    #!/usr/bin/env bash
    set -euo pipefail
    case "${app}" in
      ""|.*|*/*|*[^A-Za-z0-9_-]*)
        echo "ERROR: app must be a top-level directory name under apps/" >&2
        exit 2
        ;;
    esac
    dir="apps/${app}"
    if [[ ! -f "${dir}/kustomization.yaml" ]]; then
      echo "ERROR: ${dir}/kustomization.yaml does not exist" >&2
      exit 2
    fi
    trap 'rm -rf "${dir}/charts"' EXIT
    rm -rf "${dir}/charts"
    kustomize build --enable-helm --helm-api-versions '{{ helm_api_version }}' "${dir}" \
      | kubectl --context "${context}" apply --server-side --dry-run=server --field-manager=argocd-controller -f -

# Diff one top-level app against a cluster using ArgoCD's field manager.
app-diff $app $context='default':
    #!/usr/bin/env bash
    set -euo pipefail
    case "${app}" in
      ""|.*|*/*|*[^A-Za-z0-9_-]*)
        echo "ERROR: app must be a top-level directory name under apps/" >&2
        exit 2
        ;;
    esac
    dir="apps/${app}"
    if [[ ! -f "${dir}/kustomization.yaml" ]]; then
      echo "ERROR: ${dir}/kustomization.yaml does not exist" >&2
      exit 2
    fi
    trap 'rm -rf "${dir}/charts"' EXIT
    rm -rf "${dir}/charts"
    kustomize build --enable-helm --helm-api-versions '{{ helm_api_version }}' "${dir}" \
      | kubectl --context "${context}" diff --server-side --field-manager=argocd-controller -f -

# Run the bootstrap flow against the current kube context with confirmation.
bootstrap repo='.':
    ./hack/bootstrap/bootstrap.sh --repo '{{ repo }}'

# Run the bootstrap flow against the current kube context without confirmation.
bootstrap-yes repo='.':
    ./hack/bootstrap/bootstrap.sh --repo '{{ repo }}' --yes

# Server-side dry-run the bootstrap flow against the current kube context.
bootstrap-dry-run repo='.':
    ./hack/bootstrap/bootstrap.sh --repo '{{ repo }}' --dry-run

# Run bootstrap against the configured kind cluster.
bootstrap-kind:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --yes

# Recreate the configured kind cluster and run bootstrap from scratch.
bootstrap-kind-fresh: kind-reset
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --yes

# Server-side dry-run bootstrap against an already bootstrapped kind cluster.
bootstrap-kind-dry-run:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --from-phase bootstrap-crds --dry-run --yes

# Seed only the 1Password External Secrets credential into kind.
bootstrap-kind-seed:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --only-phase seed-secret --yes

# Resume kind bootstrap from a specific phase.
bootstrap-kind-resume phase='bootstrap-crds':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --from-phase '{{ phase }}' --yes

# Audit a live cluster for bootstrap/takeover state without applying changes.
bootstrap-live-audit context='default':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ context }}' --audit-only

# Server-side dry-run the bootstrap flow against a live cluster.
bootstrap-live-dry-run context='default':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ context }}' --from-phase bootstrap-crds --dry-run --yes

# Server-side dry-run one bootstrap phase against a live cluster.
bootstrap-live-phase phase context='default':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ context }}' --only-phase '{{ phase }}' --dry-run --yes

# Delete and recreate the configured three-node kind cluster.
kind-reset:
    kind delete cluster --name '{{ kind_cluster }}'
    kind create cluster --name '{{ kind_cluster }}' --config hack/bootstrap/kind-three-node.yaml

# Delete the configured kind cluster.
kind-delete:
    kind delete cluster --name '{{ kind_cluster }}'

# Audit the current kube context for bootstrap/takeover state.
bootstrap-audit:
    ./hack/bootstrap/bootstrap.sh --audit-only

# Run shellcheck and offline bootstrap parsing/rendering tests.
bootstrap-test:
    shellcheck hack/bootstrap/bootstrap.sh hack/bootstrap/lib/*.sh hack/bootstrap/phases/*.sh hack/bootstrap/tests/*.sh
    hack/bootstrap/tests/offline-parse.sh
