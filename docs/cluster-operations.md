# Cluster Operations Runbook

This is the operator-facing runbook for bootstrap, validation, and node
lifecycle recipes in the root `justfile`.

Bootstrap has two jobs:

1. Converge K3s nodes with the Ansible wrapper when needed.
2. Seed the minimum Kubernetes state ArgoCD needs before it can take over.

The implementation lives under `hack/bootstrap/`. Prefer `just` recipes for
normal operation; direct scripts are implementation details except for narrow
debugging cases.

## Prerequisites

Required for all bootstrap work:

- `just`
- `kubectl`
- `kustomize`
- `helm`
- `yq`
- `jq`
- `op`

Required for local validation:

- `shellcheck`
- `bats`

Required for Ansible-backed node convergence:

- `ansible-playbook`
- `ansible-galaxy`

Required for Lima VM tests:

- `limactl`

1Password must have access to:

```text
op://Kubernetes/op-credentials/op-credentials.yaml
```

## Command Map

Start with the recipe list when unsure:

```sh
just --list
```

Common validation:

| Goal | Recipe |
| --- | --- |
| Run pre-commit plus bootstrap tests | `just check` |
| Run only bootstrap ShellCheck and BATS | `just bootstrap-test` |
| Audit current kube context | `just bootstrap-audit` |
| Show current and target cluster status | `just context` |
| List ArgoCD Applications | `just argocd-apps` |
| List ArgoCD ApplicationSets | `just argocd-appsets` |

Kind:

| Goal | Recipe |
| --- | --- |
| Create the kind cluster | `just kind-create` |
| Show kind status | `just kind-status` |
| Bootstrap kind | `just kind-bootstrap` |
| Recreate and bootstrap kind | `just kind-fresh` |
| Seed only the 1Password credential | `just kind-bootstrap-seed` |
| Resume kind from a phase | `just kind-bootstrap-resume bootstrap-crds` |
| Dry-run after CRDs exist | `just kind-bootstrap-dry-run` |
| Delete kind | `just kind-delete` |

Lima foundation:

| Goal | Recipe |
| --- | --- |
| Create VMs | `just lima-create` |
| Run Ansible | `just lima-ansible` |
| Run Kubernetes bootstrap | `just lima-bootstrap` |
| Validate foundation state | `just lima-validate` |
| Full fresh flow | `just lima-fresh` |
| Show Lima status | `just lima-status` |
| Refresh kube context and API tunnel | `just lima-context` |
| Delete VMs | `just lima-delete` |

Lima app profile:

| Goal | Recipe |
| --- | --- |
| Create app-sized VMs | `just lima-apps-create` |
| Run Ansible on app-sized VMs | `just lima-apps-ansible` |
| Run app-profile bootstrap | `just lima-apps-bootstrap` |
| Validate app-profile safety | `just lima-apps-validate` |
| Full fresh app flow | `just lima-apps-fresh` |

Ansible and active-context bootstrap:

| Goal | Recipe |
| --- | --- |
| Render live Ansible plan | `just ansible-plan` |
| Import existing K3s token to 1Password | `just ansible-import-token` |
| Run live Ansible only | `just ansible-run` |
| Run live Ansible plus Kubernetes bootstrap | `just ansible-bootstrap` |
| Run Kubernetes bootstrap against the active context | `just bootstrap` |
| Audit active context state | `just bootstrap-audit` |
| Dry-run bootstrap against the active context | `just bootstrap-dry-run` |
| Dry-run one bootstrap phase | `just bootstrap-phase argocd` |

Node lifecycle:

