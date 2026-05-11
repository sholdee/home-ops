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

Run the safety-scoped foundation profile:

```sh
./hack/bootstrap/bootstrap.sh --profile foundation --kube-context kind-home-ops-bootstrap --yes
```

The foundation profile always omits the broad `ApplicationSet/k3s-apps` and
applies only the explicit ArgoCD Applications needed for bootstrap takeover.
It is intended for disposable VM validation where Cilium is already present but
normal workloads and external backup writers must not start.
In this profile, Dragonfly Operator's optional `ServiceMonitor` and
`GrafanaDashboard` outputs are disabled because the monitoring and Grafana
operators are intentionally left to steady-state ArgoCD.

For local bootstrap testing, recreate kind as one control-plane plus two worker
nodes so required pod anti-affinity can schedule:

```sh
just kind-reset
```

When `ciliumnetworkpolicies.cilium.io` is absent, the ArgoCD phase omits
real-cluster-only applications such as the full `k3s-apps` ApplicationSet,
Longhorn, Cilium, and `crd-schema-publisher`.

When Cilium CRDs are present, bootstrap still withholds
`ApplicationSet/k3s-apps` from the first ArgoCD apply. It applies the Hubble CA
chain, reconciles `Application/cilium`, waits for the Hubble server and relay
certificates, restarts Cilium/Hubble if stale takeover certs were replaced, and
only then applies `ApplicationSet/k3s-apps`.

For a closer foundation test on Apple Silicon, use the Lima harness under
`hack/bootstrap/lima/`. It creates one K3s server and two agents, runs the
external `k3s-ansible` checkout, bootstraps home-ops with `--profile
foundation`, validates current Cilium BGP CRDs/manifests, and fails if backup
writers such as `powerdns`, `hass`, VolSync, Velero, or CNPG backup resources
are created. It also requires the foundation ArgoCD Applications for Cilium and
Dragonfly Operator to be `Synced` and `Healthy`.

The foundation profile applies the Hubble cert-manager issuer chain before
ArgoCD reconciles the Cilium Helm chart. During takeover from the initial
Ansible-installed Cilium, it rotates stale Hubble cert Secrets that were not
issued by `Issuer/cilium-hubble-ca` and restarts Cilium/Hubble after the
replacement certs are ready.

By default the disposable server VM uses `4` CPU and `6GiB` memory, while each
agent VM uses `2` CPU and `3GiB` memory. Override with `LIMA_SERVER_CPUS`,
`LIMA_SERVER_MEMORY_GIB`, `LIMA_AGENT_CPUS`, or `LIMA_AGENT_MEMORY_GIB` when
needed.

The Lima inventory uses the server VM IP as the K3s API endpoint. Production
`k3s-ansible` group vars still pin kube-vip to `v1.1.2`, but Lima's default
user-mode networking is not a reliable place to validate an ARP VIP join path.
The initial Cilium install uses `netkit` so pod endpoints are created with the
same datapath mode used by the steady-state ArgoCD Cilium chart.

The Lima wrapper keeps Cilium masquerading enabled when it applies the
foundation ArgoCD resources. This is intentionally Lima-only: the real cluster
can route pod CIDRs, but Lima's user-mode network cannot route pod CIDRs back
to pods, so pod DNS and external egress require masquerading.

After the Ansible phase, the Lima harness imports the context
`lima-home-ops-k3s-test` into the local kubeconfig and keeps an SSH tunnel open
for the K3s API. Use `just bootstrap-lima-kubecontext` to refresh only that
context and tunnel. `just bootstrap-lima-delete` stops the recorded tunnel.

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
authoritative. The seed phase tries `op read` and, when that fails with
interactive stdin, falls back to `op signin` without logging the returned
session export. Keep 1Password CLI desktop app integration enabled and the app
unlocked for local interactive bootstrap runs, or authenticate `op` before
invoking the script. Leave `--op-account` unset unless you need to
disambiguate accounts; when you do set it, use the shorthand from
`op account list`, such as `my`.

If script-managed `op` auth is not appropriate, let your shell run `op read`
and pipe the manifest to the seed phase:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | ./hack/bootstrap/bootstrap.sh --kube-context kind-home-ops-bootstrap --only-phase seed-secret --seed-secret-stdin --yes
```
