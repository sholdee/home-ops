# Prometheus Prom++ Test Build Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the kube-prometheus-stack Prometheus server image with the ARM64 test build `docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481` while preserving existing data.

**Architecture:** The Prometheus Operator owns the running StatefulSet, so the change belongs in `apps/monitoring/values.yaml` under `prometheus.prometheusSpec`, not in a StatefulSet patch. The exact Prom++ test image has passed on-cluster smoke tests on an ARM64 Raspberry Pi 5 node, so the migration can proceed with a pre-migration Longhorn snapshot, chart image fields that render `spec.image`, explicit `spec.version: v3.11.3`, and a temporary guarded `prompptool walvanilla` init container only for the first rollout. The init container mounts the PVC root at `/prometheus-volume`, keeps marker files outside the TSDB directory, and runs conversion against `/prometheus-volume/prometheus-db`; after Prom++ starts, remove the init container immediately in a second GitOps change.

**Tech Stack:** Kustomize with Helm, kube-prometheus-stack `84.5.0`, Prometheus Operator `monitoring.coreos.com/v1`, Prom++ `0.7.10` test build on Docker Hub, Longhorn PVC snapshots.

---

## Current Status

This plan is **unblocked** as of 2026-05-02 after a source fix was identified, a test image was built, pushed, and smoke-tested on the ARM64 cluster. Proceed with the guarded migration tasks below; do not substitute another image without repeating the Task 1 smoke test.

What happened:

- PR #2791 migrated Prometheus to `ghcr.io/deckhouse/prompp:0.7.10`.
- PR #2792 fixed the first init-container bug: the Prom++ image has `/bin/sh` but no `touch`, so marker writes must use POSIX redirection (`: > "$file"`).
- PR #2793 moved marker files outside the Prometheus TSDB path and cleaned the bad marker created inside the TSDB directory.
- Prom++ still failed before WAL conversion. A clean no-PVC Kubernetes smoke test showed exit code `139` and repeated `<jemalloc>: Unsupported system page size`.
- PR #2794 rolled monitoring back to the kube-prometheus-stack default Prometheus image.

Restored state after rollback:

- ArgoCD `monitoring`: `Synced Healthy Succeeded` at revision `570276e8a64bf5e79d81541019eabba24f52ee05`.
- Prometheus pod: `prometheus-kube-prometheus-stack-prometheus-0`, `2/2 Running`, `0` restarts.
- Prometheus CR image: `quay.io/prometheus/prometheus:v3.11.3`.
- The failed migration marker files and generated `prompptool` core dump were removed from the Prometheus PVC.

Resolved blocker:

- Upstream issue: <https://github.com/deckhouse/prompp/issues/87>
- Upstream PR: <https://github.com/deckhouse/prompp/pull/238>
- The upstream PR is included in `v0.7.5` and `v0.7.10`, but the published images tested in this cluster still fail on Raspberry Pi 5 nodes with the jemalloc page-size error.
- Local debugging found the likely packaging/build bug in `pp/bazel/toolchain/BUILD`: the `arm64` Bazel `config_setting` matched `values = {"cpu": "arm"}` while the ARM64 toolchain selects `aarch64`, so the jemalloc build fell back to `--with-lg-page="12"` instead of the intended `--with-lg-page="16"`.
- Test image `docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481` was built from `v0.7.10` with that selector changed to `values = {"cpu": "aarch64"}`.
- The test image passed two on-cluster ARM64 smokes in `monitoring` on `k3s-master-1`: `/bin/prompptool --help` and `/bin/prompp --version`.

## Research Summary