| Goal | Recipe |
| --- | --- |
| List live nodes | `just node-list` |
| Plan additive-only live node joins | `just node-converge-plan` |
| Join missing live inventory nodes after confirmation | `just node-converge` |
| Discover live node network reimage identity | `just node-reimage-plan <node>` |
| Render live node network reimage metadata | `just node-reimage-metadata <node> <image-url> <sha256>` |
| Render live node Raspberry Pi image source | `just node-reimage-image-source <node>` |
| Build live node Raspberry Pi image | `just node-reimage-build <node>` |
| Reboot a drained live node | `just node-reboot <node>` |
| Join one explicit live node | `just node-join <node>` |
| Finalize and uncordon one live node | `just node-uncordon <node>` |
| Serve recorded live node reimage artifact | `just node-reimage-serve <node> <host>` |
| Stage, tryboot reboot, and refresh SSH key | `just node-reimage-apply <node>` |
| Clean up recorded live image server | `just node-reimage-cleanup <node>` |
| Stage live node network reimage | `just node-reimage-stage <node> <image-url> <sha256>` |
| Reboot into staged network reimage | `just node-reimage-reboot <node>` |
| Plan additive-only Lima node joins | `just node-lima-converge-plan` |
| Join missing Lima inventory nodes after confirmation | `just node-lima-converge` |
| Join missing Lima inventory nodes without prompting | `just node-lima-converge-yes` |

## Validation Ladder

Use the smallest validation that covers the change:

1. `just bootstrap-test` for Bash parsing, rendering, and helper behavior.
2. `just kind-fresh` for clean Kubernetes bootstrap ordering.
3. `just kind-bootstrap-dry-run` for server-side validation after CRDs exist.
4. `just lima-fresh` for Cilium takeover and core operators.
5. `just lima-apps-fresh` for Longhorn, VolSync, CNPG, and app safety.
6. `just bootstrap-audit` for active-context read-only inventory.
7. `just bootstrap-dry-run` for active-context API/admission validation.

Do not run a live non-dry-run bootstrap from an unmerged branch. Use dry-run
from the branch, then let merged `master` and ArgoCD own steady state.

For PVC corruption where VolSync clone pods, application mounts, or CNPG
replica joins fail with storage errors, use
[PVC Recovery](pvc-recovery.md).

## Cluster Inspection

Use `context` for a quick read-only look at the target context:

```sh
just context
just context lima-home-ops-k3s-test
```

With no argument, it targets the active kube context. Pass a context name to
inspect a different target. It prints the current kubeconfig context, the
target context, nodes, and an ArgoCD Application summary when ArgoCD is
available.

List ArgoCD Applications or ApplicationSets:

```sh
just argocd-apps
just argocd-apps cilium
just argocd-apps cilium default
just argocd-apps cilium lima-home-ops-k3s-test
just argocd-appsets
just argocd-appsets k3s-apps
just argocd-appsets k3s-apps default
just argocd-appsets k3s-apps lima-home-ops-k3s-test
```

With no context argument, `argocd-apps`, `argocd-appsets`, `app-dry-run`, and
`app-diff` target the active kube context. Pass a context name when you want a
specific cluster.

## Kind Workflow

Kind uses the repo-specific cluster name `home-ops-bootstrap`, which creates
context `kind-home-ops-bootstrap`.

Override only when needed:

```sh
KIND_CLUSTER=my-test-cluster just kind-fresh
```

Typical clean run:

```sh
just kind-fresh
```

Check current kind state:

```sh
just kind-status
```

Phase-by-phase run:

```sh
just kind-delete
just kind-create
just kind-bootstrap-seed
just kind-bootstrap-resume bootstrap-crds
```

After the first successful bootstrap:

```sh
just kind-bootstrap-dry-run
```

Do not use `kind-bootstrap-dry-run` as the first command after `kind-delete`.
Server-side dry-run validates objects but does not persist CRDs, so later CRs
cannot validate until their CRDs exist.

Kind intentionally omits real-cluster-only resources when Cilium CRDs are
absent: `ApplicationSet/k3s-apps`, Cilium apps, Longhorn, and
`crd-schema-publisher`.

## Lima Foundation Workflow

The foundation profile is the closer end-to-end rehearsal for a fresh cluster.
It creates disposable VMs, runs Ansible, imports kubeconfig through an SSH API
tunnel, and bootstraps with `--profile foundation`.

Defaults:

| Setting | Default |
| --- | --- |
| Cluster prefix | `home-ops-k3s-test` |
| Local context | `lima-home-ops-k3s-test` |
| Server shape | one VM, `4` CPU, `6GiB` memory |
| Agent shape | two VMs, `2` CPU, `3GiB` memory |
| Disk | `30GiB` |
| Master taint | enabled |
| Ansible backend | `home-ops` |

