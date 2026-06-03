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
- `hack/bootstrap/`: local bootstrap runner for fresh clusters before ArgoCD takeover
- `.github/`: CI workflows, composite actions, and Renovate config

Key files:

- `apps/argocd/manifests/app-set.yaml`: ApplicationSet for `apps/*`
- `apps/argocd/manifests/apps.yaml`: explicit ArgoCD Application CRs
- `apps/argocd/manifests/repos.yaml`: Helm repo credentials; add entries for new Application CR repos
- `apps/monitoring/grafana/`: Grafana Operator instance, datasources, HTTPRoute, ExternalSecret, dashboards, and CNPG database
- `docs/cluster-operations.md`: operator runbook for bootstrap, validation, and node lifecycle
- `docs/howto-templates.md`: templates for apps, Helm, VolSync, secrets, routes, and Cilium policies
- `hack/bootstrap/AGENTS.md`: bootstrap-specific safety and ordering rules
- `justfile`: bootstrap and validation recipes

## Validation

Use the smallest validation that covers the change:

```bash
pre-commit run --files <changed-files>
drydock test app <name> --path .
drydock test apps --path .
drydock diff apps --repo . --ref HEAD --ref-orig origin/master --skip-secrets --exit-code=false
```

`drydock` is the default local and CI renderability/diff tool for steady-state
ArgoCD GitOps validation. It renders desired state without requiring a live
ArgoCD or Kubernetes runtime. Use the full `apps` commands for cross-app or
shared-component changes, and single-app commands for narrow app-local changes.

For live ArgoCD server-side apply/diff behavior, match ArgoCD's field manager:

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

For bootstrap changes:

```bash
just bootstrap-test
just kind-fresh
just kind-bootstrap-dry-run
just bootstrap-audit
just bootstrap-dry-run
just bootstrap-phase argocd
```

## ArgoCD Notes

- ApplicationSet-generated apps default to server-side diff/apply, prune, `SkipDryRunOnMissingResource=true`, `ApplyOutOfSyncOnly=true`, `CreateNamespace=true`, and `RespectIgnoreDifferences=true`
- Keep app-of-apps sync options explicit and scoped to the Application that needs them
- Do not disable server-side diff or add broad ignore rules until the drift source is proven with ArgoCD and `kubectl` output
- If server-side diff reports impossible changes to `Application.status` or tracking annotations, inspect managed fields and fix stale live ownership instead of hiding it in Git
- If repo-server Helm rendering fails with cache extraction errors, first verify local `kustomize build`; if local render is clean, recycle the repo-server pod

## Bootstrap Notes

- Bootstrap is deliberately narrower than steady-state GitOps. Keep it limited to dependencies required before ArgoCD can take over: CRDs, cert-manager, External Secrets and 1Password Connect, Dragonfly Operator, ArgoCD dependencies, and ArgoCD itself.
- Do not add normal workloads to `hack/bootstrap/` if ArgoCD can safely reconcile them after takeover.
- Kind bootstrap validation uses the repo-specific `home-ops-bootstrap` cluster by default and intentionally omits real-cluster-only resources when `ciliumnetworkpolicies.cilium.io` is absent: the `k3s-apps` ApplicationSet, Cilium apps, Longhorn, and `crd-schema-publisher`.
- When Cilium CRDs are present, bootstrap must apply Hubble CA resources and wait for `Application/cilium` plus Hubble server/relay certs before applying `ApplicationSet/k3s-apps`; normal apps should not start until Cilium takeover is complete.
- Lima foundation bootstrap validation uses `hack/bootstrap/lima/` and `--profile foundation`; it runs the selected Ansible backend, defaults to the in-repo `home-ops` backend, installs only a disposable foundation cluster, uses the server VM IP rather than kube-vip for the cluster join endpoint, imports local context `lima-home-ops-k3s-test` through a persistent SSH tunnel, applies Hubble CA resources before ArgoCD Cilium takeover, keeps Cilium masquerading enabled only for Lima's user-mode network, disables Dragonfly Operator's optional monitoring/dashboard resources in foundation mode, requires foundation Applications to be `Synced` and `Healthy`, and must fail if normal workloads or backup writers such as `powerdns`, `hass`, VolSync, Velero, external-dns, or CNPG backup resources appear.
- Lima Longhorn bootstrap uses `--profile lima-longhorn`; run it for storage lifecycle tests that need Longhorn and a real PVC but not restored apps. It installs Cilium, Dragonfly Operator, Longhorn, external snapshotter, repo storage classes, and a checksum workload on `longhorn-retain`.
- Lima app bootstrap uses `--profile lima-apps`; run it with the app-sized Lima shape and enough disk for Longhorn restore and replacement-eviction testing. The app `just` recipes use `120GiB` disks and preflight requires `100GiB` allocatable ephemeral storage per schedulable node. Lima VM creation installs `open-iscsi` and `nfs-common` so Longhorn block and RWX volumes can mount. It first seeds Gateway wildcard TLS Secrets from 1Password through `ExternalSecret` resources, applies external-snapshotter before VolSync restore workloads, then applies a sanitized `ApplicationSet/k3s-apps` allowlist. Keep render-time safety patches primary and admission policies as fail-closed guardrails. Lima Longhorn/app bootstrap must not create `PushSecret`, ACME `Order`/`Challenge`, VolSync `ReplicationSource`, active CNPG `Cluster.spec.plugins`, CNPG backup resources, Velero backup resources, or Longhorn backup `RecurringJob` objects.
- `kind-bootstrap-dry-run` is a post-bootstrap validation pass. It is not a clean-cluster first-boot test because server-side dry-run does not persist CRDs for later CR validation.
- Live physical-node Ansible orchestration lives under `hack/bootstrap/ansible/`. The default backend is the in-repo `home-ops` Debian-family implementation for this cluster, while the external `../k3s-ansible` checkout remains available only through `BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible` or `--backend k3s-ansible`. Keep site-specific inventory rendering, 1Password token handling, and live confirmation prompts in `home-ops`.
- Existing-cluster node lifecycle helpers live under `hack/bootstrap/nodes/`. Worker status/drain/delete/join/uncordon are explicit steps. Mutating delete must prevent immediate K3s re-registration before deleting the Kubernetes Node. Control-plane drain/delete must remain gated by the embedded-etcd preflight, Longhorn eviction when Longhorn is installed, fresh K3s etcd snapshot creation, and explicit member removal from a remaining control-plane. Control-plane join/uncordon must verify the old etcd member is absent, move any stale local K3s server DB aside before rejoin, apply a temporary joining taint, and keep the node cordoned until the finalize/uncordon step removes the taint and restores Longhorn scheduling. First-inventory-master replacement depends on stable API access: live uses the stable `default` API endpoint, while Lima retargets the local API tunnel to an alternate Ready control-plane and passes an alternate control-plane InternalIP as the temporary K3s join endpoint.
- `hack/bootstrap/ansible/inventory/live/` may contain non-secret physical node facts. Do not commit the generated `.out/ansible-*` inventories, kubeconfigs, or any rendered secret values.
- Do not let local kind tests publish schemas or touch other external live services.
- Secret manifests from 1Password must be streamed, normalized to Secret `data`, and applied server-side; do not write them to disk, logs, or client-side last-applied annotations. The seed Secret may use scoped `--force-conflicts` because the 1Password item is authoritative.
- The live homelab kube context is `default`. Use live dry-run and audit recipes for validation; do not run a live non-dry-run bootstrap from an unmerged branch.
- If live server-side dry-run finds managedFields conflicts, diagnose ownership first. Prefer Git-side `ServerSideApply=true` for explicit ArgoCD Applications, and use live `--force-conflicts` only for narrow, one-time ownership migrations after confirming the rendered manifest matches intent.

