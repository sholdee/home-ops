# CLAUDE.md - Project Context for home-ops

## What This Is

ARM64 K3s GitOps cluster. ArgoCD syncs from `master` branch. Renovate manages dependency updates. GitHub Actions verify Helm diffs and container images on PRs.

## Repository Layout

```
apps/           ArgoCD watches apps/* (one Application per top-level directory)
components/     Reusable Kustomize Components (namespace, volsync)
docs/           Operational docs and full reference
.github/        Renovate config, CI workflows, scripts
```

## How ArgoCD Works

- **ApplicationSet** (`apps/argocd/manifests/app-set.yaml`): Git directory generator scans `apps/*`, creates one Application per directory. Name = directory basename, namespace = basename with `-conf` suffix stripped.
- **App-of-apps** (`apps/argocd/manifests/apps.yaml`): Contains ArgoCD Application CRs for Cilium, Longhorn, Reloader, VolSync. Legacy/simple pattern for Helm charts that don't need extra customization beyond values.
- **Cilium preflight** (`apps/argocd/manifests/cilium-preflight.yaml`): Separate file so Renovate creates an independent PR. When updating Cilium version in `apps.yaml`, also update `cilium-preflight.yaml` to match.
- ArgoCD config enables `kustomize.buildOptions: --enable-helm` so kustomize can render Helm charts.
- All apps auto-sync with prune, ServerSideApply, and CreateNamespace.
- Adding a new `apps/<name>/` directory automatically creates an ArgoCD Application.

## Five App Patterns

1. **Plain kustomize** (e.g., `adguard`, `gravity`): `kustomization.yaml` + `manifests/` with raw YAML
2. **Kustomize + Helm** (e.g., `cert-manager`, `external-dns`, `velero`): `helmCharts:` section in kustomization.yaml, values in `manifests/values.yaml` or `valuesInline:`
3. **ArgoCD Application CRs** (Cilium, Longhorn, Reloader, VolSync): Defined in `apps/argocd/manifests/apps.yaml` with `spec.source.helm.valuesObject`
4. **Grouped apps** (e.g., `hass/`, `unifi/`, `monitoring/`, `kube-system/`): Parent kustomization references sub-directories as resources
5. **Kustomize + VolSync** (e.g., `portainer`, `mealie`, `hass/hass`): Includes volsync components with patches to customize names/paths

## Required Conventions

### Every app MUST

- Include `components: [../../components/namespace]` (provides Docker Hub pull secret)
- Have an explicit `manifests/namespace.yaml` resource (or parent group provides it)
- Use `# yaml-language-server: $schema=...` comments on all YAML files

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

Apps needing persistent data backup include `../../components/volsync` (PVC template) and `../../components/volsync/b2` (B2 backup) components, then patch all four resources (`ReplicationSource`, `ReplicationDestination`, `ExternalSecret`, `PVC`) to replace generic `app` names. Some apps override `accessModes` to `ReadWriteMany`. See `docs/howto-templates.md` for the full patch template.

## CI/CD Awareness

- GitHub Actions run Helm diffs and verify container images can be pulled on ARM64 -- all images must support `linux/arm64`
- Renovate auto-manages dependency PRs; check `.github/renovate.json5` for custom managers and version constraints

## Common Mistakes to Avoid

- Forgetting the namespace component (unauthenticated Docker Hub pulls, pods may fail ImagePullBackOff on rate limit)
- Using `Ingress` instead of `HTTPRoute` (this cluster uses Gateway API exclusively)
- Using `NetworkPolicy` instead of `CiliumNetworkPolicy`
- Missing security context (pods will be rejected or run with excessive privileges)
- Omitting `kustomization.yaml` in an app directory (ArgoCD will still apply raw manifests, but kustomize wrapping is used for consistency and flexibility)
- Hardcoding secrets in manifests instead of using ExternalSecret
- Using images without ARM64 support (will fail on the RPi5 cluster)
- Forgetting `readOnlyRootFilesystem: true` without providing writable mounts for app needs

## How-To Templates

For templates covering new apps, Helm apps, VolSync setup, ExternalSecret, HTTPRoute, and CiliumNetworkPolicy, see `docs/howto-templates.md`.

## Documentation Maintenance

When making changes to the repository, update the relevant documentation as part of the same change:

- **`README.md`** -- Update when adding/removing applications, changing core components, modifying hardware, or altering the high-level architecture
- **`CLAUDE.md`** (this file) -- Update when conventions, patterns, or architectural rules change

Documentation should stay in sync with the actual state of the cluster.
