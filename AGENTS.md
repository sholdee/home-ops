# AGENTS.md - home-ops

## Context

ARM64 Raspberry Pi 5 K3s GitOps cluster. ArgoCD syncs from `master`.
All container images must support `linux/arm64`.

Direct pushes to `master` are blocked. Use a branch, conventional commits, and
a PR with passing `CI / gate`.

## Repo Layout

- `apps/`: ArgoCD watches `apps/*` and creates one Application per top-level directory
- `components/`: reusable Kustomize components such as namespace and VolSync
- `docs/`: operational docs and templates
- `.github/`: CI, Renovate, and helper scripts

Key files:

- `apps/argocd/manifests/app-set.yaml`: ApplicationSet for `apps/*`
- `apps/argocd/manifests/apps.yaml`: explicit ArgoCD Application CRs
- `apps/argocd/manifests/repos.yaml`: Helm repo credentials; add entries for new Application CR repos
- `apps/monitoring/grafana/`: Grafana Operator instance, datasources, HTTPRoute, ExternalSecret, dashboards, and CNPG database
- `docs/howto-templates.md`: templates for apps, Helm, VolSync, secrets, routes, and Cilium policies

## Validation

Use the smallest validation that covers the change:

```bash
pre-commit run --files <changed-files>
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/<name>/
```

For ArgoCD server-side apply/diff behavior, match ArgoCD's field manager:

```bash
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/<name>/ \
  | kubectl apply --server-side --dry-run=server --field-manager=argocd-controller -f -

kubectl diff --server-side --field-manager=argocd-controller -f <manifest>
kubectl apply --server-side --field-manager=argocd-controller -f <manifest>
```

Using kubectl's default field manager can create misleading managedFields
ownership and drift. Live applies are only validation drift until the matching
branch is merged to `master` and ArgoCD syncs it.

## ArgoCD Notes

- ApplicationSet-generated apps default to server-side diff/apply, prune, `SkipDryRunOnMissingResource=true`, `ApplyOutOfSyncOnly=true`, `CreateNamespace=true`, and `RespectIgnoreDifferences=true`
- Keep app-of-apps sync options explicit and scoped to the Application that needs them
- Do not disable server-side diff or add broad ignore rules until the drift source is proven with ArgoCD and `kubectl` output
- If server-side diff reports impossible changes to `Application.status` or tracking annotations, inspect managed fields and fix stale live ownership instead of hiding it in Git
- If repo-server Helm rendering fails with cache extraction errors, first verify local `kustomize build`; if local render is clean, recycle the repo-server pod

## App Conventions

- Match the existing app shape: plain Kustomize, Kustomize `helmCharts`, grouped parent app, or explicit ArgoCD Application CR in `apps/argocd/manifests/apps.yaml`
- Every app should include the namespace component and an explicit namespace manifest unless a parent group provides it
- Use `HTTPRoute`, not `Ingress`
- Gateway mapping: `envoy-gateway` => `*.mgmt.sholdee.net`, `external-gateway` => `*.sholdee.net`, `guest-gateway` => `*.guest.sholdee.net`
- Use `CiliumNetworkPolicy`, not `NetworkPolicy`
- CiliumNetworkPolicy enables enforcement for selected pods, so include all required ingress sources: gateway, metrics, database, and operator traffic as applicable
- Use External Secrets; app credentials use `ClusterSecretStore: onepassword-connect`, while gateway TLS certs use `ClusterSecretStore: gateway`
- Add `reloader.stakater.com/auto: "true"` to workloads consuming secrets/configmaps
- Add `# yaml-language-server: $schema=...` only to CRD YAML files, not built-in Kubernetes resources
- Pin container images to tag plus digest and verify ARM64 support
- Pin GitHub Actions to full commit SHAs with semver comments and preserve Renovate annotations/custom-manager patterns
- Add resource requests/limits, restricted security context, and writable `emptyDir` mounts for read-only-rootfs workloads

## Storage

- Default StorageClass: `longhorn`
- No-replica Longhorn class: `longhorn-noreplicas`
- MongoDB class: `longhorn-mongo`
- Retain class for restores: `longhorn-retain`
- `local-path` is intentionally used for small replicated CNPG clusters where important app state is GitOps-managed, such as Grafana
- For PVC backups, use `components/volsync` and `components/volsync/b2`; patch ReplicationSource, ReplicationDestination, ExternalSecret, and PVC together

## Grafana

Grafana is managed by Grafana Operator in `apps/monitoring/grafana`; the
kube-prometheus-stack Grafana instance is disabled, but kube-prometheus-stack
still emits dashboard ConfigMaps.

- Grafana is stateless with 2 replicas backed by 3-instance CNPG on `local-path`; keep PgBouncer in `session` mode unless fresh live validation proves otherwise
- Dashboard CRs live in `manifests/dashboards.yaml`; use `instanceSelector.matchLabels.dashboards: grafana`, `folder: General`, and pinned sources
- Before changing a dashboard source, verify dashboard UID and datasource input names to avoid duplicates or broken datasource substitution
