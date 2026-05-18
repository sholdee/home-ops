# PVC Recovery Runbook

Use this when a PVC-backed workload shows filesystem, clone, checksum, or mount
corruption. Keep the repair narrow: identify the owning controller, repair one
PVC or database instance at a time, and prove the backup path works again before
cleaning up.

Common symptoms:

- `applyFSGroup ... bad message` on a VolSync source clone pod
- `fsck ... UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY` during mount
- `Structure needs cleaning`, `remote I/O`, or `input/output error`
- VolSync `ReplicationSource` stuck with no `LAST SYNC`
- PostgreSQL `checksum verification failed` during CNPG replica join or backup

## Safety Rules

- Confirm the workload owner before deleting anything. Application PVCs,
  StatefulSet PVCs, VolSync cache PVCs, and CNPG instance PVCs have different
  replacement paths.
- For application PVCs backed by VolSync/restic, prefer a clean restore and
  replacement over filesystem repair.
- For CNPG-managed PostgreSQL PVCs, use `kubectl cnpg` commands. Do not
  manually delete CNPG pods or PVCs.
- Keep temporary manifests under `hack/bootstrap/.out/` or another ignored
  path.
- After any recovery, remove live-only patches so ArgoCD returns to Git state.
- Longhorn PVCs on Raspberry Pi 5 Trixie nodes should be created with a 16 KiB
  filesystem block size; this was live-tested after replica rebuild and
  reattach. Use `mkfsParams: "-b 16384"` for ext4 and
  `mkfsParams: "-b size=16384"` for XFS. Existing Longhorn PVCs created with
  4 KiB filesystem blocks should be restored or recreated, not trusted in
  place.

## Initial Audit

Check for non-running pods and recent storage errors:

```sh
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide
kubectl get events -A --sort-by=.lastTimestamp | \
  rg -i 'fsck|bad message|remote I/O|EREMOTEIO|UNEXPECTED INCONSISTENCY|applyFSGroup|FailedMount|MountVolume|checksum verification failed|Structure needs cleaning'
```

List bound PVCs and Longhorn volume health:

```sh
kubectl get pvc -A -o wide
kubectl -n longhorn-system get volumes.longhorn.io -o wide
```

For a suspicious pod, map each mounted volume back to its PVC and owner:

```sh
kubectl -n <namespace> describe pod <pod>
kubectl -n <namespace> describe pvc <pvc>
kubectl -n <namespace> get pods -o wide
```

## Application PVC Path

Use this path for normal application PVCs where a known-good VolSync restic
backup exists and the app can tolerate restoring to that point in time.

### 1. Inspect VolSync

```sh
kubectl -n <namespace> get replicationsource <name> -o wide
kubectl -n <namespace> describe pod -l job-name=volsync-src-<name>
```

If VolSync is stuck on an old clone PVC, expect to remove
`volsync-<name>-src` and `volsync-src-<name>-cache` during the cutover.

### 2. Restore Into A Temporary PVC

Restore to a temporary PVC first. Do not replace the live PVC until the restore
finishes and expected files are present.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <name>-restore-check
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <size>
  storageClassName: longhorn
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <name>-restore-check
  namespace: <namespace>
spec:
  trigger:
    manual: restore-YYYY-MM-DDTHH-MM-SSZ
  restic:
    repository: <name>-volsync-b2
    destinationPVC: <name>-restore-check
    copyMethod: Direct
    storageClassName: longhorn
    accessModes:
      - ReadWriteOnce
    capacity: <size>
    enableFileDeletion: true
    restoreAsOf: "YYYY-MM-DDTHH:MM:SSZ"
    moverSecurityContext:
      runAsUser: 65534
      runAsGroup: 65534
      fsGroup: 65534
```

```sh
kubectl apply --server-side --field-manager=home-ops-restore -f <restore-check>.yaml
kubectl -n <namespace> wait --for=jsonpath='{.status.lastSyncTime}' \
  replicationdestination/<name>-restore-check --timeout=10m
```

Verify app-specific files with a one-shot job:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: <name>-restore-verify
  namespace: <namespace>
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        fsGroupChangePolicy: OnRootMismatch
      containers:
        - name: verify
          image: quay.io/backube/volsync:0.15.0
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              test -f /data/<expected-file>
              find /data -maxdepth 2 -mindepth 1 | sort | head -50
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: <name>-restore-check
```

