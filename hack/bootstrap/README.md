# Home Ops Bootstrap

This directory contains the guarded tooling used before ArgoCD can fully take
over a fresh or disposable cluster.

Use the root `justfile` for operator workflows. Direct scripts in this
directory are implementation details behind those recipes.

```sh
just --list
```

Install the pinned local tools with `mise install --locked --yes` before
running validation or bootstrap recipes on a fresh workstation. Use
`mise exec -- just <recipe>` until your shell has mise activated. After `just`
is available, `just tools` is the repo shortcut. The tool list lives in the
repository root `mise.toml`.

For the longer operator runbook, see
[`docs/cluster-operations.md`](../../docs/cluster-operations.md).

## What Lives Here

| Path | Purpose |
| --- | --- |
| `bootstrap.sh` | Phase runner for Kubernetes takeover dependencies. |
| `phases/` | Idempotent bootstrap phases sourced by `bootstrap.sh`. |
| `lib/` | Shared bootstrap logging, rendering, apply, and report helpers. |
| `ansible/` | Live and Lima K3s node convergence wrapper. |
| `lima/` | Disposable VM harness for foundation and app-profile testing. |
| `nodes/` | Existing-cluster node lifecycle helpers. |
| `tests/bats/` | Offline regression tests for parsing, rendering, and helpers. |
| `.out/` | Disposable local reports, inventories, kubeconfigs, and renders. |

Do not commit `.out/`.

## Fast Path

| Goal | Recipe |
| --- | --- |
| List available commands | `just --list` |
| Install pinned local tools | `just tools` |
| Show active cluster status | `just context` |
| Run full local checks | `just check` |
| Test bootstrap Bash and offline behavior | `just bootstrap-test` |
| Recreate kind and bootstrap from scratch | `just kind-fresh` |
| Show kind status | `just kind-status` |
| Dry-run an already bootstrapped kind cluster | `just kind-bootstrap-dry-run` |
| Run Lima foundation bootstrap | `just lima-fresh` |
| Show Lima status | `just lima-status` |
| Run Longhorn-focused Lima bootstrap | `just lima-longhorn-fresh` |
| Run full Lima app-profile bootstrap | `just lima-apps-fresh` |
| Render live Ansible inventory and vars | `just ansible-plan` |
| Plan additive-only live node joins | `just node-converge-plan` |
| Audit active bootstrap/takeover state | `just bootstrap-audit` |
| Dry-run Kubernetes bootstrap on the active context | `just bootstrap-dry-run` |
| Run live Ansible plus Kubernetes bootstrap | `just ansible-bootstrap` |

Use the smallest validation that proves the change. Most script edits only
need `just bootstrap-test`; Cilium, Longhorn, VolSync, CNPG, and ArgoCD
behavior need Lima or live dry-run/audit validation.

## Bootstrap Scope

Bootstrap installs only what ArgoCD needs before it can reconcile the rest of
the repository:

1. 1Password seed Secret for External Secrets.
2. Required CRDs.
3. cert-manager.
4. External Secrets and 1Password Connect.
5. Gateway wildcard TLS Secrets when normal apps are in scope.
6. Dragonfly Operator.
7. Narrow ArgoCD dependencies.
8. Canonical `apps/argocd` render.
9. ArgoCD readiness gates.
10. Helm takeover cleanup and audit.

Normal workloads should stay out of `hack/bootstrap/` unless they are required
before ArgoCD can take over.

## Profiles

| Profile | Use |
| --- | --- |
| `full` | Real-cluster takeover profile. Applies dependencies, ArgoCD, readiness waits, and audit. |
| `foundation` | Lima foundation profile. Validates K3s, Cilium takeover, core operators, and ArgoCD without normal apps. |
| `lima-longhorn` | Disposable Longhorn lifecycle validation with Longhorn, external snapshotter, storage classes, and a checksum PVC workload. |
| `lima-apps` | Disposable app-profile validation with a sanitized app allowlist and external-writer guardrails. |

## Kind

Kind is the fastest disposable Kubernetes check.

| Goal | Recipe |
| --- | --- |
| Create the three-node kind cluster | `just kind-create` |
| Show kind status | `just kind-status` |
| Bootstrap the configured kind cluster | `just kind-bootstrap` |
| Resume from a phase | `just kind-bootstrap-resume bootstrap-crds` |
| Seed only the 1Password credential | `just kind-bootstrap-seed` |
| Delete the kind cluster | `just kind-delete` |