Run everything:

```sh
just lima-fresh
```

Or run phase by phase:

```sh
just lima-create
just lima-ansible
just lima-bootstrap
just lima-validate
```

The Lima Ansible recipe imports or updates the local kube context and keeps the
API tunnel running. Refresh only that context and tunnel with:

```sh
just lima-context
```

Delete the VMs and recorded tunnel:

```sh
just lima-delete
```

Check current Lima state:

```sh
just lima-status
```

Useful overrides:

- `LIMA_CLUSTER_NAME`
- `LIMA_SERVER_COUNT`
- `LIMA_SERVER_CPUS`
- `LIMA_SERVER_MEMORY_GIB`
- `LIMA_AGENT_COUNT`
- `LIMA_AGENT_CPUS`
- `LIMA_AGENT_MEMORY_GIB`
- `LIMA_DISK_GIB`
- `LIMA_K3S_MASTER_TAINT`

The Lima wrapper installs `open-iscsi` and `nfs-common` before Ansible so
Longhorn block and RWX volumes can mount.

## Lima App Workflow

The app profile should use the app-sized Lima shape, not the smaller
foundation shape.

Run the full app-sized flow:

```sh
just lima-apps-fresh
```

Or run it phase by phase:

```sh
just lima-apps-delete
just lima-apps-create
just lima-apps-ansible
just lima-apps-bootstrap
just lima-apps-validate
```

The app recipes set:

```text
LIMA_AGENT_COUNT=4
LIMA_AGENT_CPUS=4
LIMA_AGENT_MEMORY_GIB=6
LIMA_DISK_GIB=120
LIMA_VALIDATE_APP_WAIT_SECONDS=3600
```

The app-profile preflight requires at least `100GiB` allocatable ephemeral
storage per schedulable worker.

To test app manifests from an unmerged branch, push the branch first:

```sh
LIMA_APPSET_TARGET_REVISION=feat/my-branch just lima-apps-fresh
```

The `lima-apps` profile transforms `ApplicationSet/k3s-apps` before ArgoCD
sees it. It first applies an infrastructure allowlist, waits for those apps,
then releases the workload allowlist.

Allowlisted app Applications:

- `cert-manager`
- `cnpg-system`
- `envoy-gateway-system`
- `external-secrets`
- `gateway`
- `hass`
- `kube-system`
- `longhorn-system`
- `powerdns`

The Lima validator also expects explicit platform Applications such as
`cilium` and `dragonfly-operator` to be healthy before app safety checks pass.

The app profile must not create external writers:

- `PushSecret` or `ClusterPushSecret`
- ACME `Order` or `Challenge`
- VolSync `ReplicationSource`
- CNPG `Backup` or `ScheduledBackup`
- active CNPG `Cluster.spec.plugins`
- Velero backup resources
- external-dns `DNSEndpoint`
- Longhorn backup `RecurringJob`

Render-time patches are the primary safety control. Lima-only
`ValidatingAdmissionPolicy` resources are fail-closed guardrails.

## Cilium And App Ordering

Bootstrap withholds `ApplicationSet/k3s-apps` until Cilium takeover is ready.

When Cilium CRDs exist, the ArgoCD phase applies Hubble CA resources and the
explicit Cilium Application first. The wait phase then waits for Cilium sync,
Hubble server and relay certificates, and Cilium health.

If stale Hubble cert Secrets from the bootstrap install were replaced,
bootstrap restarts Cilium and Hubble relay so they load the new certs.

Before normal apps are released, bootstrap applies
`apps/kube-system/external-snapshotter` so VolSync restore workloads have the
snapshot CRDs and controller.

Lima keeps Cilium masquerading enabled because user-mode networking cannot
route pod CIDRs back to pods. The live cluster can route pod CIDRs and does not
need that Lima-only setting.

## Live Bootstrap Workflow

The live wrapper uses the in-repo `home-ops` Ansible backend by default. It
renders site-specific inventory and values from home-ops before running
Ansible.

The external `../k3s-ansible` checkout is still available for comparison:

```sh
BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible just ansible-plan
```