```sh
kubectl apply --server-side --field-manager=home-ops-restore -f <verify>.yaml
kubectl -n <namespace> wait --for=condition=complete job/<name>-restore-verify --timeout=3m
kubectl -n <namespace> logs job/<name>-restore-verify
```

### 3. Replace The Source PVC

Pause VolSync and stop every workload that mounts the PVC:

```sh
kubectl -n <namespace> patch replicationsource <name> \
  --type=merge -p '{"spec":{"paused":true}}'

kubectl -n <namespace> scale deploy/<consumer> --replicas=0
kubectl -n <namespace> wait --for=delete pod -l app=<consumer> --timeout=3m
```

Delete stale VolSync source state before deleting the app PVC:

```sh
kubectl -n <namespace> delete job volsync-src-<name> --ignore-not-found --wait=false
kubectl -n <namespace> delete pvc volsync-<name>-src volsync-src-<name>-cache --ignore-not-found
```

Delete and recreate the source PVC. The replacement manifest must match Git
desired state: name, namespace, access modes, storage class, size, labels, and
ArgoCD tracking annotations when present.

```sh
kubectl -n <namespace> delete pvc <source-pvc> --wait=true --timeout=3m
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <source-pvc>
  namespace: <namespace>
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
    argocd.argoproj.io/tracking-id: <argocd-app>:/PersistentVolumeClaim:<namespace>/<source-pvc>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <size>
  storageClassName: longhorn
---
apiVersion: batch/v1
kind: Job
metadata:
  name: <source-pvc>-cutover-copy
  namespace: <namespace>
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        fsGroupChangePolicy: OnRootMismatch
      containers:
        - name: copy
          image: quay.io/backube/volsync:0.15.0
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              cp -R --no-preserve=mode,ownership,timestamps /source/. /dest/
              test -f /dest/<expected-file>
          volumeMounts:
            - name: source
              mountPath: /source
              readOnly: true
            - name: dest
              mountPath: /dest
      volumes:
        - name: source
          persistentVolumeClaim:
            claimName: <name>-restore-check
        - name: dest
          persistentVolumeClaim:
            claimName: <source-pvc>
```

Use `cp -R --no-preserve=mode,ownership,timestamps`, not tar. Tar may still
attempt to chmod or utime the mounted destination root even with ownership and
permission preservation disabled.

```sh
kubectl apply --server-side --field-manager=home-ops-restore -f <cutover>.yaml
kubectl -n <namespace> wait --for=condition=complete \
  job/<source-pvc>-cutover-copy --timeout=10m
kubectl -n <namespace> logs job/<source-pvc>-cutover-copy
```

Restart consumers and wait for rollout:

```sh
kubectl -n <namespace> scale deploy/<consumer> --replicas=1
kubectl -n <namespace> rollout status deploy/<consumer> --timeout=6m
```

If another consumer now reports fsck errors, map that volume back to its PVC and
repeat the application PVC path for that PVC.

### 4. Prove VolSync Works Again

Delete stale source clones before triggering the regression backup. Otherwise
VolSync can reuse the old damaged clone.

```sh
kubectl -n <namespace> patch replicationsource <name> \
  --type=merge -p '{"spec":{"paused":true}}'
kubectl -n <namespace> delete job volsync-src-<name> --ignore-not-found --wait=false
kubectl -n <namespace> delete pvc volsync-<name>-src volsync-src-<name>-cache --ignore-not-found
```

Trigger one manual source backup:

```sh
kubectl -n <namespace> patch replicationsource <name> \
  --type=merge -p '{"spec":{"paused":false,"trigger":{"schedule":"0 6 * * *","manual":"repair-YYYY-MM-DD"}}}'

kubectl -n <namespace> wait --for=condition=complete \
  job/volsync-src-<name> --timeout=10m
```

After it succeeds, remove live-only fields so ArgoCD returns to Git state:

```sh
kubectl -n <namespace> patch replicationsource <name> --type=json \
  -p '[{"op":"remove","path":"/spec/trigger/manual"},{"op":"remove","path":"/spec/paused"}]'
```

