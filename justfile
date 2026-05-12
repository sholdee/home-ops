kind_cluster := env_var_or_default("KIND_CLUSTER", "home-ops-bootstrap")
kind_context := "kind-" + kind_cluster
lima_cluster := env_var_or_default("LIMA_CLUSTER_NAME", "home-ops-k3s-test")
lima_context := "lima-" + lima_cluster
helm_api_version := "grafana.integreatly.org/v1beta1/GrafanaDashboard"
lima_app_env := "LIMA_AGENT_COUNT=3 LIMA_AGENT_CPUS=4 LIMA_AGENT_MEMORY_GIB=6 LIMA_DISK_GIB=120 LIMA_VALIDATE_APP_WAIT_SECONDS=3600"

# Show available just tasks and their descriptions.
[group('core')]
default:
    @just --list --unsorted

# Run full local validation, including pre-commit and bootstrap script tests.
[group('core')]
check:
    just pre-commit
    just bootstrap-test

# Run every pre-commit hook against the repository.
[group('core')]
pre-commit:
    pre-commit run --all-files

# Render one top-level app directory with the same Kustomize Helm settings used by CI.
[group('apps')]
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
[group('apps')]
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
[group('apps')]
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
    render="$(mktemp)"
    trap 'rm -f "${render}"; rm -rf "${dir}/charts"' EXIT
    rm -rf "${dir}/charts"
    kustomize build --enable-helm --helm-api-versions '{{ helm_api_version }}' "${dir}" > "${render}"
    set +e
    KUBECTL_EXTERNAL_DIFF="${PWD}/hack/kubectl-git-diff.sh" \
      kubectl --context "${context}" diff --server-side --field-manager=argocd-controller -f "${render}"
    status="$?"
    set -e
    if [[ "${status}" == 1 ]]; then
      exit 0
    fi
    exit "${status}"

# Run the bootstrap flow against the current kube context with confirmation.
[group('bootstrap')]
bootstrap repo='.':
    ./hack/bootstrap/bootstrap.sh --repo '{{ repo }}'

# Run the bootstrap flow against the current kube context without confirmation.
[group('bootstrap')]
bootstrap-yes repo='.':
    ./hack/bootstrap/bootstrap.sh --repo '{{ repo }}' --yes

# Server-side dry-run the bootstrap flow against the current kube context.
[group('bootstrap')]
bootstrap-dry-run repo='.':
    ./hack/bootstrap/bootstrap.sh --repo '{{ repo }}' --dry-run

# Run bootstrap against the configured kind cluster.
[group('bootstrap-kind')]
bootstrap-kind:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --yes

# Recreate the configured kind cluster and run bootstrap from scratch.
[group('bootstrap-kind')]
bootstrap-kind-fresh: kind-reset
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --yes

# Server-side dry-run bootstrap against an already bootstrapped kind cluster.
[group('bootstrap-kind')]
bootstrap-kind-dry-run:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --from-phase bootstrap-crds --dry-run --yes

# Seed only the 1Password External Secrets credential into kind.
[group('bootstrap-kind')]
bootstrap-kind-seed:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --only-phase seed-secret --yes

# Resume kind bootstrap from a specific phase.
[group('bootstrap-kind')]
bootstrap-kind-resume phase='bootstrap-crds':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --from-phase '{{ phase }}' --yes

# Audit a live cluster for bootstrap/takeover state without applying changes.
[group('bootstrap-live')]
bootstrap-live-audit context='default':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ context }}' --audit-only

# Server-side dry-run the bootstrap flow against a live cluster.
[group('bootstrap-live')]
bootstrap-live-dry-run context='default':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ context }}' --from-phase bootstrap-crds --dry-run --yes

# Server-side dry-run one bootstrap phase against a live cluster.
[group('bootstrap-live')]
bootstrap-live-phase phase context='default':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ context }}' --only-phase '{{ phase }}' --dry-run --yes

# Render live Ansible inventory and derived vars without changing nodes.
[group('bootstrap-live')]
bootstrap-live-ansible-plan:
    ./hack/bootstrap/ansible/render-inventory.sh --profile live --summary