## App Conventions

- Match the existing app shape: plain Kustomize, Kustomize `helmCharts`, grouped parent app, or explicit ArgoCD Application CR in `apps/argocd/manifests/apps.yaml`
- Every app should include the namespace component and an explicit namespace manifest unless a parent group provides it
- Use `HTTPRoute`, not `Ingress`
- Gateway mapping: `envoy-gateway` => `*.mgmt.sholdee.net`, `external-gateway` => `*.sholdee.net`, `guest-gateway` => `*.guest.sholdee.net`
- Use `CiliumNetworkPolicy`, not `NetworkPolicy`
- CiliumNetworkPolicy enables enforcement for selected pods, so include all required ingress sources: gateway, metrics, database, and operator traffic as applicable
- Use External Secrets; app credentials use `ClusterSecretStore: onepassword-connect`, while gateway TLS certs use `ClusterSecretStore: gateway`
- Add `reloader.stakater.com/auto: "true"` to workloads consuming secrets/configmaps
- Add `# yaml-language-server: $schema=...` for manifests with generated schemas from `https://kube-schemas.shold.io`, including CRDs, built-in Kubernetes resources, and Kustomize Kustomization/Component files
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

## Monitoring

- Prometheus is deployed by kube-prometheus-stack in `apps/monitoring`; image
  changes belong in `apps/monitoring/values.yaml` under
  `prometheus.prometheusSpec`, not in generated StatefulSet patches
- For Prometheus image migrations, keep `prometheus.prometheusSpec.version`
  explicit when the image tag is not an upstream Prometheus version, because the
  Prometheus Operator uses it for feature compatibility and command generation
- Before any Prometheus WAL-format migration, create and verify a Longhorn
  `VolumeSnapshot` of
  `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0`
- Validate the exact digest-pinned candidate image on the actual ARM64
  Prometheus node before rollout; local Docker ARM64 checks can miss Raspberry
  Pi 5 16 KiB page-size issues
- If a one-shot WAL conversion init container is required, mount the PVC root at
  `/prometheus-volume`, keep marker files outside `/prometheus-volume/prometheus-db`,
  make retries fail closed after an incomplete start marker, and remove the init
  container in a follow-up PR immediately after the first healthy rollout
- Prom++ writes a different WAL format than upstream Prometheus. Do not simply
  revert back to `quay.io/prometheus/prometheus` after Prom++ starts; use the
  documented reverse conversion or restore the pre-migration snapshot

## Grafana

Grafana is managed by Grafana Operator in `apps/monitoring/grafana`; the
kube-prometheus-stack Grafana instance is disabled, but kube-prometheus-stack
still emits dashboard ConfigMaps.

- Grafana is stateless with 2 replicas backed by 3-instance CNPG on `local-path`; keep PgBouncer in `session` mode unless fresh live validation proves otherwise
- Dashboard CRs live in `manifests/dashboards.yaml`; use `instanceSelector.matchLabels.dashboards: grafana`, `folder: General`, and pinned sources
- Before changing a dashboard source, verify dashboard UID and datasource input names to avoid duplicates or broken datasource substitution