- Repository guidance in `AGENTS.md` requires all images to support `linux/arm64` and prefers tag plus digest pinning.
- `apps/monitoring/kustomization.yaml` deploys `kube-prometheus-stack` chart `84.5.0` with `apps/monitoring/values.yaml`.
- The current rendered Prometheus CR uses `image: quay.io/prometheus/prometheus:v3.11.3`, `version: v3.11.3`, one replica, a `50Gi` Longhorn PVC, and `walCompression: true`.
- The live operator-generated Prometheus StatefulSet mounts the data PVC volume as `prometheus-kube-prometheus-stack-prometheus-db` at `/prometheus` with `subPath: prometheus-db`.
- GHCR has public tags for `deckhouse/prompp`, including `0.7.10`, `0.7.10-amd64`, and `0.7.10-arm64`. The `0.7.10` manifest list digest is `sha256:405dbe39fe3ca1daf9a942a047418c153ace49ccbb91c5ad029552be27b96446`; the linux/arm64 child manifest digest is `sha256:bf3a1c88e5467c98d3694d65fab8c4876fd2df83af4d66c891cfcb5ff646eb87`.
- The GHCR image was verified locally with Docker: `/bin/sh` exists, `/bin/prompp --version` reports `prometheus, version 0.7.10`, and `/bin/prompptool --help` exits successfully on `linux/arm64`. This local check did **not** catch the Raspberry Pi 5 jemalloc page-size failure, so it is now only a preliminary check.
- On-cluster smoke tests failed on Raspberry Pi 5 nodes with `<jemalloc>: Unsupported system page size` and exit code `139` for `ghcr.io/deckhouse/prompp:0.7.10`, `ghcr.io/deckhouse/prompp:0.7.10-arm64`, `prompp/prompp:0.7.10`, and `ghcr.io/deckhouse/prompp:0.7.5`.
- The test image `docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64` has manifest-list digest `sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481`; the linux/arm64 child manifest is `sha256:68e67a36c9ab84f8995cf3244ec66ded82db068a6aa97aeca01f588f0c627949`. The second manifest is the Docker build attestation (`unknown/unknown`) and should not be used as the runtime platform.
- The test image includes a temporary runtime packaging fix that copies the ARM64 glibc loader and C++ runtime libraries into the final image. This is acceptable for the test migration image, but an upstream-ready fix should prefer the project's werf/distroless packaging path.
- On-cluster smoke tests for the test image completed successfully on `k3s-master-1`: `prompp-testbuild-smoke-aarch64` ran `/bin/prompptool --help`, and `prompp-testbuild-version-aarch64` ran `/bin/prompp --version` reporting `prometheus, version 0.7.10-jemalloc-aarch64-fix`, `go version: go1.25.9`, and `platform: linux/arm64`.
- The rollback Prometheus image `quay.io/prometheus/prometheus:v3.11.3` has manifest-list digest `sha256:c0b857aead0d5793aa566adb8f49a9983d6f6031652098759d521a330cfa050f` and a linux/arm64 child manifest `sha256:8737f27a6102141f06bd38e10e8908a8fa39a649cd187a2fee7c4b8429a366d6`.
- Prom++ documents itself as a Prometheus-compatible replacement, but it uses a different WAL format. Existing Prometheus WAL must be converted with `prompptool walvanilla` to avoid losing the last 1.5 blocks of data, typically around 3 hours.
- Prom++ documents broad Prometheus compatibility, but it does not publish a clear `0.7.10` to upstream Prometheus `v3.11.3` compatibility matrix. This plan accepts that residual compatibility risk and controls it with a pre-migration snapshot, guarded one-shot WAL conversion, server-side dry-run, readiness/query validation, and a reverse-conversion rollback.
- Prometheus Operator documents that `spec.image` overrides image base/tag/sha fields, but `spec.version` is still needed so the operator knows the Prometheus feature compatibility version. Because kube-prometheus-stack defaults `version` from the image tag unless overridden, this migration must set `prometheus.prometheusSpec.version: v3.11.3` explicitly.

Sources:

- Deckhouse Prom++ README and migration notes: <https://github.com/deckhouse/prompp>
- Deckhouse Prom++ release `v0.7.10`: <https://github.com/deckhouse/prompp/releases/tag/v0.7.10>
- Raspberry Pi 5 jemalloc issue: <https://github.com/deckhouse/prompp/issues/87>
- Upstream page-size fix PR: <https://github.com/deckhouse/prompp/pull/238>
- Test image manifest inspected with `docker buildx imagetools inspect sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64`
- Prometheus Operator API reference: <https://prometheus-operator.dev/docs/api-reference/api/>
- GHCR registry API checked at `https://ghcr.io/v2/deckhouse/prompp/tags/list` and `https://ghcr.io/v2/deckhouse/prompp/manifests/0.7.10`
- Quay registry API checked at `https://quay.io/v2/prometheus/prometheus/manifests/v3.11.3`

## File Structure

- Modify: `apps/monitoring/values.yaml`
  - Adds the Prom++ image override, digest pin, explicit operator compatibility version, and temporary WAL conversion init container for the first rollout.
  - Removes the temporary WAL conversion init container in the cleanup change.
- No change: `apps/monitoring/kustomization.yaml`
  - The chart and values wiring already support this migration.
- No change: `apps/monitoring/prometheus/manifests/httproute.yaml`
  - The service name and port remain `kube-prometheus-stack-prometheus:9090`.

---

### Task 1: Preflight And Snapshot

**Files:**

- No repository files changed.