Render before mutating nodes:

```sh
just ansible-plan
```

For an existing cluster, import the already-running server token before the
first wrapper-managed run:

```sh
just ansible-import-token
```

Run Ansible only:

```sh
just ansible-run
```

Run Kubernetes bootstrap only after K3s exists. It targets the active kube
context:

```sh
just bootstrap
```

Run Ansible and Kubernetes bootstrap together:

```sh
just ansible-bootstrap
```

The live wrapper derives values that must match GitOps desired state:

- K3s version from `apps/system-upgrade`.
- Cilium version and values from the explicit ArgoCD Application.
- Cilium BGP resources from `apps/kube-system/cilium`.
- kube-vip tag and API VIP from `apps/kube-system/kube-vip`.

If checked-in live overrides conflict with a derived-owned value, rendering
fails instead of silently choosing one.

Initial K3s server args leave kube-proxy enabled so Ansible can complete before
Cilium owns Service routing. The post-Cilium playbook disables kube-proxy when
the derived Cilium config has `kube_proxy_replacement: true`.

The in-repo backend enables the K3s embedded registry mirror by default and
writes `registries.yaml` mirrors for the registries used by this cluster. Nodes
must be able to reach peer nodes on TCP `5001` for Spegel image sharing and
the API endpoint on TCP `6443`. A `registries.yaml` change restarts the
affected K3s server or agent so the mirror config is loaded.

The Ansible node-prep phase also manages host prerequisites such as Raspberry
Pi boot flags, swap, CPU governor, and fsnotify sysctls. Fresh nodes may reboot
automatically before they join K3s. Existing K3s nodes do not auto-reboot; if a
boot-level change is required, drain and reboot that node through the node
lifecycle flow, then rerun Ansible.

Host services are part of full Ansible convergence. All nodes get the RPi MQTT
reporter, control-plane nodes get the NUT client, and worker nodes get a
repository-scoped GitHub Actions runner for ARM64 image-pull verification.
Runner configuration mints a short-lived GitHub App installation token from
`HOME_OPS_GITHUB_APP_ID`, `HOME_OPS_GITHUB_APP_INSTALLATION_ID`, and
`HOME_OPS_GITHUB_APP_PRIVATE_KEY` fields on `op://Kubernetes/host-services`.
Store `HOME_OPS_GITHUB_APP_PRIVATE_KEY` as base64-encoded full PEM key data so
it fits cleanly in a 1Password field. The app installation needs repository
Administration permission set to read/write for `sholdee/home-ops`. After
changing the app permission, update or reinstall the app installation so the
installation grants the new permission. The runner installer is pinned and
checksum-verified; the installed runner keeps GitHub's normal runner
auto-update behavior.

Single-node join/finalize recipes keep Kubernetes convergence separate from
optional host services. After a replacement node is joined and uncordoned, run
`just ansible-host-services <node>` when you want to converge the reporter,
NUT client, or Actions runner explicitly.

Generated live inventory, vars, kubeconfigs, and run output are written under
`hack/bootstrap/.out/ansible-live/`.

## Node Lifecycle

Node lifecycle helpers are for existing clusters, not first boot.

Live examples:

```sh
just node-list
just node-status k3s-worker-0
just node-pods k3s-worker-0
just node-control-plane-status k3s-master-0
just node-control-plane-delete-preflight k3s-master-0
just node-converge-plan
just node-drain k3s-worker-0
just node-reboot k3s-worker-0
just node-longhorn-evict k3s-worker-0
just node-delete k3s-worker-0
just node-refresh-ssh-host-key k3s-worker-0
just node-join k3s-worker-0
just node-uncordon k3s-worker-0
just node-reimage-plan k3s-worker-0
just node-reimage-build k3s-worker-0
just node-reimage-serve k3s-worker-0 k3s-master-0
just node-reimage-apply k3s-worker-0
just node-reimage-cleanup k3s-worker-0
```

Lima examples:

```sh
just node-lima-list
just node-lima-status home-ops-k3s-test-agent-1
just node-lima-pods home-ops-k3s-test-agent-1
just node-lima-control-plane-status home-ops-k3s-test-server-1
just node-lima-control-plane-delete-preflight home-ops-k3s-test-server-1
just node-lima-converge-plan
just node-lima-drain home-ops-k3s-test-server-2
just node-lima-reboot home-ops-k3s-test-server-2
just node-lima-longhorn-evict home-ops-k3s-test-server-2
just node-lima-delete home-ops-k3s-test-server-2
just node-lima-refresh-ssh-host-key home-ops-k3s-test-server-2
just node-lima-join home-ops-k3s-test-server-2
just node-lima-uncordon home-ops-k3s-test-server-2
```

For normal maintenance, use drain, reboot when needed, and uncordon.
`longhorn-evict` is for node replacement.

`node-converge` is additive-only convenience after inventory edits. It joins
fresh inventory nodes that are absent from Kubernetes, refuses deletes,
renames, role changes, unhealthy existing nodes, pending cordon/taint
finalization, K3s version drift, and unsafe control-plane counts. It joins
workers sequentially, may join at most one control-plane node, delegates to the
same `node-join` lifecycle path, and leaves all joined nodes cordoned until
you explicitly run the printed `node-uncordon` commands.

Control-plane delete is gated by read-only preflight, quorum checks, Longhorn
eviction when installed, fresh K3s etcd snapshot creation, and explicit
embedded-etcd member removal from a remaining control-plane.

Join starts K3s with `node.home-ops.sh/joining=true:NoSchedule`, then cordons
the node. Uncordon removes the temporary taint, waits for Cilium, checks
Longhorn scheduling readiness, and restores scheduling.

Control-plane joins also install and verify the K3s kube-proxy disable drop-in
when the derived Cilium config has `kube_proxy_replacement: true`.

### Network Reimage

Network reimage is a post-delete flow for Raspberry Pi nodes. The normal path
is build, serve, drain, Longhorn eviction when needed, `node-delete`,
`node-reimage-apply`, `node-join`, `node-uncordon`, and
`node-reimage-cleanup`.

`node-reimage-build` renders the per-node `rpi-image-gen` source tree, builds
the image, copies the artifact to `.out/reimage/live/<node>/`, computes its
SHA256, and records state. On macOS it uses the persistent
`home-ops-rpi-image-builder` Lima VM because `rpi-image-gen` is supported on
Debian/Linux build hosts. On Linux it can run the local `rpi-image-gen`
checkout directly. The default checkout is `../rpi-image-gen`; override with
`RPI_IMAGE_GEN_DIR` or `--rpi-image-gen-dir`.

`node-reimage-serve <node> <host>` copies the recorded image and metadata to a
node-specific directory under `/tmp/home-ops-reimage/<node>/` on a healthy
inventory host, starts a `python3 -m http.server`, and records the URL/SHA in
serve state. The host is explicit so the operator chooses a node that is
reachable from the initramfs network path.

`node-reimage-apply` reads the recorded serve state, calls the existing stage
and tryboot reboot primitives, waits for SSH to go down and return, and
refreshes `known_hosts`. It also waits for the generated image firstboot
marker so SSH returning on the old OS or before firstboot completion is not
treated as success. It does not join or uncordon the node.

`node-reimage-stage` requires image metadata with schema
`home-ops.node-image/v1`, matching `node`, `hostname`, `ansibleHost`,
`imageUrl`, `sha256`, and `arch`. It also requires
`home_ops_reimage_pi_serial` and `home_ops_reimage_disk_serial` in inventory;
use `node-reimage-plan` to discover those values. Render the sidecar metadata
with `just node-reimage-metadata <node> <image-url> <sha256> >
<image-name>.metadata.json`. By default staging fails if the Kubernetes Node
still exists. `--force` skips only that deleted-node check for disaster
recovery when the API is unavailable.

`node-reimage-image-source` renders a per-node `rpi-image-gen` source tree
under `hack/bootstrap/.out/reimage/` from inventory. The rendered config uses
the inventory hostname, Ansible user, `ansible_host` static IP, public SSH key
derived from the inventory SSH key, passwordless sudo for the Ansible user, and
a small first-boot systemd-networkd/systemd layer. The layer also seeds the
same Raspberry Pi cmdline and firmware config defaults that Ansible later
enforces. It defaults to the `trixie-minbase` base layer; pass `--base-layer`,
`--interface`, `--prefix`, `--gateway`, `--dns`, or `--ssh-public-key` when the
defaults do not match the target node.

