# CLAUDE.md - Project Context for home-ops

## What This Is

ARM64 (Raspberry Pi 5) K3s GitOps cluster. **All container images must support `linux/arm64`.** ArgoCD syncs from `master` branch. Renovate manages dependency updates. GitHub Actions verify Helm diffs and container images on PRs.

## Repository Layout

```
apps/           ArgoCD watches apps/* (one Application per top-level directory)
components/     Reusable Kustomize Components (namespace, volsync)
docs/           Operational docs and full reference
.github/        Renovate config, CI workflows, scripts
```

### Key Files

| File | Purpose |
|------|---------|
| `apps/argocd/manifests/app-set.yaml` | ApplicationSet — Git directory generator scans `apps/*`, creates one Application per dir. Name = basename, namespace = basename with `-conf` stripped. Adding a new `apps/<name>/` dir auto-creates an app. |
| `apps/argocd/manifests/apps.yaml` | App-of-apps — Cilium, Longhorn, Reloader, VolSync Helm releases |
| `apps/argocd/manifests/cilium-preflight.yaml` | Cilium preflight — keep version in sync with `apps.yaml` (separate file so Renovate creates independent PRs) |
| `apps/system-upgrade/manifests/plan.yaml` | K3s version (Renovate custom manager tracks this) |
| `.github/renovate.json5` | Renovate config — custom managers (K3s, MongoDB, GitHub releases), package rules, automerge settings |
| `.github/workflows/ci.yaml` | CI orchestrator — detects change type, conditionally calls helm-diff/pull-image, provides single `CI / gate` required status check |
| `.github/workflows/helm-diff.yml` | Reusable workflow — renders old vs new Helm templates, diffs them, verifies ARM64 image support via `crictl pull` |
| `.github/workflows/pre-commit.yml` | Reusable workflow — installs kubeconform + actionlint, runs all pre-commit hooks |
| `.github/workflows/pull-image.yml` | Reusable workflow — triggered for Renovate container image PRs, verifies `linux/arm64` platform |
| `docs/howto-templates.md` | Templates for new apps, Helm apps, VolSync, ExternalSecret, HTTPRoute, CiliumNetworkPolicy |

### ArgoCD Behavior

- Config enables `kustomize.buildOptions: --enable-helm` so kustomize can render Helm charts
- All apps auto-sync with prune, ServerSideApply, and CreateNamespace

## Pre-commit Hooks

Install and activate:

```bash
brew install pre-commit kubeconform shellcheck actionlint
pre-commit install
```

Hooks run automatically on `git commit`. To run manually:

```bash
pre-commit run --all-files    # all hooks, all files
pre-commit run kubeconform    # single hook, staged files only
```

| Hook | Purpose |
|------|---------|
| trailing-whitespace | Auto-fix trailing whitespace |
| end-of-file-fixer | Ensure files end with newline |
| check-merge-conflict | Catch merge conflict markers |
| check-added-large-files | Prevent accidental large file commits |
| check-yaml | YAML syntax validation |
| check-ast | Python syntax validation |
| yamllint | YAML style/indentation (config: `.yamllint.yaml`) |
| validate kustomization | JSON Schema validation of `kustomization.yaml` files |
| check-github-workflows | JSON Schema validation of GitHub Actions workflows |
| check-renovate | JSON Schema validation of Renovate config |
| kubeconform | K8s schema validation — builtin APIs + CRDs via `datreeio/CRDs-catalog` |
| shellcheck | Bash script linting |
| actionlint | Deep GitHub Actions linting (expressions, script injection, shellcheck) |

## Common Commands

```bash
# Validate kustomize build for an app
kustomize build --enable-helm apps/<name>/

# Preview what ArgoCD will apply (requires cluster access)
argocd app diff <name>

# Force sync an app
argocd app sync <name>

# Check ArgoCD app status
argocd app get <name>

# Run Helm diff locally (same as CI)
.github/scripts/helm_diff.sh

# Render a Helm chart's templates locally
helm template <release> <chart> -f apps/<name>/manifests/values.yaml
```

## Branch & PR Workflow