- [x] **Step 1: Confirm local guidance and feature branch state**

Run:

```bash
rg --files -g 'AGENTS.md' -g 'CLAUDE.md' .
git branch --show-current
git status --short
```

Expected:

```text
AGENTS.md
prompp-testbuild-migration
```

`git status --short` should include only this plan before the manifest edit:

```text
?? docs/superpowers/
```

- [x] **Step 2: Confirm the current rendered Prometheus image, version, and storage**

Run:

```bash
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/monitoring/ \
  | yq 'select(.apiVersion == "monitoring.coreos.com/v1" and .kind == "Prometheus") | {"image": .spec.image, "version": .spec.version, "storage": .spec.storage, "initContainers": .spec.initContainers}'
```

Expected:

```yaml
image: quay.io/prometheus/prometheus:v3.11.3
version: v3.11.3
storage:
  volumeClaimTemplate:
    spec:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 50Gi
      storageClassName: longhorn
initContainers: null
```

- [x] **Step 3: Confirm the live Prometheus data volume mount**

Run:

```bash
kubectl get statefulset -n monitoring prometheus-kube-prometheus-stack-prometheus \
  -o jsonpath='{range .spec.template.spec.containers[?(@.name=="prometheus")].volumeMounts[*]}{.name}{" "}{.mountPath}{" "}{.subPath}{"\n"}{end}'
```

Expected line:

```text
prometheus-kube-prometheus-stack-prometheus-db /prometheus prometheus-db
```

- [x] **Step 4: Preliminary local check that the Prom++ image has the binaries needed by this plan**

Run:

```bash
docker run --rm --platform linux/arm64 --entrypoint /bin/sh \
  docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481 \
  -ec 'test -x /bin/sh; /bin/prompp --version; /bin/prompptool --help >/dev/null; echo ok'
```

Expected:

```text
prometheus, version 0.7.10-jemalloc-aarch64-fix
ok
```

The version output must show `platform: linux/arm64`.

This is only a binary-presence check. It is not sufficient to prove the image works on Raspberry Pi 5 nodes.

- [x] **Step 5: Hard gate: prove the Prom++ image starts on the actual Prometheus node**

Run this on the exact image tag and digest intended for deployment. Do not continue if this fails.

```bash
IMAGE='docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481'
PROM_NODE="$(kubectl get pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.spec.nodeName}')"

kubectl delete pod -n monitoring prompp-smoke --ignore-not-found
kubectl run -n monitoring prompp-smoke \
  --image="${IMAGE}" \
  --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"${PROM_NODE}\"}}" \
  --command -- /bin/sh -ec '/bin/prompptool --help >/dev/null && /bin/prompp --version'

kubectl wait -n monitoring \
  --for=jsonpath='{.status.phase}'=Succeeded \
  pod/prompp-smoke \
  --timeout=2m

kubectl logs -n monitoring prompp-smoke
kubectl delete pod -n monitoring prompp-smoke
```

Expected:

```text
pod/prompp-smoke condition met
prometheus, version 0.7.10-jemalloc-aarch64-fix
```

The logs must not contain:

```text
<jemalloc>: Unsupported system page size
```

If the pod exits `139`, emits the jemalloc page-size error, or does not reach `Succeeded`, delete the smoke pod and stop the migration. Do not create snapshots, do not open a migration PR, and do not mutate the Prometheus PVC.

- [x] **Step 6: Confirm there are no stale failed-migration artifacts on the PVC**

Run:

```bash
PROM_NODE="$(kubectl get pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.spec.nodeName}')"

kubectl delete pod -n monitoring prompp-pvc-check --ignore-not-found
kubectl run -n monitoring prompp-pvc-check \
  --image=busybox:1.37.0@sha256:1487d0af5f52b4ba31c7e465126ee2123fe3f2305d638e7827681e7cf6c83d5e \
  --restart=Never \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"${PROM_NODE}\",\"volumes\":[{\"name\":\"promdb\",\"persistentVolumeClaim\":{\"claimName\":\"prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0\"}}],\"containers\":[{\"name\":\"prompp-pvc-check\",\"image\":\"busybox:1.37.0@sha256:1487d0af5f52b4ba31c7e465126ee2123fe3f2305d638e7827681e7cf6c83d5e\",\"command\":[\"/bin/sh\",\"-ec\",\"find /prometheus-volume -maxdepth 2 -name '.prompp-walvanilla-started' -o -name '.prompp-walvanilla-complete' -o -name '.prompp-walpp-started' -o -name '.prompp-walpp-complete' -o -name core\"],\"volumeMounts\":[{\"name\":\"promdb\",\"mountPath\":\"/prometheus-volume\"}],\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"memory\":\"64Mi\"}}}]}}"

kubectl logs -n monitoring prompp-pvc-check
kubectl delete pod -n monitoring prompp-pvc-check
```

