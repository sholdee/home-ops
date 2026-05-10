# Just Bootstrap Runbook

This page documents the `just` recipes for bootstrapping a fresh cluster into
the minimum state ArgoCD needs before it can take over normal GitOps sync.

The bootstrap runner lives in `hack/bootstrap/`. It assumes `k3s-ansible` or an
equivalent process has already produced a working Kubernetes API and kubeconfig.
For the first implementation, Cilium is expected to be installed before this
runner is used on the real cluster.

## Prerequisites

- `just`
- `kubectl`
- `kustomize`
- `helm`
- `yq`
- `jq`
- `op`
- `shellcheck`
- A kubeconfig pointing at the target cluster
- 1Password CLI signed in with access to
  `op://Kubernetes/op-credentials/op-credentials.yaml`

Run this first when validating script changes:

```sh
just bootstrap-test
```

## Local Kind Test

Kind recipes use the repo-specific cluster name `home-ops-bootstrap`, which
creates the kube context `kind-home-ops-bootstrap`. Override it only when needed:

```sh
KIND_CLUSTER=my-test-cluster just kind-reset
```

Create a clean three-node kind cluster:

```sh
just kind-reset
```

Run the bootstrap against kind:

```sh
just bootstrap-kind
```

Recreate kind and then run the bootstrap in one step:

```sh
just bootstrap-kind-fresh
```

To seed kind separately before resuming the remaining phases:

```sh
just bootstrap-kind-seed
just bootstrap-kind-resume
```

After kind has been bootstrapped once and the CRDs exist, run a server-side
dry-run validation against the local API:

```sh
just bootstrap-kind-dry-run
```

Delete the local kind cluster when validation is complete:

```sh
just kind-delete
```

Do not use `bootstrap-kind-dry-run` as the first command after `kind-reset`.
Server-side dry-run validates objects but does not persist CRDs, so later dry-run
phases cannot validate CRs such as `ClusterSecretStore` or ArgoCD `Application`
until those CRDs already exist.

The kind path is intentionally narrower than the real cluster path. If the
target cluster does not have `ciliumnetworkpolicies.cilium.io`, the bootstrap
omits the real-cluster `ApplicationSet/k3s-apps`, Cilium applications, and
Longhorn application. It also omits `crd-schema-publisher` so a local kind test
does not publish schemas over the live schema index. That keeps kind focused on
bootstrap dependency ordering instead of trying to run every homelab workload
without Cilium, Longhorn, and real infrastructure.

## Real Cluster Bootstrap

Review the active context:

```sh
kubectl config current-context
```

Dry-run against the current context:

```sh
just bootstrap-dry-run
```

Run with confirmation prompts:

```sh
just bootstrap
```

Run non-interactively after confirming the context is correct:

```sh
just bootstrap-yes
```

Run against an explicit local repo path:

```sh
just bootstrap /Users/ethan.shold/git/home-ops
```

## Live Cluster Validation

Use the `default` context for the live homelab cluster unless kubeconfig has
been changed deliberately:

```sh
kubectl --context default get nodes -o wide
```

Run a read-only inventory of Helm release storage, ArgoCD applications, and core
deployments:

```sh
just bootstrap-live-audit default
```

Run the live API validation without reading the 1Password seed secret and
without persisting changes:

```sh
just bootstrap-live-dry-run default
```

This starts at `bootstrap-crds`, uses server-side dry-run for rendered resources,
and skips rollout waits. It validates the manifests against the real API server,
installed CRDs, admission webhooks, and RBAC. It does not prove first-boot timing
because the real cluster already has CRDs, controllers, namespaces, and secrets.
Use a clean kind reset for first-boot ordering.

Live dry-run can fail on existing managed-field ownership that does not affect
the currently synced live cluster. For example, older resources may have fields
owned by `argocd-controller` through an `Update` operation, and a server-side
dry-run apply from the bootstrap script may report a conflict on that field. Treat
that as managed-field drift to investigate, not as a bootstrap ordering failure.

If the all-in-one dry-run stops on one object, continue coverage phase by phase:

```sh
just bootstrap-live-phase dragonfly-operator default
just bootstrap-live-phase argocd-dependencies default
just bootstrap-live-phase argocd default
just bootstrap-live-phase wait-argocd default
just bootstrap-live-phase takeover-cleanup default
```

Do not run a live non-dry-run bootstrap from an unmerged branch. For the live
cluster, use dry-run from a branch and let merged `master` plus ArgoCD own
steady-state changes.

## 1Password Seed Secret

The seed phase creates `Secret/external-secrets/op-credentials`. The secret
manifest is read from 1Password, validated, normalized to Secret `data`, and
streamed to Kubernetes with server-side apply. It is not written to disk or
included in the local run report, and the bootstrap removes any old
`kubectl.kubernetes.io/last-applied-configuration` annotation from the seed
Secret. This one apply path uses scoped server-side `--force-conflicts` because
the 1Password item is authoritative for the bootstrap seed Secret and older
clusters may have created it with client-side apply.

The seed phase first tries `op read`. If that fails and the run is interactive,
it runs `op signin`, evaluates the returned session export inside the bootstrap
process without logging it, and then retries the read. Only the Secret manifest
is written to stdout for the YAML pipeline.

If the automatic prompt is not appropriate, authenticate first:

```sh
eval "$(op signin)"
```

Then rerun bootstrap. You can also pipe the seed manifest directly to bypass
all script-managed `op` calls:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | ./hack/bootstrap/bootstrap.sh --only-phase seed-secret --seed-secret-stdin --yes
```

Use `--op-account` only when multiple accounts require disambiguation. Prefer
the shorthand from `op account list`.

## Phases

The runner logs each phase name and makes every phase idempotent:

1. `preflight`
2. `seed-secret`
3. `bootstrap-crds`
4. `cert-manager`
5. `external-secrets`
6. `dragonfly-operator`
7. `argocd-dependencies`
8. `argocd`
9. `wait-argocd`
10. `takeover-cleanup`
11. `audit`

Run only one phase when debugging:

```sh
./hack/bootstrap/bootstrap.sh --only-phase audit
```

Start from a later phase:

```sh
./hack/bootstrap/bootstrap.sh --from-phase argocd --yes
```

## Reports

Each run writes non-secret output under `hack/bootstrap/.out/`. The directory is
gitignored. Use the report when comparing a kind test to a real-cluster run.

## After Bootstrap

On the real cluster, ArgoCD should own the steady-state sync after bootstrap.
Check Application status:

```sh
kubectl -n argocd get applications.argoproj.io
```

Run the audit phase after takeover cleanup or after manual investigation:

```sh
just bootstrap-audit
```
