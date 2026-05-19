# PVC Restore Runbook

Use this when a PVC-backed workload shows filesystem, checksum, or mount
corruption. The default recovery path is restore from a known-good backup or
controller-managed replica, not filesystem repair.

This runbook assumes Git is the desired state. Prefer changing the app
manifests, merging the change, and letting ArgoCD reconcile instead of applying
long-lived live patches.

Common symptoms:

- `fsck ... UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY` during mount
- `Structure needs cleaning`, `remote I/O`, or `input/output error`
- `applyFSGroup ... bad message` on a VolSync mover or application pod
- PostgreSQL `checksum verification failed` during CNPG replica join or backup
- A workload starts but serves broken data from a mounted PVC

## Safety Rules

- Confirm the PVC owner before deleting anything. Application PVCs,
  StatefulSet PVCs, VolSync cache PVCs, and CNPG instance PVCs have different
  replacement paths.
- For VolSync-backed app PVCs, prefer deleting the bad PVC and recreating it
  from Git with the correct `dataSourceRef` and `storageClassName`.
- For CNPG-managed PostgreSQL PVCs, use `kubectl cnpg` commands. Do not
  manually delete CNPG pods or PVCs.
- Do not run filesystem repair on a mounted live workload PVC. Use repair only
  as last-resort forensic work on an isolated copy.
- If several PVCs fail at once, suspect the storage datapath first. Restore
  onto a trusted StorageClass before spending time on per-volume repairs.
- After recovery, ArgoCD should be `Synced` and `Healthy`; any emergency live
  patch should be removed or represented in Git.

## Initial Triage

Find unhealthy pods and storage-related events:

```sh
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide
kubectl get events -A --sort-by=.lastTimestamp | \
  rg -i 'fsck|bad message|remote I/O|EREMOTEIO|UNEXPECTED INCONSISTENCY|applyFSGroup|FailedMount|MountVolume|checksum verification failed|Structure needs cleaning'
```

Map the failing pod to its PVC and controller:

```sh
kubectl -n <namespace> describe pod <pod>
kubectl -n <namespace> describe pvc <pvc>
kubectl -n <namespace> get deploy,sts,pod,pvc,replicationsource,replicationdestination -o wide
```

Check backup freshness before changing the live PVC:

```sh
kubectl -n <namespace> get replicationsource <name> -o wide
kubectl -n <namespace> get replicationdestination <name> -o yaml
```

## VolSync App PVC Restore

Use this path for normal application PVCs where a known-good VolSync restic
backup exists and the workload can be restored to that backup time.

### 1. Put The Desired Restore In Git

The PVC should be the final shape you want after recovery. Set the
StorageClass deliberately, such as `local-path` for node-local recovery or a
known-good Longhorn class when Longhorn is trusted.

The PVC should include a `dataSourceRef` to the matching
`ReplicationDestination` so a deleted PVC can be recreated by ArgoCD and
populated automatically:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <app>-pvc
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  dataSourceRef:
    apiGroup: volsync.backube
    kind: ReplicationDestination
    name: <app>-bootstrap
  resources:
    requests:
      storage: <size>
  storageClassName: <trusted-storage-class>
```

The `ReplicationDestination` should point at the desired restic repository and
restore time. Omit `restoreAsOf` to use the latest backup.

If the app must stay down during restore, commit the workload at `replicas: 0`
in the same PR or in an earlier PR.

### 2. Recreate The PVC

After the Git change is merged and ArgoCD sees the desired shape, stop the
workload if it is not already scaled down:

```sh
kubectl -n <namespace> scale deploy/<consumer> --replicas=0
kubectl -n <namespace> wait --for=delete pod -l app=<consumer> --timeout=5m
```

Delete the corrupt PVC and let ArgoCD recreate it from Git:

```sh
kubectl -n <namespace> delete pvc <app>-pvc --wait=true --timeout=5m
kubectl -n argocd annotate application <argocd-app> \
  argocd.argoproj.io/refresh=hard --overwrite
