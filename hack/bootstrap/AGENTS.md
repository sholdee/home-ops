# AGENTS.md - hack/bootstrap

## Scope

This directory owns local bootstrap tooling for disposable or fresh clusters
before ArgoCD can take over. Keep bootstrap narrower than steady-state GitOps:
install only the dependencies needed for takeover, then let ArgoCD reconcile the
normal app graph.

## Start Here

- Read `docs/cluster-operations.md` for operator-facing workflows and command
  examples.
- Use `just --list` or the grouped sections in the root `justfile` for the
  current command surface. The main groups are bootstrap validation, kind,
  Lima, live bootstrap, and node lifecycle.
- Use `rg --files hack/bootstrap` for source inventory. Ignore `.out/` unless
  you are comparing run reports or generated non-secret manifests from a
  specific bootstrap attempt.

## Codemap

- `bootstrap.sh`: generic Kubernetes bootstrap runner and phase dispatcher.
- `lib/`: shared bootstrap runner helpers for logging, Kubernetes commands,
  rendering, and local run reports.
- `phases/`: idempotent bootstrap phases sourced by `bootstrap.sh`.
- `ansible/`: physical-node and Lima K3s convergence wrapper, inventory
  rendering, token/kubeconfig handling, and the in-repo `home-ops` Ansible
  backend. Public scripts source `ansible/lib.sh`; implementation modules live
  under `ansible/lib/`.
- `lima/`: disposable VM harness for foundation and app-profile bootstrap
  validation; `apps.sh` owns Lima app-profile ApplicationSet and safety-policy
  rendering.
- `nodes/`: existing-cluster node lifecycle commands. Command scripts source
  `nodes/lib.sh`; implementation modules live under `nodes/lib/`.
  `nodes/converge.sh` is an additive-only planner/orchestrator and must
  delegate actual joins to `nodes/join.sh`.
- `tests/bats/`: offline BATS tests for parsing, rendering, Ansible command
  construction, node lifecycle helpers, and bootstrap library helpers.
- `tests/helpers/`: BATS fixture and assertion helpers.
- `.out/`: disposable local output, reports, rendered non-secret manifests,
  generated inventories, and Lima runtime state.

## Profiles and Phases

Profiles:

- `full`: real-cluster bootstrap profile. It installs dependencies needed for
  ArgoCD takeover, applies ArgoCD, waits for takeover readiness, then audits.
- `foundation`: Lima foundation profile. It validates K3s, Cilium takeover,
  core operators, and ArgoCD without applying normal app workloads.
- `lima-apps`: disposable app-profile validation. It applies a sanitized
  workload allowlist and fail-closed safety guards so restores can be tested
  without creating external writers.

Phase order:

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

Keep this list in sync with `PHASES` in `bootstrap.sh` and the phase list in
`docs/cluster-operations.md`.

## Safety Rules

- Never write secret manifests from 1Password to disk, reports, logs, or
  client-side last-applied annotations. Stream and validate them, then apply
  server-side.
- Keep `.out/` as disposable local output. Do not commit generated reports,
  kubeconfigs, rendered secret streams, or Lima runtime artifacts.
- Live bootstrap against the homelab context must be dry-run/audit only unless
  explicitly requested after the branch is merged.
- Prefer render-time Kustomize patches for Lima safety. Admission policies are
  fail-closed guardrails, not the primary mutation mechanism.
- Lima app tests must not create external writers: `PushSecret`, ACME
  `Order`/`Challenge`, VolSync `ReplicationSource`, CNPG active
  `Cluster.spec.plugins`, CNPG `Backup` or `ScheduledBackup`, Velero backup
  resources, or Longhorn backup jobs.

## Node Lifecycle Flow

- Worker replacement is explicit: status, drain, delete, join, then uncordon.
- Inventory expansion may use `node-converge`, but it must stay additive-only:
  refuse deletes, renames, role changes, unhealthy existing nodes, pending
  finalization, K3s version drift, unsafe control-plane counts, and any state
  it cannot prove safe.
- Control-plane replacement adds stricter gates: preflight, Longhorn eviction
  if installed, fresh K3s etcd snapshot, Kubernetes Node deletion, explicit
  embedded-etcd member removal, join with a temporary taint, then finalize and
  uncordon.
- Raspberry Pi network reimage is post-delete only by default. Keep the
  deleted-node check, Pi serial check, disk serial check, image metadata check,
  and staged-payload check fail-closed; `--force` may skip only the Kubernetes
  node-existence check for disaster recovery.
- Mutating node lifecycle commands must remain fail-closed. If a helper cannot
  prove safety, stop and leave the node cordoned rather than guessing.

## Ordering Invariants

- Cilium takeover must complete before applying normal `k3s-apps` workloads.
  Apply the Hubble issuer chain, wait for Cilium and Hubble certs, restart
  Cilium/Hubble when stale takeover certs were replaced, then release apps.
- Gateway wildcard TLS restore must happen before applying normal Gateway
  resources in profiles that include app workloads.
- External snapshotter must be applied before VolSync restore destinations and
  PVCs that use snapshot-based restores.
- For CNPG clusters that reference the Barman Cloud plugin, apply required
  ExternalSecrets and `barmancloud.cnpg.io/ObjectStore` resources before the
  `postgresql.cnpg.io/Cluster`. The Cluster pre-reconcile hook blocks instance
  pod creation until the ObjectStore exists.
- When adding sync waves for app dependencies, avoid same-wave ambiguity for
  resources a controller requires during reconcile. Put provider/config
  resources in an earlier wave than the consumer CR.

## Implementation Notes

- Scripts are Bash. Keep phases idempotent and fail hard on real errors.
- Preserve explicit phase names and logs; they are the debugging interface for
  long bootstrap runs.
- Keep `bootstrap.sh` generic and put profile-specific behavior in narrow phase
  helpers or Lima wrapper scripts.
- Keep physical-node Ansible orchestration in `hack/bootstrap/ansible/`.
  Generated inventories, kubeconfigs, and run output belong under `.out/`.
  1Password may hold durable bootstrap secrets such as the K3s token; scripts
  must pass secret values through stdin, environment, or memory and never log
  them.
- Validate script changes with `just bootstrap-test`; it runs ShellCheck and
  the offline BATS suite. For app-profile changes, also use the relevant Lima
  validation recipe.
- Validation ladder:
  `just bootstrap-test` for Bash and offline behavior,
  `just kind-fresh` for disposable Kubernetes bootstrap behavior,
  Lima foundation recipes for Cilium and ArgoCD takeover behavior,
  Lima app recipes for Longhorn, VolSync, CNPG restore, and workload safety,
  live audit/dry-run recipes for real-cluster field ownership and drift.
- Add offline regression coverage in `tests/bats/` for Bash helper behavior
  that can be exercised without a real cluster. Keep Lima and live recipes for
  behavior that needs VM, Kubernetes, Longhorn, or ArgoCD state.
- If a long Lima run fails, identify whether it is an ordering problem,
  controller health problem, or workload/runtime problem before widening the
  bootstrap allowlist.