## CNPG PostgreSQL Path

Use this path for CNPG-managed PostgreSQL instance PVCs. CNPG instance names are
normally `<cluster>-<ordinal>`, and the CNPG CLI expects the cluster name plus
the ordinal.

### 1. Inspect The Cluster

```sh
kubectl cnpg status <cluster> -n <namespace>
kubectl -n <namespace> get pods,pvc -l cnpg.io/cluster=<cluster> -o wide
kubectl -n <namespace> logs <instance-pod> -c postgres --since=30m --tail=500
```

Confirm the target instance role before any destructive action:

```sh
kubectl cnpg status <cluster> -n <namespace>
```

Do not destroy a primary until a healthy standby has been promoted and accepted
writes.

### 2. Destroy A Corrupt Replica

If the corrupt instance is a replica, let CNPG remove the pod and PVC:

```sh
kubectl cnpg destroy <cluster> <replica-ordinal> -n <namespace>
kubectl -n <namespace> wait cluster.postgresql.cnpg.io/<cluster> \
  --for=condition=Ready --timeout=30m
kubectl cnpg status <cluster> -n <namespace>
```

CNPG should create a replacement instance automatically when
`spec.instances` still requires it.

### 3. Replace A Corrupt Primary

First identify a standby that can produce a checksum-clean basebackup. For
PostgreSQL versions that support the blackhole backup target, this checks the
standby without writing a local backup:

```sh
kubectl -n <namespace> exec <standby-pod> -c postgres -- \
  pg_basebackup --target=blackhole -X none --checkpoint=fast \
  -d "host=<standby-pod> user=streaming_replica port=5432 \
sslkey=/controller/certificates/streaming_replica.key \
sslcert=/controller/certificates/streaming_replica.crt \
sslrootcert=/controller/certificates/server-ca.crt \
application_name=checksum-check sslmode=verify-ca dbname=postgres connect_timeout=5"
```

Promote the clean standby:

```sh
kubectl cnpg promote <cluster> <clean-standby-ordinal> -n <namespace>
kubectl cnpg status <cluster> -n <namespace>
```

After `kubectl cnpg status` reports the promoted instance as primary, destroy
the old corrupt primary:

```sh
kubectl cnpg destroy <cluster> <old-primary-ordinal> -n <namespace>
```

If a failed join instance was created from the corrupt primary, destroy that
instance through CNPG too:

```sh
kubectl cnpg destroy <cluster> <failed-join-ordinal> -n <namespace>
```

Wait for CNPG to rebuild the requested number of instances:

```sh
kubectl -n <namespace> wait cluster.postgresql.cnpg.io/<cluster> \
  --for=condition=Ready --timeout=30m
kubectl cnpg status <cluster> -n <namespace>
```

### 4. Take A Fresh CNPG Backup

Trigger a fresh backup after the cluster is healthy. Use the same method and
plugin as the cluster's Git-managed backup configuration.

```sh
kubectl cnpg backup <cluster> -n <namespace> \
  --method plugin \
  --plugin-name barman-cloud.cloudnative-pg.io \
  --backup-target prefer-standby \
  --backup-name <cluster>-post-repair-YYYYMMDDHHMM

kubectl -n <namespace> get backup.postgresql.cnpg.io <backup-name> -o wide
kubectl -n <namespace> wait backup.postgresql.cnpg.io/<backup-name> \
  --for=jsonpath='{.status.phase}'=completed --timeout=60m
```

If the normal scheduled backup uses `target: primary`, use `--backup-target
primary` instead so the on-demand backup matches steady-state behavior.

## Final Validation

Run these checks after either path:

```sh
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide
kubectl get events -A --sort-by=.lastTimestamp | \
  rg -i 'fsck|bad message|remote I/O|EREMOTEIO|UNEXPECTED INCONSISTENCY|applyFSGroup|FailedMount|MountVolume|checksum verification failed|Structure needs cleaning'
kubectl -n longhorn-system get volumes.longhorn.io -o wide
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

The target ArgoCD applications should be `Synced` and `Healthy`, and any
live-only recovery patches should be removed or represented in Git.
