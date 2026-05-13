# Just Bootstrap Runbook

This page documents the `just` recipes for bootstrapping a fresh cluster into
the minimum state ArgoCD needs before it can take over normal GitOps sync.

The bootstrap runner lives in `hack/bootstrap/`. It assumes the Ansible wrapper
or an equivalent process has already produced a working Kubernetes API,
kubeconfig, and initial Cilium install before this runner is used on the real
cluster.

## Prerequisites

- `just`
- `kubectl`
- `kustomize`
- `helm`
- `yq`
- `jq`
- `op`
- `shellcheck`
- `ansible-playbook` and `ansible-galaxy` for Ansible-based bootstrap
- `limactl` for the optional Lima VM bootstrap tests
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

If the target cluster already has Cilium CRDs, bootstrap still delays
`ApplicationSet/k3s-apps`. The ArgoCD phase applies Hubble CA resources and the
explicit foundation Applications first; the wait phase then waits for
`Application/cilium` to be `Synced` and `Healthy`, waits for Hubble server and
relay certificates, restarts Cilium/Hubble when stale takeover certs were
replaced, and applies `ApplicationSet/k3s-apps` only after that completes.

## Local Lima Foundation Test

The Lima path is a closer end-to-end bootstrap rehearsal for Apple Silicon. It
creates one K3s server and two K3s agents, runs the selected Ansible backend,
then runs home-ops bootstrap with `--profile foundation`.

Defaults:

- Lima cluster prefix: `home-ops-k3s-test`
- foundation VM shape: one server and two agents
- Ansible backend: `home-ops` by default, using
  `hack/bootstrap/ansible/home-ops/`
- home-ops checkout: the current working tree
- server VM size: `4` CPU and `6GiB` memory
- foundation agent VM size: `2` CPU and `3GiB` memory
- guest storage prerequisites: `open-iscsi` and `nfs-common` are installed on
  each VM before Ansible runs so Longhorn block and RWX volumes can mount
- Cilium version: derived from `Application/cilium.spec.source.targetRevision`
  and rendered into the selected Ansible backend
- Cilium datapath mode: `netkit`, matching the steady-state ArgoCD values
- Cilium takeover: Hubble CA resources are applied before ArgoCD Cilium, and
  stale Hubble cert Secrets from the initial Ansible install are rotated
- Dragonfly Operator: reconciled through ArgoCD without optional
  `ServiceMonitor` or `GrafanaDashboard` resources in foundation mode
- K3s API endpoint: the server VM IP, not kube-vip
- Local kube context: `lima-home-ops-k3s-test`

The shape and size can be overridden with `LIMA_SERVER_COUNT`,
`LIMA_SERVER_CPUS`, `LIMA_SERVER_MEMORY_GIB`, `LIMA_AGENT_COUNT`,
`LIMA_AGENT_CPUS`, `LIMA_AGENT_MEMORY_GIB`, and `LIMA_K3S_MASTER_TAINT`.

Run the full disposable VM flow:

```sh
just bootstrap-lima-fresh
```

Or run it phase by phase:

```sh
just bootstrap-lima-create
just bootstrap-lima-ansible
just bootstrap-lima-bootstrap
just bootstrap-lima-validate
```

The external compatibility backend can be tested through the same Lima flow:

```sh
BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible just bootstrap-lima-ansible
```

`bootstrap-lima-ansible` imports or updates the local kube context and starts a
persistent SSH tunnel for the K3s API. Re-run this if you only need to refresh
the context:

```sh
just bootstrap-lima-kubecontext
kubectl --context lima-home-ops-k3s-test get nodes
```

If this agent process is not signed in to 1Password, stream the seed Secret from
your own shell instead:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | just bootstrap-lima-bootstrap-stdin
```

Use the app-profile variant for the same stdin seed flow:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | just bootstrap-lima-bootstrap-apps-stdin
```

Delete the VMs:

```sh
just bootstrap-lima-delete
```

Deleting the Lima VMs also stops the recorded local API tunnel.

Foundation mode always omits the broad `ApplicationSet/k3s-apps`. The Lima
validation requires the foundation Cilium and Dragonfly Operator Applications to
be `Synced` and `Healthy`. It also fails if backup-writing or real-workload
resources appear, including `Application/powerdns`, `Application/hass`, CNPG
`ScheduledBackup` and `ObjectStore` resources, VolSync `ReplicationSource`,
Velero `Schedule`, and the external-dns deployment. The real 1Password seed may
be used because the profile does not create those writers.

The Lima inventory deliberately disables kube-vip while keeping the same
K3s/Cilium/BGP versions as the real bootstrap path. The live inventory still
pins kube-vip to `v1.1.2`; Lima's default user-mode networking is not a
reliable validation target for ARP VIP behavior.

The Lima wrapper also keeps Cilium masquerading enabled when it applies the
foundation ArgoCD resources. The real cluster disables Cilium masquerading
because its network can route pod CIDRs; Lima's user-mode network cannot route
pod CIDRs back to pods, so pod DNS and external egress require masquerading in
the disposable test cluster.