When Cilium CRDs are absent, bootstrap omits real-cluster-only resources such
as the full `ApplicationSet/k3s-apps`, Cilium, Longhorn, and
`crd-schema-publisher`.

Server-side dry-run does not persist CRDs on a clean cluster. Use
`just kind-fresh` for first-boot behavior, then
`just kind-bootstrap-dry-run` after CRDs exist.

## Lima

Lima is the Apple Silicon VM harness for end-to-end behavior.

| Goal | Foundation Recipe | Longhorn Recipe | App-Profile Recipe |
| --- | --- | --- | --- |
| Create VMs | `just lima-create` | `just lima-longhorn-create` | `just lima-apps-create` |
| Run Ansible | `just lima-ansible` | `just lima-longhorn-ansible` | `just lima-apps-ansible` |
| Run Kubernetes bootstrap | `just lima-bootstrap` | `just lima-longhorn-bootstrap` | `just lima-apps-bootstrap` |
| Validate | `just lima-validate` | `just lima-longhorn-validate` | `just lima-apps-validate` |
| Full fresh run | `just lima-fresh` | `just lima-longhorn-fresh` | `just lima-apps-fresh` |

Useful maintenance recipes:

```sh
just lima-status
just lima-context
just lima-delete
```

Foundation defaults to one server VM with `4` CPU and `6GiB` memory plus two
agent VMs with `2` CPU and `3GiB` memory.

The Longhorn-focused recipes default to three untainted server VMs and one
agent VM with `3` CPU, `4GiB` memory, and `80GiB` disks. Use this profile for
node lifecycle and Longhorn replica-eviction testing; it avoids the full app
restore workload while still validating a real `longhorn-retain` PVC with a
checksum loop.

The app-profile recipes default to three untainted server VMs and one agent VM
with `3` CPU, `5GiB` memory, and `120GiB` disks for topology spread, Longhorn,
VolSync restores, database operators, and node replacement testing without
overloading the local host.

Override the shape with `LIMA_SERVER_COUNT`, `LIMA_SERVER_CPUS`,
`LIMA_SERVER_MEMORY_GIB`, `LIMA_AGENT_COUNT`, `LIMA_AGENT_CPUS`,
`LIMA_AGENT_MEMORY_GIB`, `LIMA_K3S_MASTER_TAINT`, or `LIMA_DISK_GIB`.

Lima VM creation installs `open-iscsi` and `nfs-common` before Ansible runs so
Longhorn block and RWX volumes can mount.

## App-Profile Safety

The `lima-apps` profile transforms the existing `ApplicationSet/k3s-apps`
before ArgoCD sees it. Render-time patches and fail-closed admission policies
prevent external writes while still testing restores.

The profile must not create:

- `PushSecret`
- ACME `Order` or `Challenge`
- VolSync `ReplicationSource`
- active CNPG `Cluster.spec.plugins`
- CNPG backup resources
- Velero backup resources
- Longhorn backup jobs

If a Lima app-profile run needs app manifests from an unmerged branch, push
the branch and set `LIMA_APPSET_TARGET_REVISION` for the run.

## Cilium Ordering

Bootstrap withholds `ApplicationSet/k3s-apps` until Cilium takeover is ready.

When Cilium CRDs are present, bootstrap applies the Hubble issuer chain,
reconciles `Application/cilium`, waits for Hubble server and relay certs,
restarts Cilium/Hubble if stale takeover certs were replaced, and then releases
apps.

Before normal apps are released, bootstrap applies
`apps/kube-system/external-snapshotter` so VolSync restore workloads have the
snapshot CRDs and controller.

Lima keeps Cilium masquerading enabled because Lima user-mode networking cannot
route pod CIDRs back to pods. The live cluster does not need that Lima-only
setting.

## Live Bootstrap

The live wrapper renders this repo's inventory and GitOps-derived values before
calling Ansible.

| Goal | Recipe |
| --- | --- |
| Render a non-mutating plan | `just ansible-plan` |
| Import an existing K3s token into 1Password | `just ansible-import-token` |
| Run live Ansible only | `just ansible-run` |
| Run Kubernetes bootstrap only on the active context | `just bootstrap` |
| Run Ansible and Kubernetes bootstrap | `just ansible-bootstrap` |