```

Wait for the restore destination and PVC population:

```sh
kubectl -n <namespace> get pvc <app>-pvc -w
kubectl -n <namespace> get replicationdestination <app>-bootstrap -o wide -w
```

### 3. Start And Validate

Return the workload to its Git-managed replica count, either by merging the
replica change or by syncing the already-merged app manifest:

```sh
kubectl -n argocd annotate application <argocd-app> \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl -n <namespace> rollout status deploy/<consumer> --timeout=10m
```

Verify application-specific files, logs, and health. Then trigger or wait for a
fresh `ReplicationSource` backup from the restored PVC:

```sh
kubectl -n <namespace> get replicationsource <name> -o wide
kubectl -n <namespace> logs job/volsync-src-<name> --all-containers --tail=200
```

If a manual backup trigger is needed, make that trigger in Git when practical
so ArgoCD remains the source of truth.

## CNPG PostgreSQL Restore

Use this path for CNPG-managed PostgreSQL instance PVCs. CNPG instance names
are normally `<cluster>-<ordinal>`.

Inspect the cluster:

```sh
kubectl cnpg status <cluster> -n <namespace>
kubectl -n <namespace> get pods,pvc -l cnpg.io/cluster=<cluster> -o wide
kubectl -n <namespace> logs <instance-pod> -c postgres --since=30m --tail=500
```

If the corrupt instance is a replica, let CNPG remove the pod and PVC:

```sh
kubectl cnpg destroy <cluster> <replica-ordinal> -n <namespace>
kubectl -n <namespace> wait cluster.postgresql.cnpg.io/<cluster> \
  --for=condition=Ready --timeout=30m
kubectl cnpg status <cluster> -n <namespace>
```

If the corrupt instance is primary, first confirm a standby is healthy. Promote
the clean standby, then destroy the old primary through CNPG:

```sh
kubectl cnpg promote <cluster> <clean-standby-ordinal> -n <namespace>
kubectl cnpg status <cluster> -n <namespace>
kubectl cnpg destroy <cluster> <old-primary-ordinal> -n <namespace>
```

After CNPG is healthy, take a fresh backup with the same method used by the
cluster's Git-managed backup configuration:

```sh
kubectl cnpg backup <cluster> -n <namespace> \
  --method plugin \
  --plugin-name barman-cloud.cloudnative-pg.io \
  --backup-target prefer-standby \
  --backup-name <cluster>-post-restore-YYYYMMDDHHMM
```

## Final Validation

Run these checks after recovery:

```sh
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide
kubectl get events -A --sort-by=.lastTimestamp | \
  rg -i 'fsck|bad message|remote I/O|EREMOTEIO|UNEXPECTED INCONSISTENCY|applyFSGroup|FailedMount|MountVolume|checksum verification failed|Structure needs cleaning'
kubectl get replicationsource -A -o wide
kubectl -n argocd get applications.argoproj.io -o wide
```

For PVC-backed pods, scan recent logs for recurring storage symptoms:

```sh
pattern='EREMOTEIO|remote I/O|input/output error|bad message|UNEXPECTED INCONSISTENCY|fsck|database disk image|read-only file system|I/O error|corrupt|checksum verification failed|Structure needs cleaning'
kubectl get pods -A -o json | \
  jq -r '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim != null)) | [.metadata.namespace,.metadata.name] | @tsv' | \
  sort -u | \
  while IFS="$(printf '\t')" read -r namespace pod; do
    matches="$(kubectl -n "${namespace}" logs "${pod}" --all-containers --since=15m --tail=1000 2>/dev/null | rg -i "${pattern}" || true)"
    if [ -n "${matches}" ]; then
      printf '== %s/%s ==\n%s\n' "${namespace}" "${pod}" "${matches}"
    fi
  done
```

The target application should be `Synced` and `Healthy`, the workload should
serve expected data, and a fresh backup should succeed from the restored PVC.