- **Default branch:** `master` (ArgoCD syncs from here)
- **Renovate branches:** `renovate/<package-name>-<major>.x`
- **Manual branches:** descriptive names (e.g., `headlamp-token-login`)
- **Commit style:** [Conventional Commits](https://www.conventionalcommits.org/) — `feat(scope):`, `fix(scope):`, `chore(deps):`, `docs:`
- **Automerge:** Renovate minor/patch/digest updates for approved packages merge automatically
- **CI gate:** Single required status check `CI / gate` — conditionally runs helm-diff and/or docker-verify; passes automatically when neither applies
- **Branch protection:** Direct pushes to `master` are blocked — all changes require a PR with passing gate

## Five App Patterns

1. **Plain kustomize** (e.g., `adguard`, `powerdns`): `kustomization.yaml` + `manifests/` with raw YAML
2. **Kustomize + Helm** (e.g., `cert-manager`, `external-dns`, `velero`): `helmCharts:` section in kustomization.yaml, values in `manifests/values.yaml` or `valuesInline:`
3. **ArgoCD Application CRs** (Cilium, Longhorn, Reloader, VolSync): Defined in `apps/argocd/manifests/apps.yaml` with `spec.source.helm.valuesObject`
4. **Grouped apps** (e.g., `hass/`, `unifi/`, `monitoring/`, `kube-system/`): Parent kustomization references sub-directories as resources
5. **Kustomize + VolSync** (e.g., `portainer`, `mealie`, `hass/hass`): Includes volsync components with patches to customize names/paths

## Required Conventions

### Every app MUST

- Include `components: [../../components/namespace]` (provides Docker Hub pull secret)
- Have an explicit `manifests/namespace.yaml` resource (or parent group provides it)
- Use `# yaml-language-server: $schema=...` comments only on CRD YAML files (ExternalSecret, HTTPRoute, CiliumNetworkPolicy, CNPG resources, etc.). Do NOT add schema comments to built-in Kubernetes APIs (Deployment, Service, ConfigMap, Namespace, etc.) — the IDE already provides schema awareness for these

### Dependency pinning

- **Container images:** Pin to tag + manifest index digest (e.g., `image: busybox:1.37.0@sha256:...`). Renovate updates both tag and digest together.
- **GitHub Actions:** Pin to commit SHA with semver comment (e.g., `uses: actions/checkout@sha256hash # v6.0.2`). Renovate updates both SHA and comment together.

### Every deployment MUST have

- Pod security context: `runAsNonRoot: true`, `runAsUser: 65534`, `runAsGroup: 65534`, `fsGroup: 65534`, `seccompProfile: { type: RuntimeDefault }`
- Container security context: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: { drop: ["ALL"] }`
- Resource `requests` and `limits` on all containers
- `emptyDir: {}` for any tmp/cache mounts (since root FS is read-only)

### Secrets

- Never hardcode credentials. Use External Secrets Operator with `ClusterSecretStore: onepassword-connect`
- TLS certs use `ClusterSecretStore: gateway` (keys: `external-wildcard`, `mgmt-wildcard`)
- Add `reloader.stakater.com/auto: "true"` annotation to deployments that consume secrets/configmaps

### Networking

- **Internal services:** HTTPRoute -> `envoy-gateway` (gateway namespace) -> `*.mgmt.sholdee.net`
- **External services:** HTTPRoute -> `external-gateway` (gateway namespace) -> `*.sholdee.net`
- **Guest portal:** HTTPRoute -> `guest-gateway` (gateway namespace) -> `*.guest.sholdee.net`
- Use `CiliumNetworkPolicy` (not NetworkPolicy) for pod-level restrictions
- Backend TLS: use `BackendTLSPolicy` when upstream serves HTTPS

### Storage

- Default StorageClass: `longhorn`
- No-replica class (for CNPG): `longhorn-noreplicas`
- MongoDB class: `longhorn-mongo`
- Retain class (VolSync restore): `longhorn-retain`

## VolSync Backup Pattern

Apps needing persistent data backup include two components and patch four resources to replace generic `app` names. Canonical example: `apps/portainer/kustomization.yaml`.

```yaml
components:
  - ../../components/volsync       # PVC template
  - ../../components/volsync/b2    # B2 backup ReplicationSource/Destination + ExternalSecret
patches:
  - target: { kind: ReplicationSource, name: app }
    patch: |-  # rename to <app>, update sourcePVC and repository
  - target: { kind: ReplicationDestination, name: app-bootstrap }
    patch: |-  # rename to <app>-bootstrap, update repository
  - target: { kind: ExternalSecret, name: app-volsync-b2 }
    patch: |-  # rename, set B2 bucket path: s3:s3.us-west-002.backblazeb2.com/sholdee-volsync/<app>
  - target: { kind: PersistentVolumeClaim, name: app-pvc }
    patch: |-  # rename to <app>-pvc, update dataSourceRef
```

Other VolSync apps: `mealie`, `unifi/unifi`, `hass/hass`. Some override `accessModes` to `ReadWriteMany`. See `docs/howto-templates.md` for the full patch template.

## Common Mistakes to Avoid

- Forgetting the namespace component (unauthenticated Docker Hub pulls, pods may fail ImagePullBackOff on rate limit)
- Using `Ingress` instead of `HTTPRoute` (this cluster uses Gateway API exclusively)
- Using `NetworkPolicy` instead of `CiliumNetworkPolicy`
- Missing security context (pods will be rejected or run with excessive privileges)
- Omitting `kustomization.yaml` in an app directory (ArgoCD will still apply raw manifests, but kustomize wrapping is used for consistency and flexibility)
- Hardcoding secrets in manifests instead of using ExternalSecret
- Using images without ARM64 support (CI will reject and pods won't schedule)
- Adding container images without a digest — always include `@sha256:...` (use `docker buildx imagetools inspect <image>` to get the manifest index digest)
- Pinning GitHub Actions to tag only (`@v6`) instead of SHA + comment (`@sha256hash # v6.0.2`)
- Forgetting `readOnlyRootFilesystem: true` without providing writable mounts for app needs
- Using non-conventional commit messages (Renovate and CI rely on semantic prefixes)
- Pushing directly to `master` — branch protection requires a PR with passing `CI / gate` check
- Skipping pre-commit hooks with `--no-verify` — fix the underlying issue instead

## Cluster Access & Debugging

- **ArgoCD UI:** <https://argocd.sholdee.net> (external gateway, behind Cloudflare Zero Trust)
- **ArgoCD CLI:** requires `kubectl port-forward svc/argocd-server -n argocd 8443:443`, then `argocd login localhost:8443 --insecure`
- **kubectl:** requires kubeconfig for the K3s cluster
- **Useful docs:** `docs/cilium-setup-commands.md` (networking/BGP), `docs/helm-commands.md` (Helm utilities)
- **Logs:** `kubectl logs -n <namespace> deploy/<name>` or check ArgoCD UI for sync errors
- **Storage issues:** check Longhorn UI or `kubectl get volumes.longhorn.io -A`