By default staging builds the payload on the target from the current Raspberry
Pi initramfs, injects the reimage hook, manifest, network env, VLAN module when
needed, and CA certificates when present. `--payload-dir` can still supply a
local `initramfs.img` and `cmdline.txt` pair. Staging writes the payload,
manifest, and `/boot/firmware/tryboot.txt`; the separate reboot command uses
the Raspberry Pi one-shot `0 tryboot` flag.

Network reimage destroys any `local-path` data on that node. Replicated
controllers should recover from healthy peers, but a stale local-path PVC may
need a narrow operator cleanup after the node rejoins. For CNPG, verify the
failed instance is not primary and the cluster has healthy peers before
deleting only the failed pod/PVC so the operator can rebuild a fresh replica.

## Live Validation

Live bootstrap recipes use the active kube context. Switch to the intended
context before running them, and inspect it first when in doubt.

Check the live target explicitly when needed:

```sh
just context default
```

Run read-only bootstrap inventory against the active context:

```sh
just bootstrap-audit
```

Run server-side dry-run against the active context:

```sh
just bootstrap-dry-run
```

This starts at `bootstrap-crds`, skips rollout waits, and validates rendered
resources against the real API server, installed CRDs, admission webhooks, and
RBAC. It does not prove first-boot timing because the live cluster already has
CRDs, controllers, namespaces, and secrets.

If the all-in-one dry-run stops on one object, continue coverage phase by
phase:

```sh
just bootstrap-phase dragonfly-operator
just bootstrap-phase argocd-dependencies
just bootstrap-phase argocd
just bootstrap-phase wait-argocd
just bootstrap-phase takeover-cleanup
```

Managed-field conflicts in live dry-run are drift to investigate. They are not
automatically bootstrap ordering failures.

## 1Password Seed Secret

The seed phase creates `Secret/external-secrets/op-credentials`.

The manifest is read from 1Password, validated, normalized to Secret `data`,
and streamed to Kubernetes with server-side apply. It is not written to disk,
logs, reports, or client-side last-applied annotations.

The seed apply uses narrow server-side `--force-conflicts` because the
1Password item is authoritative and older clusters may have created the Secret
with client-side apply.

The seed phase tries `op read`. If that fails in an interactive run, it runs
`op signin`, evaluates the returned session export inside the bootstrap
process without logging it, and retries.

That interactive fallback is scoped to the bootstrap process. If you want
later bootstrap runs to avoid another password prompt, run the signin in your
shell.

If automatic `op` auth is not appropriate, authenticate first:

```sh
eval "$(op signin)"
```

For Lima, you can also pipe the seed manifest to a stdin recipe:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | just lima-bootstrap-stdin
```

For Lima app-profile runs:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | just lima-apps-bootstrap-stdin
```

Use `--op-account` only when multiple accounts require disambiguation. Prefer
the shorthand from `op account list`.

## Phases

Bootstrap phases run in this order:

1. `preflight`
2. `seed-secret`
3. `bootstrap-crds`
4. `cert-manager`
5. `external-secrets`
6. `gateway-cert-seed`
7. `dragonfly-operator`
8. `argocd-dependencies`
9. `argocd`
10. `wait-argocd`
11. `takeover-cleanup`
12. `audit`

For live phase debugging, use:

```sh
just bootstrap-phase argocd
```

For current-context operation, the generic recipes are:

```sh
just bootstrap-dry-run
just bootstrap
just bootstrap-yes
```

## Reports

Each run writes non-secret output under `hack/bootstrap/.out/`. The directory
is gitignored.

Use reports to compare kind, Lima, and live dry-run behavior. Secret manifests
must never be written there.

## After Bootstrap

On the real cluster, ArgoCD should own steady-state sync after bootstrap.

Start with:

```sh
just bootstrap-audit
```

For direct ArgoCD status inspection:

```sh
just argocd-apps
```