## Local Lima App Test

After the foundation profile is healthy, run the app profile against the same
Lima cluster. The app profile is materially heavier than foundation mode and
defaults to four schedulable worker nodes with `4` CPU, `6GiB` memory,
and enough disk for Longhorn restore, replica scheduling, and one-node
replacement testing. The app-specific recipes create `120GiB` VM disks and
preflight requires at least `100GiB`
allocatable ephemeral storage per schedulable worker. Use the app-specific
create/ansible recipes if running phase by phase:

```sh
just bootstrap-lima-delete
just bootstrap-lima-create-apps
just bootstrap-lima-ansible-apps
```

Then bootstrap and validate:

```sh
just bootstrap-lima-bootstrap-apps
just bootstrap-lima-validate-apps
```

Or recreate the VMs and run the app profile in one step:

```sh
just bootstrap-lima-fresh-apps
```

To validate app-level changes from a branch before they merge to `master`, push
the branch first and point the generated Applications at it:

```sh
LIMA_APPSET_TARGET_REVISION=feat/my-branch just bootstrap-lima-fresh-apps
```

The app profile uses `--profile lima-apps`. It is intentionally still scoped:
it restores Gateway wildcard TLS Secrets from 1Password, waits for
`gateway/external-wildcard`, `gateway/mgmt-wildcard`, and
`gateway/guest-wildcard` to contain `tls.crt` and `tls.key`, applies
external-snapshotter from `apps/kube-system/external-snapshotter`, then applies
the existing `ApplicationSet/k3s-apps` name with a Lima-only allowlist.
Validation waits for allowlisted ArgoCD Application sync operations and then
requires those Applications to become `Synced` and `Healthy`. It then requires
all non-completed pods to settle to Running and Ready.

The first allowlist includes cert-manager, external-secrets, kube-system
support resources, Longhorn support resources, CNPG, Envoy Gateway, Gateway,
`hass`, and `powerdns`. The rendered desired state removes Gateway ACME
annotations, removes `PushSecret` resources, removes VolSync
`ReplicationSource`, removes CNPG backup schedules, removes active CNPG
Cluster plugins while keeping externalCluster recovery configuration, removes
the Longhorn backup `RecurringJob`, and removes kube-vip from the disposable
Lima cluster. VolSync restore destinations keep their retain storage class
because the restored snapshot must survive long enough to populate the final
PVC.

The app profile also installs Lima-only `ValidatingAdmissionPolicy` guardrails
that deny known external writer resources such as `PushSecret`,
`ClusterPushSecret`, ACME `Order`/`Challenge`, VolSync `ReplicationSource`,
CNPG backup resources, Velero backup resources, external-dns `DNSEndpoint`, and
Longhorn backup `RecurringJob`, plus active CNPG Cluster plugins. The
render-time patches are the primary safety control; admission is there to fail
closed if a future manifest reintroduces a writer or archive-backed active
plugin.

## Real Cluster Bootstrap

### Live Ansible Wrapper

The physical-node Ansible wrapper lives in `hack/bootstrap/ansible/`. It uses
the in-repo `home-ops` backend by default and renders site-specific inventory
and values from home-ops. The external `../k3s-ansible` checkout remains
available as an explicit compatibility backend with
`BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible`.

Render the live plan without changing nodes:

```sh
just bootstrap-live-ansible-plan
```

Render through the external compatibility backend:

```sh
BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible just bootstrap-live-ansible-plan
```

This writes non-secret generated inventory under
`hack/bootstrap/.out/ansible-live/` and prints the target hosts, first
control-plane node, K3s version, Cilium version/config, kube-vip tag, and API
endpoint.

The live `k3s_token` is stored in 1Password at:

```text
op://Kubernetes/k3s-bootstrap/k3s_token
```

For an existing cluster, import the already-running server token explicitly
before the first wrapper-managed run:

```sh
just bootstrap-ansible-import-token
```

The import command reads the token from the first control-plane node and writes
it to 1Password. It does not run Ansible or Kubernetes bootstrap and does not
log the token.

Run Ansible convergence only:

```sh
just bootstrap-live-ansible
```

Run the Kubernetes bootstrap only, after K3s already exists:

```sh
just bootstrap-live-kube default
```

Run both behind one wrapper-level confirmation prompt:

```sh
just bootstrap-live-full
```

The live wrapper derives values that must match GitOps desired state, including
the K3s version from `apps/system-upgrade`, Cilium Helm values from the explicit
ArgoCD Application, Cilium BGP resources from `apps/kube-system/cilium`, and
the kube-vip tag/API VIP from `apps/kube-system/kube-vip`. If the checked-in
live overrides try to set one of those derived-owned values differently, the
render fails instead of silently choosing one.

Keep `../k3s-ansible` close to upstream when using the external compatibility
backend. The wrapper does not require its sample defaults to match the homelab;
it renders the homelab values as an overlay. The default `home-ops` backend
does not use the external checkout.

### Node Lifecycle