The default Ansible backend is the in-repo `home-ops` backend for
Debian-family, systemd nodes. The external `../k3s-ansible` backend remains
available for comparison with `BOOTSTRAP_ANSIBLE_BACKEND=k3s-ansible`.

Generated live inventory, group vars, kubeconfigs, and run output are written
under `hack/bootstrap/.out/ansible-live/`. The checked-in live inventory under
`hack/bootstrap/ansible/inventory/live/` is intentionally non-secret.

The live K3s token lives at `op://Kubernetes/k3s-bootstrap/k3s_token`. Normal
runs load it from 1Password. If an existing cluster already has a token, import
it before the next run.

Initial K3s server args leave kube-proxy enabled so Ansible can complete before
Cilium owns Service routing. After Cilium is ready, the wrapper runs the
post-Cilium playbook that disables kube-proxy when the derived Cilium config
has `kube_proxy_replacement: true`.

The in-repo backend enables the K3s embedded registry mirror by default and
writes `registries.yaml` mirrors for the registries used by this cluster. Nodes
must be able to reach peer nodes on TCP `5001` for Spegel image sharing and
the API endpoint on TCP `6443`. A `registries.yaml` change restarts the
affected K3s server or agent so the mirror config is actually loaded.

The in-repo backend owns node-prep prerequisites before K3s install or join:
Raspberry Pi boot/config flags, swap disablement, CPU governor, fsnotify
sysctls, K3s kernel modules, and Longhorn host prerequisites such as
`open-iscsi`, `nfs-common`, `cryptsetup`, `dmsetup`, and `dm_crypt`. Fresh
nodes may reboot automatically before joining K3s. Existing K3s nodes stop with
a reboot-required message instead of rebooting themselves; use the node
lifecycle drain/reboot/uncordon flow.

Full Ansible runs also converge host services: RPi MQTT reporter on all nodes,
NUT client on control-plane nodes, and a GitHub Actions runner on workers for
ARM64 image verification. Host-service secrets are loaded from
`op://Kubernetes/host-services`; new worker runner registration mints a
short-lived GitHub App installation token from the
`HOME_OPS_GITHUB_APP_ID`, `HOME_OPS_GITHUB_APP_INSTALLATION_ID`, and
`HOME_OPS_GITHUB_APP_PRIVATE_KEY` fields. Store
`HOME_OPS_GITHUB_APP_PRIVATE_KEY` as base64-encoded full PEM key data so it fits
cleanly in a 1Password field. The app installation needs repository
Administration permission set to read/write for `sholdee/home-ops`. After
changing the app permission, update or reinstall the app installation so the
installation grants the new permission. The runner uses a dedicated
`github-runner` user and a narrow `home-ops-crictl` sudo wrapper for image
pull/inspect checks.

Single-node join/finalize recipes keep Kubernetes convergence separate from
optional host services. After a replacement node is joined and uncordoned, run
`just ansible-host-services <node>` when you want to converge the reporter,
NUT client, or Actions runner explicitly.

## Node Lifecycle

Node lifecycle commands operate on an existing cluster and are intentionally
explicit.

| Goal | Live Recipe | Lima Recipe |
| --- | --- | --- |
| List nodes | `just node-list` | `just node-lima-list` |
| Node status | `just node-status <node>` | `just node-lima-status <node>` |
| Pods bound to node | `just node-pods <node>` | `just node-lima-pods <node>` |
| Control-plane status | `just node-control-plane-status <node>` | `just node-lima-control-plane-status <node>` |
| Control-plane delete preflight | `just node-control-plane-delete-preflight <node>` | `just node-lima-control-plane-delete-preflight <node>` |
| Discover network reimage identity | `just node-reimage-plan <node>` | n/a |
| Render network reimage metadata | `just node-reimage-metadata <node> <image-url> <sha256>` | n/a |
| Render network reimage OS source | `just node-reimage-image-source <node>` | n/a |
| Build network reimage OS artifact | `just node-reimage-build <node>` | n/a |
| Plan additive-only joins | `just node-converge-plan` | `just node-lima-converge-plan` |
| Join missing inventory nodes | `just node-converge` | `just node-lima-converge` |
| Drain | `just node-drain <node>` | `just node-lima-drain <node>` |
| Reboot a drained node | `just node-reboot <node>` | `just node-lima-reboot <node>` |
| Evict Longhorn replicas | `just node-longhorn-evict <node>` | `just node-lima-longhorn-evict <node>` |
| Delete | `just node-delete <node>` | `just node-lima-delete <node>` |
| Refresh SSH host key | `just node-refresh-ssh-host-key <node>` | `just node-lima-refresh-ssh-host-key <node>` |
| Join from inventory | `just node-join <node>` | `just node-lima-join <node>` |
| Remove joining taint and uncordon | `just node-uncordon <node>` | `just node-lima-uncordon <node>` |
| Serve recorded reimage artifact | `just node-reimage-serve <node> <host>` | n/a |
| Apply recorded reimage | `just node-reimage-apply <node>` | n/a |
| Clean up image server | `just node-reimage-cleanup <node>` | n/a |
| Stage network reimage | `just node-reimage-stage <node> <image-url> <sha256>` | n/a |
| Reboot into one-shot reimage | `just node-reimage-reboot <node>` | n/a |

