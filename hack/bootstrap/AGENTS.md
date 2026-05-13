# AGENTS.md - hack/bootstrap

## Scope

This directory owns local bootstrap tooling for disposable or fresh clusters
before ArgoCD can take over. Keep bootstrap narrower than steady-state GitOps:
install only the dependencies needed for takeover, then let ArgoCD reconcile the
normal app graph.

## Codemap

- `bootstrap.sh`: generic Kubernetes bootstrap runner and phase dispatcher.
- `lib/`: shared bootstrap runner helpers for logging, Kubernetes commands,
  rendering, and local run reports.
- `phases/`: idempotent bootstrap phases sourced by `bootstrap.sh`.
- `ansible/`: physical-node and Lima K3s convergence wrapper, inventory
  rendering, and the in-repo `home-ops` Ansible backend.
- `lima/`: disposable VM harness for foundation and app-profile bootstrap
  validation.
- `nodes/`: existing-cluster node lifecycle commands. Command scripts source
  `nodes/lib.sh`; implementation modules live under `nodes/lib/`.
- `tests/bats/`: offline BATS tests for parsing, rendering, Ansible command
  construction, node lifecycle helpers, and bootstrap library helpers.
- `tests/helpers/`: BATS fixture and assertion helpers.
- `.out/`: disposable local output, reports, rendered non-secret manifests,
  generated inventories, and Lima runtime state.

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
- Add offline regression coverage in `tests/bats/` for Bash helper behavior
  that can be exercised without a real cluster. Keep Lima and live recipes for
  behavior that needs VM, Kubernetes, Longhorn, or ArgoCD state.
- If a long Lima run fails, identify whether it is an ordering problem,
  controller health problem, or workload/runtime problem before widening the
  bootstrap allowlist.
