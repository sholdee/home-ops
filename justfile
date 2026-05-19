kind_cluster := env_var_or_default("KIND_CLUSTER", "home-ops-bootstrap")
kind_context := "kind-" + kind_cluster
lima_cluster := env_var_or_default("LIMA_CLUSTER_NAME", "home-ops-k3s-test")
lima_context := "lima-" + lima_cluster
helm_api_version := "grafana.integreatly.org/v1beta1/GrafanaDashboard"
lima_longhorn_env := "LIMA_SERVER_COUNT=" + env_var_or_default("LIMA_SERVER_COUNT", "3") + " LIMA_AGENT_COUNT=" + env_var_or_default("LIMA_AGENT_COUNT", "1") + " LIMA_K3S_MASTER_TAINT=" + env_var_or_default("LIMA_K3S_MASTER_TAINT", "false") + " LIMA_SERVER_CPUS=" + env_var_or_default("LIMA_SERVER_CPUS", "3") + " LIMA_AGENT_CPUS=" + env_var_or_default("LIMA_AGENT_CPUS", "3") + " LIMA_SERVER_MEMORY_GIB=" + env_var_or_default("LIMA_SERVER_MEMORY_GIB", "4") + " LIMA_AGENT_MEMORY_GIB=" + env_var_or_default("LIMA_AGENT_MEMORY_GIB", "4") + " LIMA_DISK_GIB=" + env_var_or_default("LIMA_DISK_GIB", "80") + " LIMA_VALIDATE_APP_WAIT_SECONDS=" + env_var_or_default("LIMA_VALIDATE_APP_WAIT_SECONDS", "2400")
lima_app_env := "LIMA_SERVER_COUNT=" + env_var_or_default("LIMA_SERVER_COUNT", "3") + " LIMA_AGENT_COUNT=" + env_var_or_default("LIMA_AGENT_COUNT", "1") + " LIMA_K3S_MASTER_TAINT=" + env_var_or_default("LIMA_K3S_MASTER_TAINT", "false") + " LIMA_SERVER_CPUS=" + env_var_or_default("LIMA_SERVER_CPUS", "3") + " LIMA_AGENT_CPUS=" + env_var_or_default("LIMA_AGENT_CPUS", "3") + " LIMA_SERVER_MEMORY_GIB=" + env_var_or_default("LIMA_SERVER_MEMORY_GIB", "5") + " LIMA_AGENT_MEMORY_GIB=" + env_var_or_default("LIMA_AGENT_MEMORY_GIB", "5") + " LIMA_DISK_GIB=" + env_var_or_default("LIMA_DISK_GIB", "120") + " LIMA_VALIDATE_APP_WAIT_SECONDS=" + env_var_or_default("LIMA_VALIDATE_APP_WAIT_SECONDS", "3600")

# Show available just tasks and their descriptions.
[group('core')]
default:
    @just --list --unsorted

# Run full local validation, including pre-commit, GitHub script tests, and bootstrap script tests.
[group('core')]
check:
    just pre-commit
    just github-test
    just bootstrap-test

# Run every pre-commit hook against the repository.
[group('core')]
pre-commit:
    pre-commit run --all-files

# Run lightweight tests for GitHub workflow helper scripts.
[group('core')]
github-test:
    python3 -B .github/scripts/test_extract_image_info.py

# Show current and target cluster status without mutating anything.
[group('cluster')]
context context='':
    #!/usr/bin/env bash
    set -euo pipefail
    current="$(kubectl config current-context 2>/dev/null || true)"
    target='{{ context }}'
    if [[ -z "${target}" ]]; then
      target="${current}"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
    printf 'current_context: '
    if [[ -n "${current}" ]]; then
      printf '%s\n' "${current}"
    else
      printf 'unavailable\n'
    fi
    printf 'target_context: %s\n\n' "${target}"
    kubectl --context "${target}" get nodes -o wide
    printf '\nargocd_applications:\n'
    if ! kubectl --context "${target}" -n argocd get applications.argoproj.io -o wide; then
      printf 'ArgoCD applications unavailable\n'
    fi

