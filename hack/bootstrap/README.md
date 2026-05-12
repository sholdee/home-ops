# Home Ops Bootstrap

This directory contains the local bootstrap tooling for fresh-cluster takeover.
It covers two layers:

1. a guarded Ansible wrapper for physical node convergence
2. the Kubernetes bootstrap runner that seeds the minimum dependencies needed
   before ArgoCD can take over

For the operator-facing `just` runbook, see
[`docs/just-bootstrap.md`](../../docs/just-bootstrap.md).

The Kubernetes runner is intentionally outside normal GitOps app state. It
seeds the minimum dependencies needed for ArgoCD to take over:

1. Seed `Secret/external-secrets/op-credentials` from 1Password CLI.
2. Install required CRDs.
3. Bootstrap cert-manager.
4. Bootstrap External Secrets and 1Password Connect.
5. Seed Gateway wildcard TLS Secrets from 1Password when the selected profile
   will apply normal apps.
6. Bootstrap Dragonfly Operator.
7. Apply narrow ArgoCD dependencies.
8. Apply the canonical `apps/argocd` render.
9. Wait for ArgoCD components.
10. Run conservative Helm takeover cleanup and audit.

The physical-node Ansible wrapper is the supported way to converge K3s nodes
for this repo. It renders the homelab inventory and GitOps-owned values before
calling Ansible. The default backend is the in-repo
`hack/bootstrap/ansible/home-ops/` implementation. The external
`../k3s-ansible` checkout remains available as an explicit compatibility
backend for side-by-side comparison.

Render the live Ansible plan without changing nodes:

```sh
just bootstrap-live-ansible-plan
```

Run a Kubernetes bootstrap dry-run against the current kube context:

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
then waits for the explicit platform Applications for Dragonfly Operator,
Grafana Operator, Longhorn, Reloader, and VolSync. Before releasing
`ApplicationSet/k3s-apps`, it also applies external-snapshotter from
`apps/kube-system/external-snapshotter` so VolSync restore workloads have
snapshot CRDs/controller available.

For a closer foundation test on Apple Silicon, use the Lima harness under
`hack/bootstrap/lima/`. It creates one K3s server and two agents, runs the
selected Ansible backend, bootstraps home-ops with `--profile foundation`,
validates current Cilium BGP CRDs/manifests, and fails if backup writers such
as `powerdns`, `hass`, VolSync, Velero, or CNPG backup resources are created.
It also requires the foundation ArgoCD Applications for Cilium and Dragonfly
Operator to be `Synced` and `Healthy`.

The foundation profile applies the Hubble cert-manager issuer chain before
ArgoCD reconciles the Cilium Helm chart. During takeover from the initial
Ansible-installed Cilium, it rotates stale Hubble cert Secrets that were not
issued by `Issuer/cilium-hubble-ca` and restarts Cilium/Hubble after the
replacement certs are ready.

After foundation is working, the Lima harness can run the narrower app profile:

```sh
just bootstrap-lima-bootstrap-apps
just bootstrap-lima-validate-apps
```

If an app-profile test needs app manifests from a branch before they merge to
`master`, push the branch and set `LIMA_APPSET_TARGET_REVISION` for the Lima
bootstrap run.

The `lima-apps` profile restores Gateway wildcard TLS Secrets from 1Password
through `ExternalSecret` resources before applying normal apps. It then applies
external-snapshotter from `apps/kube-system/external-snapshotter` so VolSync
restore workloads have snapshot CRDs/controller available, then applies the
existing `ApplicationSet/k3s-apps` name with a Lima-only allowlist and
render-time patches. The first app profile includes cert-manager,
external-secrets, kube-system support resources, Longhorn support resources,
CNPG, Envoy Gateway, Gateway, `hass`, and `powerdns`. It removes Gateway ACME
annotations, disables CNPG WAL archiving while keeping recovery configuration,
deletes backup schedules and VolSync upload sources, and applies Lima-only
admission policies that deny known external writer resources. VolSync restore
destinations keep retain storage so the restored snapshot can populate the
final PVC.

By default the disposable foundation shape is one server VM using `4` CPU and
`6GiB` memory plus two agent VMs using `2` CPU and `3GiB` memory. The app-profile
`just` recipes create three larger agent VMs using `4` CPU and `6GiB` memory
each with `120GiB` disks, because the allowed app set includes topology-spread
workloads, Longhorn, VolSync restores, retained restore source volumes, and
database operators. Override with `LIMA_SERVER_COUNT`, `LIMA_SERVER_CPUS`,
`LIMA_SERVER_MEMORY_GIB`, `LIMA_AGENT_COUNT`, `LIMA_AGENT_CPUS`,
`LIMA_AGENT_MEMORY_GIB`, `LIMA_K3S_MASTER_TAINT`, or `LIMA_DISK_GIB` when
needed.

Lima VM creation installs `open-iscsi` and `nfs-common` before Ansible runs.
Longhorn needs the iSCSI initiator for block volumes, and RWX volumes need the
NFS mount helper on each node.

The Lima inventory uses the server VM IP as the K3s API endpoint. Lima's
default user-mode networking is not a reliable place to validate an ARP VIP
join path, so the Lima overlay disables kube-vip while still using the same
K3s/Cilium/BGP values as the live wrapper where they matter. The initial Cilium
install uses `netkit` so pod endpoints are created with the same datapath mode
used by the steady-state ArgoCD Cilium chart.

The Lima wrapper keeps Cilium masquerading enabled when it applies the
foundation ArgoCD resources. This is intentionally Lima-only: the real cluster
can route pod CIDRs, but Lima's user-mode network cannot route pod CIDRs back
to pods, so pod DNS and external egress require masquerading.