Node lifecycle helpers live in `hack/bootstrap/nodes/` and are for existing
clusters, not first-boot bootstrap. Worker lifecycle is intentionally split
into explicit operator steps. Control-plane nodes support status, read-only
delete preflight, drain, optional Longhorn eviction, delete, join, and
uncordon:

```sh
just node-live-status k3s-worker-0
just node-live-control-plane-status k3s-master-0
just node-live-control-plane-delete-preflight k3s-master-0
just node-live-drain k3s-master-1
just node-live-longhorn-evict k3s-master-1
just node-live-delete k3s-master-1
just node-live-refresh-ssh-host-key k3s-master-1
just node-live-join k3s-master-1
just node-live-uncordon k3s-master-1
just node-live-drain k3s-worker-0
just node-live-longhorn-evict k3s-worker-0
just node-live-delete k3s-worker-0
just node-live-refresh-ssh-host-key k3s-worker-0
just node-live-join k3s-worker-0
just node-live-uncordon k3s-worker-0
```

The Lima equivalents use the `node-lima-*` group:

```sh
just node-lima-status home-ops-k3s-test-agent-1
just node-lima-control-plane-status home-ops-k3s-test-server-1
just node-lima-control-plane-delete-preflight home-ops-k3s-test-server-1
just node-lima-drain home-ops-k3s-test-server-2
just node-lima-longhorn-evict home-ops-k3s-test-server-2
just node-lima-delete home-ops-k3s-test-server-2
just node-lima-refresh-ssh-host-key home-ops-k3s-test-server-2
just node-lima-join home-ops-k3s-test-server-2
just node-lima-uncordon home-ops-k3s-test-server-2
just node-lima-drain home-ops-k3s-test-agent-1
just node-lima-longhorn-evict home-ops-k3s-test-agent-1
just node-lima-delete home-ops-k3s-test-agent-1
just node-lima-refresh-ssh-host-key home-ops-k3s-test-agent-1
just node-lima-join home-ops-k3s-test-agent-1
just node-lima-uncordon home-ops-k3s-test-agent-1
```

Control-plane drain, Longhorn eviction, and delete are guarded by the
embedded-etcd member preflight.
The control-plane status command is read-only and exists to validate that future
procedure: it reports inventory/Ready quorum math and probes the selected server
for K3s service state, datastore files, etcd listeners, and `etcdctl`
availability. The home-ops Ansible backend derives the upstream `etcdctl`
version from the K3s release's embedded Etcd version, verifies the release
archive checksum, and installs `etcdctl` on control-plane nodes so
embedded-etcd member inspection is available after node convergence.
The control-plane delete preflight is also read-only. It queries etcd from an
alternate Ready control-plane, maps the target node to exactly one etcd member,
checks quorum math, and prints the future `etcdctl member remove` command
without running it. Single-server Lima clusters cannot pass that HA preflight
because there is no alternate etcd member to query.

For normal node maintenance or reboots, run drain and then uncordon. Drain only
requires ordinary workloads to move and Longhorn volumes to detach from the
target node. It does not require every Longhorn volume to stay healthy, because
three-replica volumes on exactly three storage nodes will be temporarily
degraded while one node is drained.

The delete step is deliberately conservative. Worker delete stops and disables
`k3s-node` through Ansible before deleting the Kubernetes `Node` and the K3s
node-password Secret, so the old node cannot immediately re-register.
For control-plane nodes, run the same Longhorn eviction helper after drain and
before delete when Longhorn is installed. Delete requires the node to be
cordoned and empty, stops and disables `k3s`, rechecks the preflight from a
remaining control-plane, creates a fresh K3s etcd snapshot, removes the target
etcd member, then deletes the Kubernetes `Node` and node-password Secret. If
the target is the first inventory master, live runs require the `default`
context to use the stable API endpoint; Lima runs retarget the local API tunnel
to an alternate Ready control-plane before stopping the target and may update
the Lima kubeconfig context to a different local port if the default tunnel
port is already occupied. For node replacement, run `node-*-longhorn-evict`
after drain and before delete. The eviction helper disables Longhorn scheduling
for the target, requests replica eviction, and fails before mutating anything if
the remaining eligible storage nodes cannot hold the maximum configured replica
count. Delete and eviction completion allow stopped stale target-node replica
records only after the desired healthy replica count exists on other nodes.
Delete also clears stale pod objects still bound to the removed node and waits
for the Longhorn node resource to disappear before a same-name join can
proceed.

Join uses the generated home-ops Ansible playbook for the node role and starts
the K3s service with `node.home-ops.sh/joining=true:NoSchedule`. First-master
control-plane rejoin passes an alternate Ready control-plane InternalIP as the
temporary K3s `--server` endpoint so the replacement does not try to join
through itself. After the node object appears, the helper cordons it while
Cilium settles. The uncordon helper removes the taint from the rendered K3s
service and finalizes the server back to the normal stable endpoint, restarts
the service if needed, removes the live taint, waits for Cilium, verifies
Longhorn is ready to schedule on the node, uncordons, and then verifies
Longhorn marks the node schedulable.

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
just bootstrap /path/to/home-ops
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