Expected: `kubectl logs` prints no file paths.

If stale `.prompp-*` marker files or a `core` file are present, stop and inspect before proceeding. Only remove files that are known artifacts from the failed Prom++ attempt, and verify the live Prometheus image is still `quay.io/prometheus/prometheus:v3.11.3` before deleting anything from the PVC.

Execution note, 2026-05-02: the first check found stale `/prometheus-volume/.prompp-walvanilla-started`. Live Prometheus was verified as `quay.io/prometheus/prometheus:v3.11.3`, pod status was `Running config-reloader=true:0 prometheus=true:0`, then only that known stale marker was removed. The follow-up PVC check printed no paths.

- [x] **Step 7: Create a Longhorn VolumeSnapshot before changing the WAL format**

Run:

```bash
SNAPSHOT_NAME="prometheus-pre-prompp-$(date +%Y%m%d%H%M%S)"
cat <<YAML | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: monitoring
spec:
  volumeSnapshotClassName: longhorn
  source:
    persistentVolumeClaimName: prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
YAML
```

Then run:

```bash
kubectl wait -n monitoring \
  --for=jsonpath='{.status.readyToUse}'=true \
  "volumesnapshot/${SNAPSHOT_NAME}" \
  --timeout=10m
```

Expected:

```text
volumesnapshot.snapshot.storage.k8s.io/<snapshot-name> condition met
```

Execution note, 2026-05-02: created and verified `volumesnapshot.snapshot.storage.k8s.io/prometheus-pre-prompp-20260502144044`.

---

### Task 2: Add The Prom++ Image And One-Shot WAL Conversion

**Files:**

- Modify: `apps/monitoring/values.yaml`

- [x] **Step 1: Add only the Prom++ image override, explicit operator version, and guarded conversion init container**

Insert these keys under `prometheus.prometheusSpec` in `apps/monitoring/values.yaml`. Preserve every existing key in that block, including `externalUrl`, `storageSpec`, `resources`, and `affinity`.

```yaml
prometheus:
  prometheusSpec:
    image:
      registry: docker.io
      repository: sholdee/prompp
      tag: "0.7.10-jemalloc-aarch64-fix-arm64"
      sha: df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481
      pullPolicy: IfNotPresent
    version: v3.11.3
    initContainers:
      - name: prompptool-walvanilla
        image: docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481
        command:
          - /bin/sh
          - -ec
          - |
            started=/prometheus-volume/.prompp-walvanilla-started
            complete=/prometheus-volume/.prompp-walvanilla-complete
            if [ -f "$complete" ]; then
              echo "Prom++ WAL conversion marker exists; skipping walvanilla"
              exit 0
            fi
            if [ -f "$started" ]; then
              echo "Prom++ WAL conversion started previously but did not complete; refusing automatic retry" >&2
              exit 1
            fi
            : > "$started"
            /bin/prompptool --working-dir=/prometheus-volume/prometheus-db walvanilla
            : > "$complete"
        volumeMounts:
          - name: prometheus-kube-prometheus-stack-prometheus-db
            mountPath: /prometheus-volume
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 2Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
```

Keep the rest of the existing `prometheus.prometheusSpec` settings unchanged. The marker guard is required because ArgoCD and the Prometheus Operator may recreate the pod before the cleanup PR lands; reruns must skip conversion after the first successful `walvanilla`, and a failed partial conversion must not be retried automatically. Marker files must live in the PVC root (`/prometheus-volume`), not in the Prometheus TSDB directory (`/prometheus-volume/prometheus-db`), because `prompptool` should see only Prometheus TSDB contents in its working directory.

- [x] **Step 2: Render the Prometheus CR and confirm the image, version, and init container**

Run:

```bash
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/monitoring/ \
  | yq 'select(.apiVersion == "monitoring.coreos.com/v1" and .kind == "Prometheus") | {"image": .spec.image, "version": .spec.version, "initContainers": .spec.initContainers}'
```

Expected:

```yaml
image: docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481
version: v3.11.3
initContainers:
  - command:
      - /bin/sh
      - -ec
      - |
        started=/prometheus-volume/.prompp-walvanilla-started
        complete=/prometheus-volume/.prompp-walvanilla-complete
        if [ -f "$complete" ]; then
          echo "Prom++ WAL conversion marker exists; skipping walvanilla"
          exit 0
        fi
        if [ -f "$started" ]; then
          echo "Prom++ WAL conversion started previously but did not complete; refusing automatic retry" >&2
          exit 1
        fi
        : > "$started"
        /bin/prompptool --working-dir=/prometheus-volume/prometheus-db walvanilla
        : > "$complete"
    image: docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481
    name: prompptool-walvanilla
    resources:
      limits:
        memory: 2Gi
      requests:
        cpu: 100m
        memory: 256Mi
    volumeMounts:
      - mountPath: /prometheus-volume
        name: prometheus-kube-prometheus-stack-prometheus-db
```

- [x] **Step 3: Run a server-side dry-run with ArgoCD's field manager**

Run:

```bash
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/monitoring/ \
  | kubectl apply --server-side --dry-run=server --field-manager=argocd-controller -f -
```

Expected: the dry-run completes without schema, admission, or field ownership errors.

- [x] **Step 4: Run the repository validation for the changed file**

Run:

```bash
pre-commit run --files apps/monitoring/values.yaml
```

Expected: all hooks pass.

Execution note, 2026-05-02: `pre-commit run --files apps/monitoring/values.yaml docs/superpowers/plans/2026-05-02-prompp-ghcr-migration.md` passed after rerunning with network access for the Helm-backed `kustomize build` hook.

- [x] **Step 5: Commit the migration change**

Run:

```bash
git add apps/monitoring/values.yaml
git commit -m "feat: migrate prometheus to prompp"
```

Expected: a commit containing `apps/monitoring/values.yaml` and this migration plan.

Execution note, 2026-05-02: committed as `e0e2d183 feat: migrate prometheus to prompp test build`; merged through PR #2795 as `067ccaa8`.

---

### Task 3: Merge The Migration PR And Validate The First Rollout

**Files:**

- No repository files changed.

- [x] **Step 1: Schedule a maintenance window and prepare cleanup before syncing**

Prometheus has one replica, so expect a short monitoring and query outage while the pod restarts and converts WAL. Silence noisy Prometheus/target-down alerts for the maintenance window, and have the cleanup change from Task 4 ready to merge immediately after the first Prom++ readiness check succeeds.

Expected: the operator is not being upgraded, nodes hosting Longhorn replicas are stable, and no node drain is planned during the migration window.

- [x] **Step 2: Open and merge the migration PR**

Use the normal branch and PR flow for this repository. Merge only after CI passes.

Expected: ArgoCD syncs the `monitoring` application from `master`.

- [x] **Step 3: Watch the Prometheus pod restart**

Run:

```bash
kubectl get pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -w
```

Expected: the pod restarts, runs the `prompptool-walvanilla` init container, and returns to `2/2 Running`.

- [x] **Step 4: Check the WAL conversion init container logs**

Run:

```bash
kubectl logs -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prompptool-walvanilla
```

Expected: the command completes without conversion errors. If the pod is recreated before cleanup, the log should contain `Prom++ WAL conversion marker exists; skipping walvanilla` on the later run.

If the init container exits non-zero after creating `/prometheus-volume/.prompp-walvanilla-started` but before creating `/prometheus-volume/.prompp-walvanilla-complete`, stop the rollout. Do not delete the marker and retry. Inspect logs and either restore the pre-migration snapshot or perform a deliberate manual repair.

If logs contain this message, the Prom++ image is still incompatible with the Raspberry Pi 5 node page size and the migration must be rolled back:

```text
<jemalloc>: Unsupported system page size
```

In that case, do not retry `walvanilla`; the failure happens before WAL conversion code runs.

Execution note, 2026-05-02: `prompptool-walvanilla` exited `0`. Logs showed WAL replay completed, two blocks written, and checkpoint creation completed; no jemalloc page-size error appeared.

- [x] **Step 5: Confirm ArgoCD, Prometheus Operator, and StatefulSet status**

Run:

```bash
kubectl get application -n argocd monitoring \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl rollout status statefulset/prometheus-kube-prometheus-stack-prometheus \
  -n monitoring \
  --timeout=20m
kubectl wait -n monitoring \
  --for=condition=Ready \
  pod/prometheus-kube-prometheus-stack-prometheus-0 \
  --timeout=20m
```

Then run:

```bash
kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus \
  -o jsonpath='{.metadata.generation} {.status.conditions[?(@.type=="Reconciled")].observedGeneration} {.status.conditions[?(@.type=="Available")].status}{"\n"}'
```

Expected:

```text
Synced Healthy
statefulset rolling update complete
<generation> <same-generation> True
```