After the Lima Ansible phase, the Lima harness imports the context
`lima-home-ops-k3s-test` into the local kubeconfig and keeps an SSH tunnel open
for the K3s API. Use `just bootstrap-lima-kubecontext` to refresh only that
context and tunnel. `just bootstrap-lima-delete` stops the recorded tunnel.

## Live Ansible Bootstrap

`hack/bootstrap/ansible/` orchestrates physical-node K3s convergence for the
cluster. By default it uses the in-repo `home-ops` backend, while the external
`../k3s-ansible` checkout remains available with
`BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible` or `--backend k3s-ansible`.

The `home-ops` backend is a small home-ops-specific playbook for Debian-family,
systemd nodes. It supports the current live and Lima shapes, installs kube-vip
and a minimal bootstrap Cilium, fetches kubeconfig into the same `.out/` flow,
and leaves ArgoCD takeover plus the post-Cilium kube-proxy disable phase to the
existing wrapper. It is intentionally not a broad replacement for
`k3s-ansible`: it does not support reset/destroy, K3s upgrades, non-Debian OS
families, or alternate CNIs.

The live inventory is intentionally non-secret and checked in under
`hack/bootstrap/ansible/inventory/live/`. Generated inventory, group vars, and
kubeconfigs are written under `hack/bootstrap/.out/ansible-live/`.

Render a non-mutating plan:

```sh
just bootstrap-live-ansible-plan
```

Render the same plan through the external compatibility backend:

```sh
BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible just bootstrap-live-ansible-plan
```

For the external `k3s-ansible` backend, the rendered vars are a deterministic
merge of:

1. `k3s-ansible` sample vars.
2. live home-ops overrides such as host facts, SSH user, interface names, and
   timezone.
3. values derived from home-ops manifests, including K3s version, Cilium
   version/config, Cilium BGP settings, kube-vip tag, and API VIP.
4. runtime secret references.

For the default `home-ops` backend, the external sample vars are omitted; the
same live overrides, derived values, and runtime secret references are merged
directly.

For live inventory, derived-owned values fail on conflict instead of silently
overriding human input. This keeps Ansible bootstrap aligned with the GitOps
state ArgoCD will enforce later.

The external `k3s-ansible` defaults do not need to match home-ops versions or
network settings when that backend is explicitly selected. Keep that checkout
close to upstream and let this wrapper render the homelab-specific K3s, Cilium,
BGP, kube-vip, API endpoint, and control-plane taint values.

Initial K3s server args intentionally leave kube-proxy enabled so Ansible
bootstrap can complete before Cilium owns Service routing. After the selected
backend installs and waits for Cilium, the wrapper runs a home-ops post-Cilium
playbook. When the derived Cilium config has
`kube_proxy_replacement: true`, that playbook writes
`/etc/rancher/k3s/config.yaml.d/90-home-ops-kube-proxy.yaml` with
`disable-kube-proxy: true`, then restarts K3s servers one at a time and waits
for each node plus Cilium to become ready.

The live K3s token is stored at `op://Kubernetes/k3s-bootstrap/k3s_token`.
Normal runs load it from 1Password. If a fresh cluster has no remote token and
the 1Password item is missing, the wrapper generates and stores a token. If an
existing cluster already has a token, import it explicitly first:

```sh
just bootstrap-ansible-import-token
```

Then converge nodes with Ansible:

```sh
just bootstrap-live-ansible
```

Use the external compatibility backend explicitly when comparing behavior:

```sh
BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible just bootstrap-live-ansible
```

Run only the Kubernetes bootstrap after K3s already exists:

```sh
just bootstrap-live-kube default
```

Or run Ansible and then the home-ops Kubernetes bootstrap in one guarded
command:

```sh
just bootstrap-live-full
```

The live Ansible run prompts for explicit confirmation by default and prints
the target hosts, first control-plane host, derived K3s/Cilium versions, and API
endpoint before making changes.

## Node Lifecycle

`hack/bootstrap/nodes/` contains existing-cluster node lifecycle helpers. The
worker path is split into explicit status, drain, optional Longhorn eviction,
delete, join, and uncordon steps:

```sh
just node-live-status k3s-worker-0
just node-live-drain k3s-worker-0
just node-live-longhorn-evict k3s-worker-0
just node-live-delete k3s-worker-0
just node-live-refresh-ssh-host-key k3s-worker-0
just node-live-join k3s-worker-0
just node-live-uncordon k3s-worker-0
just node-lima-status home-ops-k3s-test-agent-1
```

Control-plane lifecycle is intentionally refused until the embedded-etcd member
procedure is proven. Worker delete stops and disables `k3s-node` before deleting
the Kubernetes Node and node-password Secret. If Longhorn is installed, delete
also requires Longhorn scheduling to be disabled for the target node and all
target-node replicas and attached volumes to be gone.

For normal maintenance or reboot work, use `drain` and `uncordon` only. The
drain helper allows the expected temporary Longhorn degraded state after
workloads leave the node, which matters when three-replica volumes are spread
across exactly three storage nodes. The `longhorn-evict` helper is only for
node replacement; it fails before mutating Longhorn if the remaining storage
nodes cannot hold the maximum configured replica count.

Worker join starts the agent with
`node.home-ops.sh/joining=true:NoSchedule`, then cordons the node. The uncordon
helper removes that taint from the rendered agent service and live Node, waits
for Cilium, verifies Longhorn is ready to schedule on the node, uncordons, and
then verifies Longhorn marks the node schedulable.

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