# Import the existing live K3s server token into 1Password.
[group('bootstrap-live')]
bootstrap-ansible-import-token:
    ./hack/bootstrap/ansible/import-token.sh

# Run the live Ansible convergence wrapper.
[group('bootstrap-live')]
bootstrap-live-ansible:
    ./hack/bootstrap/ansible/run.sh --profile live

# Run the Kubernetes bootstrap phase against the live default context.
[group('bootstrap-live')]
bootstrap-live-kube context='default':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ context }}' --profile full --yes

# Run live Ansible convergence, then home-ops Kubernetes bootstrap.
[group('bootstrap-live')]
bootstrap-live-full:
    ./hack/bootstrap/ansible/run.sh --profile live --kube-bootstrap

# Show read-only node lifecycle status for a live cluster node.
[group('node-live')]
node-live-status node:
    ./hack/bootstrap/nodes/status.sh --profile live --context default '{{ node }}'

# Drain a live worker node before deletion or maintenance.
[group('node-live')]
node-live-drain node:
    ./hack/bootstrap/nodes/drain.sh --profile live --context default '{{ node }}'

# Delete a drained live worker node after Longhorn state has been evacuated.
[group('node-live')]
node-live-delete node:
    ./hack/bootstrap/nodes/delete.sh --profile live --context default '{{ node }}'

# Evict Longhorn replicas from a drained live worker before replacement.
[group('node-live')]
node-live-longhorn-evict node:
    ./hack/bootstrap/nodes/longhorn-evict.sh --profile live --context default '{{ node }}'

# Refresh a rebuilt live worker's SSH host key in known_hosts.
[group('node-live')]
node-live-refresh-ssh-host-key node:
    ./hack/bootstrap/nodes/refresh-ssh-host-key.sh --profile live '{{ node }}'

# Join a live worker from inventory with a temporary scheduling taint.
[group('node-live')]
node-live-join node:
    ./hack/bootstrap/nodes/join.sh --profile live --context default '{{ node }}'

# Remove the temporary live worker taint and restore scheduling.
[group('node-live')]
node-live-uncordon node:
    ./hack/bootstrap/nodes/uncordon.sh --profile live --context default '{{ node }}'

# Delete and recreate the configured three-node kind cluster.
[group('bootstrap-kind')]
kind-reset:
    kind delete cluster --name '{{ kind_cluster }}'
    kind create cluster --name '{{ kind_cluster }}' --config hack/bootstrap/kind-three-node.yaml

# Delete the configured kind cluster.
[group('bootstrap-kind')]
kind-delete:
    kind delete cluster --name '{{ kind_cluster }}'

# Create the configured Lima VMs for a foundation bootstrap test.
[group('bootstrap-lima')]
bootstrap-lima-create:
    ./hack/bootstrap/lima/create.sh

# Create larger Lima VMs for the app bootstrap profile.
[group('bootstrap-lima-apps')]
bootstrap-lima-create-apps:
    {{ lima_app_env }} ./hack/bootstrap/lima/create.sh

# Run the selected Ansible backend against the configured Lima VMs.
[group('bootstrap-lima')]
bootstrap-lima-ansible:
    ./hack/bootstrap/lima/run-ansible.sh

# Run the selected Ansible backend against the larger Lima app-profile VM shape.
[group('bootstrap-lima-apps')]
bootstrap-lima-ansible-apps:
    {{ lima_app_env }} ./hack/bootstrap/lima/run-ansible.sh

# Import/update the Lima K3s context in the local kubeconfig and keep its API tunnel running.
[group('bootstrap-lima')]
bootstrap-lima-kubecontext:
    ./hack/bootstrap/lima/kubecontext.sh

# Run home-ops foundation bootstrap against the Lima K3s cluster.
[group('bootstrap-lima')]
bootstrap-lima-bootstrap:
    ./hack/bootstrap/lima/bootstrap-home-ops.sh

# Run home-ops app bootstrap profile against the Lima K3s cluster.
[group('bootstrap-lima-apps')]
bootstrap-lima-bootstrap-apps:
    LIMA_BOOTSTRAP_PROFILE=lima-apps ./hack/bootstrap/lima/bootstrap-home-ops.sh