If any command stalls, collect diagnostics before changing Git again:

```bash
kubectl describe pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0
kubectl get events -n monitoring --sort-by=.lastTimestamp
kubectl logs -n monitoring deploy/kube-prometheus-stack-operator
kubectl logs -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus --previous
```

- [x] **Step 6: Confirm the service is healthy and queryable**

In one terminal, run:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

In another terminal, run:

```bash
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:9090/api/v1/status/buildinfo
curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up'
```

Expected: readiness returns success, both API calls return JSON with `"status":"success"`, and buildinfo reports version `0.7.10-jemalloc-aarch64-fix`.

Execution note, 2026-05-02: ArgoCD synced revision `067ccaa8a4493b54794865d08eea6893f577c5ce`; Prometheus CR rendered the pinned Prom++ image, `v3.11.3`, Available `True`, generation `15` observed as `15`; StatefulSet rollout completed; pod was Ready with `prompptool-walvanilla=0`, `config-reloader=true:0`, and `prometheus=true:0`; `/-/ready`, `/api/v1/status/buildinfo`, and `/api/v1/query?query=up` all succeeded.

---

### Task 4: Remove The One-Shot WAL Conversion Init Container

**Files:**

- Modify: `apps/monitoring/values.yaml`

- [x] **Step 1: Remove only the temporary `initContainers` block**

Edit `apps/monitoring/values.yaml` so `prometheus.prometheusSpec` keeps this image and version block:

```yaml
prometheus:
  prometheusSpec:
    image:
      registry: docker.io
      repository: sholdee/prompp
      tag: "0.7.10-jemalloc-aarch64-fix-arm64"
      sha: df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481
      pullPolicy: IfNotPresent
    version: v3.11.3
    serviceMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
```

Remove the `prometheus.prometheusSpec.initContainers` key entirely.

- [x] **Step 2: Render the final Prometheus CR**

Run:

```bash
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/monitoring/ \
  | yq 'select(.apiVersion == "monitoring.coreos.com/v1" and .kind == "Prometheus") | {"image": .spec.image, "version": .spec.version, "initContainers": .spec.initContainers}'
```

Expected:

```yaml
image: docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481
version: v3.11.3
initContainers: null
```

- [x] **Step 3: Run a server-side dry-run with ArgoCD's field manager**

Run:

```bash
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/monitoring/ \
  | kubectl apply --server-side --dry-run=server --field-manager=argocd-controller -f -
```

Expected: the dry-run completes without schema, admission, or field ownership errors.

- [x] **Step 4: Run repository validation**

Run:

```bash
pre-commit run --files apps/monitoring/values.yaml
```

Expected: all hooks pass.

Execution note, 2026-05-02: final render showed the pinned Prom++ image, `version: v3.11.3`, and `initContainers: null`; the ArgoCD-style server-side dry-run completed; `pre-commit run --files apps/monitoring/values.yaml docs/superpowers/plans/2026-05-02-prompp-ghcr-migration.md` passed.

- [x] **Step 5: Commit the cleanup change**

Run:

```bash
git add apps/monitoring/values.yaml
git commit -m "chore: remove prompp wal migration init container"
```

Expected: a commit containing `apps/monitoring/values.yaml` and this migration plan.

Execution note, 2026-05-02: committed as `a29b5c82 chore: remove prompp wal migration init container`; merged through PR #2796 as `2c8eae5e`.

- [x] **Step 6: Merge the cleanup PR and validate final state**

After CI passes and ArgoCD syncs, run:

```bash
kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.image}{"\n"}{.spec.version}{"\n"}{.spec.initContainers}{"\n"}'
```

Expected:

```text
docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481
v3.11.3
```

The third line should be empty.

Execution note, 2026-05-02: ArgoCD synced cleanup revision `2c8eae5e479f1f5eaba35530f14ce22e9716fb2c` and returned `Synced Healthy Succeeded`; the live Prometheus CR has the pinned Prom++ image, `version: v3.11.3`, no `spec.initContainers`, Available `True`, and generation `16` observed as `16`; the pod is Ready with `init-config-reloader=0`, `config-reloader=true:0`, and `prometheus=true:0`; final API checks returned `Prometheus Server is Ready.`, buildinfo version `0.7.10-jemalloc-aarch64-fix`, and query `up` returned `success results=103`.

---

## Rollback Runbook

Do not simply revert to `quay.io/prometheus/prometheus` after Prom++ has started, because Prom++ writes a different WAL format. Use the reverse WAL conversion first.

