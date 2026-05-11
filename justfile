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

# Create the configured Lima VMs for a foundation bootstrap test.
bootstrap-lima-create:
    ./hack/bootstrap/lima/create.sh

# Run k3s-ansible against the configured Lima VMs.
bootstrap-lima-ansible:
    ./hack/bootstrap/lima/run-ansible.sh

# Import/update the Lima K3s context in the local kubeconfig and keep its API tunnel running.
bootstrap-lima-kubecontext:
    ./hack/bootstrap/lima/kubecontext.sh

# Run home-ops foundation bootstrap against the Lima K3s cluster.
bootstrap-lima-bootstrap:
    ./hack/bootstrap/lima/bootstrap-home-ops.sh

# Run Lima foundation bootstrap with the seed Secret manifest provided on stdin.
bootstrap-lima-bootstrap-stdin:
    ./hack/bootstrap/lima/bootstrap-home-ops.sh --seed-secret-stdin

# Validate Cilium BGP APIs and backup-safety invariants in the Lima cluster.
bootstrap-lima-validate:
    ./hack/bootstrap/lima/validate.sh

# Delete the configured Lima VMs.
bootstrap-lima-delete:
    ./hack/bootstrap/lima/delete.sh

# Recreate Lima VMs, run k3s-ansible, bootstrap home-ops, and validate foundation state.
bootstrap-lima-fresh: bootstrap-lima-delete bootstrap-lima-create bootstrap-lima-ansible bootstrap-lima-bootstrap bootstrap-lima-validate

# Audit the current kube context for bootstrap/takeover state.
bootstrap-audit:
    ./hack/bootstrap/bootstrap.sh --audit-only

# Run shellcheck and offline bootstrap parsing/rendering tests.
bootstrap-test:
    shellcheck hack/bootstrap/bootstrap.sh hack/bootstrap/lib/*.sh hack/bootstrap/phases/*.sh hack/bootstrap/tests/*.sh hack/bootstrap/lima/*.sh
    hack/bootstrap/tests/offline-parse.sh