For maintenance work, use `drain`, `reboot` when needed, and `uncordon`.
`longhorn-evict` is for node replacement and fails before mutating Longhorn if
remaining storage nodes cannot hold the maximum configured replica count.

Node replacement also waits for global Longhorn quiescence. The lifecycle gates
block while Longhorn has unhealthy volumes, active rebuilds, non-RW replicas,
clone/restore/purge/backup activity, unschedulable storage nodes, or an
eviction still in progress. Treat `node-uncordon` completion as the point where
it is safe to begin the next replacement.

Control-plane delete is gated by read-only preflight, quorum checks, Longhorn
eviction when Longhorn is installed, fresh K3s etcd snapshot creation, and
explicit embedded-etcd member removal from a remaining control-plane.

Join starts K3s with `node.home-ops.sh/joining=true:NoSchedule`, then cordons
the node. Uncordon removes the temporary taint, waits for Cilium, checks
Longhorn scheduling readiness, restores scheduling, and waits for Longhorn to
be healthy and idle.

Converge is additive-only. It joins fresh inventory nodes that are absent from
Kubernetes, refuses ambiguous drift or pending finalization, delegates mutation
to `node-join`, and never uncordons automatically.

Control-plane joins also install and verify the K3s kube-proxy disable drop-in
when `kube_proxy_replacement: true`.

Network reimage is for Raspberry Pi nodes that have already passed the normal
delete lifecycle. `node-reimage-stage` refuses to run while the Kubernetes Node
still exists, unless `--force` is passed for disaster recovery. It verifies the
inventory node, Raspberry Pi serial, target disk serial, image metadata, and
payload files before writing `tryboot.txt` plus staged files under
`/boot/firmware/home-ops-reimage`. Use `node-reimage-plan` first to discover
the serial values that must be stored in inventory, and
`node-reimage-build` to render and build the replacement Raspberry Pi OS image.
On macOS the build runs in the persistent `home-ops-rpi-image-builder` Lima VM;
on Linux it can run directly. `node-reimage-serve` hosts the recorded artifact
from an explicit healthy inventory node, `node-reimage-apply` stages and
tryboot-reboots the deleted node from recorded serve state, and
waits for SSH plus the generated-image firstboot marker before reporting
success. The full reimage flow labels the rejoined node with the current
system-upgrade Plan hash so it is adopted by future OS updates without
rerunning the already-applied revision. `node-reimage-cleanup` removes the
node-specific remote hosting directory. By default the payload is built on the
target from its current
Raspberry Pi initramfs, so it keeps the matching kernel modules and
boot-network tooling.

## Secrets

Secret manifests read from 1Password are streamed directly to Kubernetes. They
must not be written to disk, logs, reports, or client-side last-applied
annotations.

Keep 1Password CLI desktop app integration enabled and the app unlocked for
interactive runs, or authenticate `op` before invoking a recipe. Leave
`--op-account` unset unless you need to disambiguate accounts.

Interactive `op signin` fallback is scoped to the recipe process. Run
`eval "$(op signin)"` in your shell first if repeated prompts are annoying.

If script-managed `op` auth is not appropriate, pipe the seed manifest to a
stdin recipe:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | just lima-bootstrap-stdin
```

For Longhorn-focused Lima runs:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | just lima-longhorn-bootstrap-stdin
```

For app-profile Lima runs:

```sh
op read op://Kubernetes/op-credentials/op-credentials.yaml \
  | just lima-apps-bootstrap-stdin
```