### Rollback Before WAL Conversion Starts

Only use a simple Git revert if `prompptool-walvanilla` has not started and did not modify the PVC. Check that before reverting:

```bash
kubectl get pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 \
  -o jsonpath='{.status.initContainerStatuses[?(@.name=="prompptool-walvanilla")].state.terminated.exitCode}{"\n"}'
kubectl logs -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prompptool-walvanilla
```

Expected safe-to-revert state: no terminated exit code and no conversion log output. If `walvanilla` exited `0`, printed conversion output, or created `/prometheus-volume/.prompp-walvanilla-complete`, the WAL may already be in Prom++ format; use reverse conversion or restore the pre-migration snapshot instead.

### Rollback For Jemalloc Startup Failure

If the init container logs show `<jemalloc>: Unsupported system page size`, `prompptool` failed during process startup before conversion code could run. In the 2026-05-02 attempt this left marker files and a core dump, but the vanilla Prometheus WAL was still readable after those artifacts were removed and the image was rolled back.

1. Confirm the failure signature:

```bash
kubectl logs -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prompptool-walvanilla --tail=100
kubectl get pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 \
  -o jsonpath='{.status.initContainerStatuses[?(@.name=="prompptool-walvanilla")].state.terminated.exitCode}{"\n"}'
```

Expected:

```text
<jemalloc>: Unsupported system page size
139
```

1. Use a temporary PVC inspection pod to remove only the known failed-attempt artifacts:

```bash
PROM_NODE="$(kubectl get pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.spec.nodeName}')"

kubectl delete pod -n monitoring prompp-pvc-repair --ignore-not-found
kubectl run -n monitoring prompp-pvc-repair \
  --image=busybox:1.37.0@sha256:1487d0af5f52b4ba31c7e465126ee2123fe3f2305d638e7827681e7cf6c83d5e \
  --restart=Never \
  --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeName\":\"${PROM_NODE}\",\"volumes\":[{\"name\":\"promdb\",\"persistentVolumeClaim\":{\"claimName\":\"prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0\"}}],\"containers\":[{\"name\":\"prompp-pvc-repair\",\"image\":\"busybox:1.37.0@sha256:1487d0af5f52b4ba31c7e465126ee2123fe3f2305d638e7827681e7cf6c83d5e\",\"command\":[\"/bin/sh\",\"-ec\",\"rm -f /prometheus-volume/.prompp-walvanilla-started /prometheus-volume/.prompp-walvanilla-complete /prometheus-volume/prometheus-db/.prompp-walvanilla-started /prometheus-volume/prometheus-db/.prompp-walvanilla-complete /prometheus-volume/prometheus-db/core && find /prometheus-volume -maxdepth 2 -name '.prompp-walvanilla-started' -o -name '.prompp-walvanilla-complete' -o -name core\"],\"volumeMounts\":[{\"name\":\"promdb\",\"mountPath\":\"/prometheus-volume\"}],\"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"memory\":\"64Mi\"}}}]}}"

kubectl logs -n monitoring prompp-pvc-repair
kubectl delete pod -n monitoring prompp-pvc-repair
```

Expected: `kubectl logs` prints no remaining marker or core paths.

1. Create and merge a rollback PR that removes the Prom++ image override and all Prom++ init containers, returning kube-prometheus-stack to its default `quay.io/prometheus/prometheus:v3.11.3` image.

1. After ArgoCD syncs, verify:

```bash
kubectl get application -n argocd monitoring \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase} {.status.sync.revision}{"\n"}'
kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.image}{" "}{.spec.version}{" "}{.status.conditions[?(@.type=="Available")].status}{"\n"}'
kubectl get pod -n monitoring prometheus-kube-prometheus-stack-prometheus-0 \
  -o jsonpath='{.status.phase} {range .status.containerStatuses[*]}{.name}={.ready}:{.restartCount} {end}{"\n"}'
```

Expected:

```text
Synced Healthy Succeeded <rollback-revision>
quay.io/prometheus/prometheus:v3.11.3 v3.11.3 True
Running config-reloader=true:0 prometheus=true:0
```

### Rollback After WAL Conversion Starts Or Completes

1. Create a Prom++ state snapshot before rewriting the WAL again:

```bash
ROLLBACK_SNAPSHOT_NAME="prometheus-prompp-before-walpp-$(date +%Y%m%d%H%M%S)"
cat <<YAML | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${ROLLBACK_SNAPSHOT_NAME}
  namespace: monitoring
spec:
  volumeSnapshotClassName: longhorn
  source:
    persistentVolumeClaimName: prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
YAML
kubectl wait -n monitoring \
  --for=jsonpath='{.status.readyToUse}'=true \
  "volumesnapshot/${ROLLBACK_SNAPSHOT_NAME}" \
  --timeout=10m
```

