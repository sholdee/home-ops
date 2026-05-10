# Home Ops Bootstrap

This directory contains the local bootstrap runner for a fresh cluster after
`k3s-ansible` has produced a working Kubernetes API and kubeconfig.

For the operator-facing `just` runbook, see
[`docs/just-bootstrap.md`](../../docs/just-bootstrap.md).

The runner is intentionally outside normal GitOps app state. It seeds the
minimum dependencies needed for ArgoCD to take over:

1. Seed `Secret/external-secrets/op-credentials` from 1Password CLI.
2. Install required CRDs.
3. Bootstrap cert-manager.
4. Bootstrap External Secrets and 1Password Connect.
5. Bootstrap Dragonfly Operator.
6. Apply narrow ArgoCD dependencies.
7. Apply the canonical `apps/argocd` render.
8. Wait for ArgoCD components.
9. Run conservative Helm takeover cleanup and audit.

Run a dry-run against the current kube context:

```sh
./hack/bootstrap/bootstrap.sh --dry-run
```

On a clean cluster, dry-run does not persist CRDs. Use a real guarded kind
bootstrap for first-boot validation, then dry-run later phases after the CRDs
exist.

Run against an explicit context:

```sh
./hack/bootstrap/bootstrap.sh --kube-context kind-home-ops-bootstrap --yes
```

For local bootstrap testing, recreate kind as one control-plane plus two worker
nodes so required pod anti-affinity can schedule:

```sh
just kind-reset
```

When `ciliumnetworkpolicies.cilium.io` is absent, the ArgoCD phase omits
real-cluster-only applications such as the full `k3s-apps` ApplicationSet,
Longhorn, Cilium, and `crd-schema-publisher`.

If more than one 1Password account is configured and the default account is
wrong, pin the account explicitly:

```sh
./hack/bootstrap/bootstrap.sh --kube-context kind-home-ops-bootstrap --op-account my --yes
```

The script writes local run logs under `.out/`. Secret manifests read from
1Password are validated and streamed directly to Kubernetes; they are never
written to disk or stored in the local run report. The seed Secret is normalized
to `data`, applied server-side, and cleaned of any old
`kubectl.kubernetes.io/last-applied-configuration` annotation. That seed apply
uses scoped server-side `--force-conflicts` because the 1Password item is
authoritative. The seed phase checks `op whoami` and, when stdin is
interactive, falls back to `op signin` without logging the returned session
export. Keep 1Password CLI desktop app integration enabled and the app unlocked
for local interactive bootstrap runs, or authenticate `op` before invoking the
script. Leave `--op-account` unset unless you need to disambiguate accounts;
when you do set it, use the shorthand from `op account list`, such as `my`.

If script-managed `op` auth is not appropriate, let your shell run `op read`
and pipe the manifest to the seed phase:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | ./hack/bootstrap/bootstrap.sh --kube-context kind-home-ops-bootstrap --only-phase seed-secret --seed-secret-stdin --yes
```