# Run Lima app bootstrap with the seed Secret manifest provided on stdin.
[group('bootstrap-lima-apps')]
bootstrap-lima-bootstrap-apps-stdin:
    LIMA_BOOTSTRAP_PROFILE=lima-apps ./hack/bootstrap/lima/bootstrap-home-ops.sh --seed-secret-stdin

# Run Lima foundation bootstrap with the seed Secret manifest provided on stdin.
[group('bootstrap-lima')]
bootstrap-lima-bootstrap-stdin:
    ./hack/bootstrap/lima/bootstrap-home-ops.sh --seed-secret-stdin

# Validate Cilium BGP APIs and backup-safety invariants in the Lima cluster.
[group('bootstrap-lima')]
bootstrap-lima-validate:
    ./hack/bootstrap/lima/validate.sh

# Validate app-profile safety invariants in the Lima cluster.
[group('bootstrap-lima-apps')]
bootstrap-lima-validate-apps:
    LIMA_VALIDATE_PROFILE=lima-apps ./hack/bootstrap/lima/validate.sh

# Delete the configured Lima VMs.
[group('bootstrap-lima')]
bootstrap-lima-delete:
    ./hack/bootstrap/lima/delete.sh

# Recreate Lima VMs, run Ansible, bootstrap home-ops, and validate foundation state.
[group('bootstrap-lima')]
bootstrap-lima-fresh: bootstrap-lima-delete bootstrap-lima-create bootstrap-lima-ansible bootstrap-lima-bootstrap bootstrap-lima-validate

# Show read-only node lifecycle status for a Lima cluster node.
[group('node-lima')]
node-lima-status node:
    ./hack/bootstrap/nodes/status.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Drain a Lima worker node before deletion or maintenance.
[group('node-lima')]
node-lima-drain node:
    ./hack/bootstrap/nodes/drain.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Delete a drained Lima worker node after Longhorn state has been evacuated.
[group('node-lima')]
node-lima-delete node:
    ./hack/bootstrap/nodes/delete.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Evict Longhorn replicas from a drained Lima worker before replacement.
[group('node-lima')]
node-lima-longhorn-evict node:
    ./hack/bootstrap/nodes/longhorn-evict.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Refresh a rebuilt Lima worker's SSH host key in known_hosts.
[group('node-lima')]
node-lima-refresh-ssh-host-key node:
    ./hack/bootstrap/nodes/refresh-ssh-host-key.sh --profile lima '{{ node }}'

# Join a Lima worker from inventory with a temporary scheduling taint.
[group('node-lima')]
node-lima-join node:
    ./hack/bootstrap/nodes/join.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Remove the temporary Lima worker taint and restore scheduling.
[group('node-lima')]
node-lima-uncordon node:
    ./hack/bootstrap/nodes/uncordon.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Recreate larger Lima VMs, run Ansible, bootstrap app profile, and validate app safety.
[group('bootstrap-lima-apps')]
bootstrap-lima-fresh-apps:
    {{ lima_app_env }} ./hack/bootstrap/lima/delete.sh
    {{ lima_app_env }} ./hack/bootstrap/lima/create.sh
    {{ lima_app_env }} ./hack/bootstrap/lima/run-ansible.sh
    LIMA_BOOTSTRAP_PROFILE=lima-apps ./hack/bootstrap/lima/bootstrap-home-ops.sh
    LIMA_VALIDATE_PROFILE=lima-apps ./hack/bootstrap/lima/validate.sh

# Audit the current kube context for bootstrap/takeover state.
[group('bootstrap')]
bootstrap-audit:
    ./hack/bootstrap/bootstrap.sh --audit-only

# Run shellcheck and offline bootstrap parsing/rendering tests.
[group('bootstrap')]
bootstrap-test:
    shellcheck hack/bootstrap/bootstrap.sh hack/bootstrap/lib/*.sh hack/bootstrap/phases/*.sh hack/bootstrap/tests/*.sh hack/bootstrap/lima/*.sh hack/bootstrap/ansible/*.sh hack/bootstrap/nodes/*.sh
    hack/bootstrap/tests/offline-parse.sh
    hack/bootstrap/tests/offline-ansible.sh
    hack/bootstrap/tests/offline-nodes.sh