1. Create a rollback PR that restores the digest-pinned Prometheus image and adds this temporary guarded reverse conversion init container:

```yaml
prometheus:
  prometheusSpec:
    image:
      registry: quay.io
      repository: prometheus/prometheus
      tag: v3.11.3
      sha: c0b857aead0d5793aa566adb8f49a9983d6f6031652098759d521a330cfa050f
      pullPolicy: IfNotPresent
    version: v3.11.3
    initContainers:
      - name: prompptool-walpp
        image: docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:df1285d2da16952348de8b094f5332cb68b8241399941b6c2c7c3dc03b284481
        command:
          - /bin/sh
          - -ec
          - |
            started=/prometheus-volume/.prompp-walpp-started
            complete=/prometheus-volume/.prompp-walpp-complete
            if [ -f "$complete" ]; then
              echo "Prom++ rollback marker exists; skipping walpp"
              exit 0
            fi
            if [ -f "$started" ]; then
              echo "Prom++ rollback conversion started previously but did not complete; refusing automatic retry" >&2
              exit 1
            fi
            : > "$started"
            /bin/prompptool --working-dir=/prometheus-volume/prometheus-db --verbose walpp
            rm -f /prometheus-volume/.prompp-walvanilla-complete
            : > "$complete"
        volumeMounts:
          - name: prometheus-kube-prometheus-stack-prometheus-db
            mountPath: /prometheus-volume
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 2Gi
```

1. Render and validate the rollback PR:

```bash
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/monitoring/ \
  | yq 'select(.apiVersion == "monitoring.coreos.com/v1" and .kind == "Prometheus") | {"image": .spec.image, "version": .spec.version, "initContainers": .spec.initContainers}'
pre-commit run --files apps/monitoring/values.yaml
```

Expected: image renders as `quay.io/prometheus/prometheus:v3.11.3@sha256:c0b857aead0d5793aa566adb8f49a9983d6f6031652098759d521a330cfa050f`, version remains `v3.11.3`, and the init container command contains `walpp`.

Then run the rollback server-side dry-run:

```bash
kustomize build --enable-helm \
  --helm-api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
  apps/monitoring/ \
  | kubectl apply --server-side --dry-run=server --field-manager=argocd-controller -f -
```

Expected: the dry-run completes without schema, admission, or field ownership errors.

1. Merge the rollback PR, wait for Prometheus to become `Ready`, and verify `/api/v1/query?query=up` succeeds.

1. Create and merge a cleanup PR that removes the temporary `prompptool-walpp` init container.

---

## Notes For Implementation

- Do not substitute this test image with an upstream image until the exact replacement image passes the Task 1 on-cluster smoke test on the current Prometheus node. The upstream PR for Raspberry Pi page-size support is merged, but the tested published images still failed in this cluster.
- If the fix arrives as a rebuilt upstream `0.7.10` image with a new digest, update every `docker.io/sholdee/prompp:0.7.10-jemalloc-aarch64-fix-arm64@sha256:...` reference in this plan before implementation. If the fix arrives only in a later tag, update the plan title, goal, image snippets, smoke-test command, and validation expectations before proceeding.
- The migration is intentionally two PRs because the conversion init container is not a stable desired state. The marker guard makes pod restarts safe during the migration window, but cleanup should still be merged immediately after the first successful Prom++ readiness and query checks.
- Keep `prometheus.prometheusSpec.version: v3.11.3` even though the image tag is `0.7.10-jemalloc-aarch64-fix-arm64`; the operator uses `version` for feature compatibility and command generation.
- Prom++ `0.7.10` does not expose an upstream Prometheus version mapping in the sources checked for this plan. Proceed only with the accepted compatibility risk documented above and the rollback path ready.
- The current Prometheus pod runs as UID `1000`, GID `2000`, with `fsGroup: 2000`. The conversion init container inherits that pod-level context but mounts the PVC root at `/prometheus-volume` so marker files can live outside the TSDB directory.
- The Docker Hub digest is the manifest-list digest. That keeps the image pin architecture-neutral while still resolving to the linux/arm64 child manifest on Raspberry Pi nodes.
- If restoring the pre-migration snapshot after the cleanup PR has merged, either restore the Prometheus image at the same time or temporarily re-add the guarded `walvanilla` init container, because the restored snapshot may not contain the Prom++ WAL marker.