# List ArgoCD Applications, or one named Application, in a target context.
[group('argocd')]
argocd-apps app='' context='':
    #!/usr/bin/env bash
    set -euo pipefail
    app={{ quote(app) }}
    target={{ quote(context) }}
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
    if [[ -n "${app}" ]]; then
      kubectl --context "${target}" -n argocd get "application/${app}" -o wide
    else
      kubectl --context "${target}" -n argocd get applications.argoproj.io -o wide
    fi

# List ArgoCD ApplicationSets, or one named ApplicationSet, in a target context.
[group('argocd')]
argocd-appsets appset='' context='':
    #!/usr/bin/env bash
    set -euo pipefail
    appset={{ quote(appset) }}
    target={{ quote(context) }}
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
    if [[ -n "${appset}" ]]; then
      kubectl --context "${target}" -n argocd get "applicationset/${appset}" -o wide
    else
      kubectl --context "${target}" -n argocd get applicationsets.argoproj.io -o wide
    fi

# Show sync, health, revision, operation, and conditions for ArgoCD Applications.
[group('argocd')]
argocd-status app='' context='':
    #!/usr/bin/env bash
    set -euo pipefail
    app={{ quote(app) }}
    target={{ quote(context) }}
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
    if [[ -z "${app}" ]]; then
      kubectl --context "${target}" -n argocd get applications.argoproj.io \
        --sort-by=.metadata.name \
        -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,OPERATION:.status.operationState.phase'
      exit 0
    fi
    kubectl --context "${target}" -n argocd get "application/${app}" -o json | jq -r '
      def val($v): if $v == null or $v == "" then "unknown" else $v end;
      "name: \(.metadata.name)",
      "sync: \(val(.status.sync.status))",
      "health: \(val(.status.health.status))",
      "revision: \(val(.status.sync.revision))",
      "operation: \(val(.status.operationState.phase))",
      (if .status.operationState.message then "message: \(.status.operationState.message)" else empty end),
      (if ((.status.conditions // []) | length) > 0 then "conditions:" else empty end),
      (.status.conditions // [] | .[] | "- \(.type): \(.message)")
    '

# Ask ArgoCD to refresh one Application through the normal refresh annotation.
[group('argocd')]
argocd-refresh app context='':
    #!/usr/bin/env bash
    set -euo pipefail
    app={{ quote(app) }}
    target={{ quote(context) }}
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
    kubectl --context "${target}" -n argocd annotate "application/${app}" \
      argocd.argoproj.io/refresh=normal --overwrite

# Ask ArgoCD to discard cache and hard-refresh one Application.
[group('argocd')]
argocd-hard-refresh app context='':
    #!/usr/bin/env bash
    set -euo pipefail
    app={{ quote(app) }}
    target={{ quote(context) }}
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
    kubectl --context "${target}" -n argocd annotate "application/${app}" \
      argocd.argoproj.io/refresh=hard --overwrite

# Request a controller-side sync for one ArgoCD Application.
[group('argocd')]
argocd-sync app context='':
    #!/usr/bin/env bash
    set -euo pipefail
    app={{ quote(app) }}
    target={{ quote(context) }}
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
    kubectl --context "${target}" -n argocd patch "application/${app}" \
      --type=merge \
      -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'

# Wait for one ArgoCD Application to become Synced and Healthy.
[group('argocd')]
argocd-wait app context='' timeout='10m':
    #!/usr/bin/env bash
    set -euo pipefail
    app={{ quote(app) }}
    target={{ quote(context) }}
    timeout={{ quote(timeout) }}
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
    kubectl --context "${target}" -n argocd wait "application/${app}" \
      --for=jsonpath='{.status.sync.status}'=Synced \
      --timeout="${timeout}"
    kubectl --context "${target}" -n argocd wait "application/${app}" \
      --for=jsonpath='{.status.health.status}'=Healthy \
      --timeout="${timeout}"

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
app-dry-run $app $context='':
    #!/usr/bin/env bash
    set -euo pipefail
    target="${context}"
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
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
      | kubectl --context "${target}" apply --server-side --dry-run=server --field-manager=argocd-controller -f -

# Diff one top-level app against a cluster using ArgoCD's field manager.
[group('apps')]
app-diff $app $context='':
    #!/usr/bin/env bash
    set -euo pipefail
    target="${context}"
    if [[ -z "${target}" ]]; then
      target="$(kubectl config current-context 2>/dev/null || true)"
    fi
    if [[ -z "${target}" ]]; then
      echo "ERROR: no target context provided and no current kube context is set" >&2
      exit 2
    fi
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
      kubectl --context "${target}" diff --server-side --field-manager=argocd-controller -f "${render}"
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
    ./hack/bootstrap/bootstrap.sh --repo '{{ repo }}' --from-phase bootstrap-crds --dry-run --yes

# Server-side dry-run one bootstrap phase against the current kube context.
[group('bootstrap')]
bootstrap-phase phase repo='.':
    ./hack/bootstrap/bootstrap.sh --repo '{{ repo }}' --only-phase '{{ phase }}' --dry-run --yes

# Show best-effort status for the configured kind cluster.
[group('kind')]
kind-status:
    #!/usr/bin/env bash
    set -euo pipefail
    printf 'kind_clusters:\n'
    if ! kind get clusters; then
      printf 'kind clusters unavailable\n'
    fi
    printf '\nnodes ({{ kind_context }}):\n'
    if ! kubectl --context '{{ kind_context }}' get nodes -o wide; then
      printf 'nodes unavailable\n'
    fi
    printf '\nargocd_applications ({{ kind_context }}):\n'
    if ! kubectl --context '{{ kind_context }}' -n argocd get applications.argoproj.io -o wide; then
      printf 'ArgoCD applications unavailable\n'
    fi

# Create the configured kind cluster.
[group('kind')]
kind-create:
    kind create cluster --name '{{ kind_cluster }}' --config hack/bootstrap/kind-three-node.yaml

# Run bootstrap against the configured kind cluster.
[group('kind')]
kind-bootstrap:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --yes

# Seed only the 1Password External Secrets credential into kind.
[group('kind')]
kind-bootstrap-seed:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --only-phase seed-secret --yes

# Resume kind bootstrap from a specific phase.
[group('kind')]
kind-bootstrap-resume phase='bootstrap-crds':
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --from-phase '{{ phase }}' --yes

# Server-side dry-run bootstrap against an already bootstrapped kind cluster.
[group('kind')]
kind-bootstrap-dry-run:
    ./hack/bootstrap/bootstrap.sh --kube-context '{{ kind_context }}' --from-phase bootstrap-crds --dry-run --yes

# Delete, recreate, and bootstrap the configured kind cluster.
[group('kind')]
kind-fresh: kind-delete kind-create kind-bootstrap

# Render live Ansible inventory and derived vars without changing nodes.
[group('ansible')]
ansible-plan:
    ./hack/bootstrap/ansible/render-inventory.sh --profile live --summary

# Import the existing live K3s server token into 1Password.
[group('ansible')]
ansible-import-token:
    ./hack/bootstrap/ansible/import-token.sh

# Run the live Ansible convergence wrapper.
[group('ansible')]
ansible-run:
    ./hack/bootstrap/ansible/run.sh --profile live

# Run live Ansible convergence, then home-ops Kubernetes bootstrap.
[group('ansible')]
ansible-bootstrap:
    ./hack/bootstrap/ansible/run.sh --profile live --kube-bootstrap

# Converge host-level services on one live inventory node without touching Kubernetes workloads.
[group('ansible')]
ansible-host-services node:
    ./hack/bootstrap/ansible/host-services.sh '{{ node }}'

# Show read-only node lifecycle status for a live cluster node.
[group('node')]
node-status node:
    ./hack/bootstrap/nodes/status.sh --profile live --context default '{{ node }}'

# List live cluster nodes.
[group('node')]
node-list:
    kubectl --context default get nodes -o wide

# List non-succeeded pods bound to a live cluster node.
[group('node')]
node-pods node:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl --context default get pods -A --field-selector 'spec.nodeName={{ node }},status.phase!=Succeeded' -o wide

# Run one SSH command against a live inventory node without implicit sudo.
[group('node-mutate')]
node-cmd node +command:
    ./hack/bootstrap/nodes/cmd.sh --profile live '{{ node }}' -- {{ quote(command) }}

# Show read-only control-plane quorum and embedded-etcd status for a live cluster node.
[group('node')]
node-control-plane-status node:
    ./hack/bootstrap/nodes/control-plane-status.sh --profile live --context default '{{ node }}'

# Run read-only control-plane delete preflight for a live cluster node.
[group('node')]
node-control-plane-delete-preflight node:
    ./hack/bootstrap/nodes/control-plane-delete-preflight.sh --profile live --context default '{{ node }}'

# Discover Raspberry Pi and target-disk identity needed before network reimage.
[group('node-reimage')]
node-reimage-plan node:
    ./hack/bootstrap/nodes/reimage-plan.sh --profile live --context default '{{ node }}'

# Render image metadata JSON expected by network reimage staging.
[group('node-reimage-primitive')]
node-reimage-metadata node image_url sha256:
    @./hack/bootstrap/nodes/reimage-metadata.sh --profile live '{{ node }}' '{{ image_url }}' '{{ sha256 }}'

# Render a per-node rpi-image-gen source tree for a Raspberry Pi OS image.
[group('node-reimage-primitive')]
node-reimage-image-source node +args='':
    ./hack/bootstrap/nodes/reimage-image-source.sh --profile live '{{ node }}' {{ args }}

# Build a per-node Raspberry Pi OS image through the supported reimage builder.
[group('node-reimage')]
node-reimage-build node +args='':
    ./hack/bootstrap/nodes/reimage-build.sh --profile live '{{ node }}' {{ args }}

# Run the full live reimage flow through join, leaving final uncordon to the operator.
[group('node-reimage')]
node-reimage-full node:
    ./hack/bootstrap/nodes/reimage-full.sh --profile live --context default '{{ node }}'

# Plan additive-only live node convergence from inventory.
[group('node')]
node-converge-plan:
    ./hack/bootstrap/nodes/converge.sh --profile live --context default --plan

# Drain a live worker or control-plane node before deletion or maintenance.
[group('node-mutate')]
node-drain node:
    ./hack/bootstrap/nodes/drain.sh --profile live --context default '{{ node }}'

# Reboot a drained live worker or control-plane node and wait for it to return Ready.
[group('node-mutate')]
node-reboot node:
    ./hack/bootstrap/nodes/reboot.sh --profile live --context default '{{ node }}'

# Delete a drained live worker or control-plane node after Longhorn state has been evacuated.
[group('node-mutate')]
node-delete node:
    ./hack/bootstrap/nodes/delete.sh --profile live --context default '{{ node }}'

# Evict Longhorn replicas from a drained live node before replacement.
[group('node-mutate')]
node-longhorn-evict node:
    ./hack/bootstrap/nodes/longhorn-evict.sh --profile live --context default '{{ node }}'

# Refresh a rebuilt live inventory host's SSH host key in known_hosts.
[group('node-mutate')]
node-refresh-ssh-host-key node:
    ./hack/bootstrap/nodes/refresh-ssh-host-key.sh --profile live '{{ node }}'

# Join a live worker or control-plane node from inventory with a temporary scheduling taint.
[group('node-mutate')]
node-join node:
    ./hack/bootstrap/nodes/join.sh --profile live --context default '{{ node }}'

# Remove the temporary live node taint and restore scheduling.
[group('node-mutate')]
node-uncordon node:
    ./hack/bootstrap/nodes/uncordon.sh --profile live --context default '{{ node }}'

# Stage a one-shot Raspberry Pi network reimage payload for a deleted live node.
[group('node-reimage-primitive')]
node-reimage-stage node image_url sha256 +args='':
    ./hack/bootstrap/nodes/reimage-stage.sh --profile live --context default '{{ node }}' '{{ image_url }}' '{{ sha256 }}' {{ args }}

# Reboot a staged live node into one-shot Raspberry Pi tryboot reimage mode.
[group('node-reimage-primitive')]
node-reimage-reboot node +args='':
    ./hack/bootstrap/nodes/reimage-reboot.sh --profile live --context default '{{ node }}' {{ args }}

# Serve a recorded reimage artifact from a healthy live inventory host.
[group('node-reimage')]
node-reimage-serve node host +args='':
    ./hack/bootstrap/nodes/reimage-serve.sh --profile live '{{ node }}' '{{ host }}' {{ args }}

# Stage, tryboot reboot, wait for SSH, and refresh host key from recorded serve state.
[group('node-reimage')]
node-reimage-apply node +args='':
    ./hack/bootstrap/nodes/reimage-apply.sh --profile live --context default '{{ node }}' {{ args }}

# Stop the recorded node-specific image server and remove remote temp files.
[group('node-reimage')]
node-reimage-cleanup node +args='':
    ./hack/bootstrap/nodes/reimage-cleanup.sh --profile live '{{ node }}' {{ args }}

# Run prompted additive-only live node convergence from inventory.
[group('node-mutate')]
node-converge:
    ./hack/bootstrap/nodes/converge.sh --profile live --context default

# Delete the configured kind cluster.
[group('kind')]
kind-delete:
    kind delete cluster --name '{{ kind_cluster }}'

# Show best-effort status for the configured Lima cluster.
[group('lima')]
lima-status:
    #!/usr/bin/env bash
    set -euo pipefail
    cluster='{{ lima_cluster }}'
    printf 'lima_instances (%s):\n' "${cluster}"
    if command -v limactl >/dev/null 2>&1; then
      if ! limactl list | awk -v cluster="${cluster}" 'NR == 1 || $1 ~ "^" cluster "-(server|agent)-[0-9]+$"'; then
        printf 'lima instances unavailable\n'
      fi
    else
      printf 'limactl unavailable\n'
    fi
    printf '\nnodes ({{ lima_context }}):\n'
    if ! kubectl --context '{{ lima_context }}' get nodes -o wide; then
      printf 'nodes unavailable\n'
    fi
    printf '\nargocd_applications ({{ lima_context }}):\n'
    if ! kubectl --context '{{ lima_context }}' -n argocd get applications.argoproj.io -o wide; then
      printf 'ArgoCD applications unavailable\n'
    fi

# Create the configured Lima VMs for a foundation bootstrap test.
[group('lima')]
lima-create:
    ./hack/bootstrap/lima/create.sh

# Run the selected Ansible backend against the configured Lima VMs.
[group('lima')]
lima-ansible:
    ./hack/bootstrap/lima/run-ansible.sh

# Import/update the Lima K3s context in the local kubeconfig and keep its API tunnel running.
[group('lima')]
lima-context:
    ./hack/bootstrap/lima/kubecontext.sh

# Run home-ops foundation bootstrap against the Lima K3s cluster.
[group('lima')]
lima-bootstrap:
    ./hack/bootstrap/lima/bootstrap-home-ops.sh

# Run Lima foundation bootstrap with the seed Secret manifest provided on stdin.
[group('lima')]
lima-bootstrap-stdin:
    ./hack/bootstrap/lima/bootstrap-home-ops.sh --seed-secret-stdin

# Validate Cilium BGP APIs and backup-safety invariants in the Lima cluster.
[group('lima')]
lima-validate:
    ./hack/bootstrap/lima/validate.sh

# Delete the configured Lima VMs.
[group('lima')]
lima-delete:
    ./hack/bootstrap/lima/delete.sh

# Recreate Lima VMs, run Ansible, bootstrap home-ops, and validate foundation state.
[group('lima')]
lima-fresh: lima-delete lima-create lima-ansible lima-bootstrap lima-validate

# Show best-effort status for the configured Lima Longhorn test cluster.
[group('lima-longhorn')]
lima-longhorn-status: lima-status

# Create Longhorn-focused Lima VMs for storage lifecycle testing.
[group('lima-longhorn')]
lima-longhorn-create:
    {{ lima_longhorn_env }} ./hack/bootstrap/lima/create.sh

# Run the selected Ansible backend against the Longhorn-focused VM shape.
[group('lima-longhorn')]
lima-longhorn-ansible:
    {{ lima_longhorn_env }} ./hack/bootstrap/lima/run-ansible.sh

# Run home-ops Longhorn-focused bootstrap profile against the Lima K3s cluster.
[group('lima-longhorn')]
lima-longhorn-bootstrap:
    LIMA_BOOTSTRAP_PROFILE=lima-longhorn ./hack/bootstrap/lima/bootstrap-home-ops.sh

# Run Lima Longhorn bootstrap with the seed Secret manifest provided on stdin.
[group('lima-longhorn')]
lima-longhorn-bootstrap-stdin:
    LIMA_BOOTSTRAP_PROFILE=lima-longhorn ./hack/bootstrap/lima/bootstrap-home-ops.sh --seed-secret-stdin

# Validate Longhorn-focused safety and checksum workload invariants.
[group('lima-longhorn')]
lima-longhorn-validate:
    LIMA_VALIDATE_PROFILE=lima-longhorn ./hack/bootstrap/lima/validate.sh

# Delete the configured Lima Longhorn test VMs.
[group('lima-longhorn')]
lima-longhorn-delete: lima-delete

# Recreate Longhorn-focused Lima VMs, bootstrap Longhorn, and validate the checksum workload.
[group('lima-longhorn')]
lima-longhorn-fresh:
    {{ lima_longhorn_env }} ./hack/bootstrap/lima/delete.sh
    {{ lima_longhorn_env }} ./hack/bootstrap/lima/create.sh
    {{ lima_longhorn_env }} ./hack/bootstrap/lima/run-ansible.sh
    LIMA_BOOTSTRAP_PROFILE=lima-longhorn ./hack/bootstrap/lima/bootstrap-home-ops.sh
    LIMA_VALIDATE_PROFILE=lima-longhorn ./hack/bootstrap/lima/validate.sh

# Show best-effort status for the configured Lima app-profile cluster.
[group('lima-apps')]
lima-apps-status: lima-status

# Create app-profile Lima VMs for workload, Longhorn, and node lifecycle testing.
[group('lima-apps')]
lima-apps-create:
    {{ lima_app_env }} ./hack/bootstrap/lima/create.sh

# Run the selected Ansible backend against the Lima app-profile VM shape.
[group('lima-apps')]
lima-apps-ansible:
    {{ lima_app_env }} ./hack/bootstrap/lima/run-ansible.sh

# Run home-ops app bootstrap profile against the Lima K3s cluster.
[group('lima-apps')]
lima-apps-bootstrap:
    LIMA_BOOTSTRAP_PROFILE=lima-apps ./hack/bootstrap/lima/bootstrap-home-ops.sh

# Run Lima app bootstrap with the seed Secret manifest provided on stdin.
[group('lima-apps')]
lima-apps-bootstrap-stdin:
    LIMA_BOOTSTRAP_PROFILE=lima-apps ./hack/bootstrap/lima/bootstrap-home-ops.sh --seed-secret-stdin

# Validate app-profile safety invariants in the Lima cluster.
[group('lima-apps')]
lima-apps-validate:
    LIMA_VALIDATE_PROFILE=lima-apps ./hack/bootstrap/lima/validate.sh

# Delete the configured Lima app-profile VMs.
[group('lima-apps')]
lima-apps-delete: lima-delete

# Show read-only node lifecycle status for a Lima cluster node.
[group('node-lima')]
node-lima-status node:
    ./hack/bootstrap/nodes/status.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# List Lima cluster nodes.
[group('node-lima')]
node-lima-list:
    kubectl --context '{{ lima_context }}' get nodes -o wide

# List non-succeeded pods bound to a Lima cluster node.
[group('node-lima')]
node-lima-pods node:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl --context '{{ lima_context }}' get pods -A --field-selector 'spec.nodeName={{ node }},status.phase!=Succeeded' -o wide

# Run one SSH command against a Lima inventory node without implicit sudo.
[group('node-lima-mutate')]
node-lima-cmd node +command:
    ./hack/bootstrap/nodes/cmd.sh --profile lima '{{ node }}' -- {{ quote(command) }}

# Show read-only control-plane quorum and embedded-etcd status for a Lima cluster node.
[group('node-lima')]
node-lima-control-plane-status node:
    ./hack/bootstrap/nodes/control-plane-status.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Run read-only control-plane delete preflight for a Lima cluster node.
[group('node-lima')]
node-lima-control-plane-delete-preflight node:
    ./hack/bootstrap/nodes/control-plane-delete-preflight.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Plan additive-only Lima node convergence from inventory.
[group('node-lima')]
node-lima-converge-plan:
    ./hack/bootstrap/nodes/converge.sh --profile lima --context '{{ lima_context }}' --plan

# Drain a Lima worker or control-plane node before deletion or maintenance.
[group('node-lima-mutate')]
node-lima-drain node:
    ./hack/bootstrap/nodes/drain.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Reboot a drained Lima worker or control-plane node and wait for it to return Ready.
[group('node-lima-mutate')]
node-lima-reboot node:
    ./hack/bootstrap/nodes/reboot.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Delete a drained Lima worker or control-plane node after Longhorn state has been evacuated.
[group('node-lima-mutate')]
node-lima-delete node:
    ./hack/bootstrap/nodes/delete.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Evict Longhorn replicas from a drained Lima node before replacement.
[group('node-lima-mutate')]
node-lima-longhorn-evict node:
    ./hack/bootstrap/nodes/longhorn-evict.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Refresh a rebuilt Lima inventory host's SSH host key in known_hosts.
[group('node-lima-mutate')]
node-lima-refresh-ssh-host-key node:
    ./hack/bootstrap/nodes/refresh-ssh-host-key.sh --profile lima '{{ node }}'

# Join a Lima worker or control-plane node from inventory with a temporary scheduling taint.
[group('node-lima-mutate')]
node-lima-join node:
    ./hack/bootstrap/nodes/join.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Remove the temporary Lima node taint and restore scheduling.
[group('node-lima-mutate')]
node-lima-uncordon node:
    ./hack/bootstrap/nodes/uncordon.sh --profile lima --context '{{ lima_context }}' '{{ node }}'

# Run prompted additive-only Lima node convergence from inventory.
[group('node-lima-mutate')]
node-lima-converge:
    ./hack/bootstrap/nodes/converge.sh --profile lima --context '{{ lima_context }}'

# Run non-interactive additive-only Lima node convergence from inventory.
[group('node-lima-mutate')]
node-lima-converge-yes:
    ./hack/bootstrap/nodes/converge.sh --profile lima --context '{{ lima_context }}' --yes

# Recreate app-profile Lima VMs, run Ansible, bootstrap apps, and validate safety.
[group('lima-apps')]
lima-apps-fresh:
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
    shellcheck -x hack/bootstrap/bootstrap.sh hack/bootstrap/lib/*.sh hack/bootstrap/phases/*.sh hack/bootstrap/tests/bats/*.bats hack/bootstrap/tests/helpers/*.bash hack/bootstrap/lima/*.sh hack/bootstrap/ansible/*.sh hack/bootstrap/ansible/lib/*.sh hack/bootstrap/nodes/*.sh hack/bootstrap/nodes/lib/*.sh
    bats hack/bootstrap/tests/bats
