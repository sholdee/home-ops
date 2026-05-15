#!/usr/bin/env bash
# shellcheck shell=bash

LIMA_LONGHORN_NAMESPACE="${LIMA_LONGHORN_NAMESPACE:-lima-longhorn-check}"
LIMA_LONGHORN_DEPLOYMENT="${LIMA_LONGHORN_DEPLOYMENT:-checksum-writer}"
LIMA_LONGHORN_PVC="${LIMA_LONGHORN_PVC:-checksum-data}"

lima_longhorn_kubectl() {
  if declare -F kubectl_cmd >/dev/null 2>&1; then
    kubectl_cmd "$@"
  elif declare -F kubectl_lima >/dev/null 2>&1; then
    kubectl_lima "$@"
  else
    kubectl "$@"
  fi
}

write_lima_longhorn_workload() {
  local output="$1"
  cat > "$output" <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${LIMA_LONGHORN_NAMESPACE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${LIMA_LONGHORN_PVC}
  namespace: ${LIMA_LONGHORN_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: longhorn-retain
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${LIMA_LONGHORN_DEPLOYMENT}
  namespace: ${LIMA_LONGHORN_NAMESPACE}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: ${LIMA_LONGHORN_DEPLOYMENT}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${LIMA_LONGHORN_DEPLOYMENT}
    spec:
      containers:
        - name: checksum
          image: docker.io/library/busybox:1.37.0
          command:
            - sh
            - -ceu
            - |-
              cd /data
              if [ ! -f data.sha256 ]; then
                i=0
                : > data.txt
                while [ "\$i" -lt 20000 ]; do
                  printf 'home-ops-longhorn-%s\n' "\$i" >> data.txt
                  i=\$((i + 1))
                done
                sha256sum data.txt > data.sha256
                sync
              fi
              while true; do
                sha256sum -c data.sha256
                sleep 10
              done
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${LIMA_LONGHORN_PVC}
EOF
}

apply_lima_longhorn_storage_manifests() {
  local render
  render="${TMP_DIR}/lima-longhorn-storage.yaml"
  {
    cat "${REPO_ROOT}/apps/longhorn-system/manifests/storageclass.yaml"
    printf '%s\n' '---'
    cat "${REPO_ROOT}/apps/longhorn-system/manifests/volumesnapshotclass.yaml"
  } > "$render"
  apply_file "$render"
  save_render_if_safe lima-longhorn-storage "$render"
}

apply_lima_longhorn_workload() {
  local workload
  workload="${TMP_DIR}/lima-longhorn-workload.yaml"
  write_lima_longhorn_workload "$workload"
  apply_file "$workload"
  save_render_if_safe lima-longhorn-workload "$workload"
}

wait_lima_longhorn_workload_ready() {
  local deadline
  if bool "$DRY_RUN"; then
    log "dry-run: skip wait for Lima Longhorn checksum workload"
    return
  fi

  deadline=$((SECONDS + 900))
  while ((SECONDS < deadline)); do
    if lima_longhorn_verify_checksum >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done

  lima_longhorn_kubectl -n "$LIMA_LONGHORN_NAMESPACE" get pods -o wide || true
  lima_longhorn_kubectl -n "$LIMA_LONGHORN_NAMESPACE" describe "deployment/${LIMA_LONGHORN_DEPLOYMENT}" || true
  lima_longhorn_kubectl -n "$LIMA_LONGHORN_NAMESPACE" describe "pvc/${LIMA_LONGHORN_PVC}" || true
  die "timed out waiting for Lima Longhorn checksum workload"
}

lima_longhorn_verify_checksum() {
  lima_longhorn_kubectl -n "$LIMA_LONGHORN_NAMESPACE" exec "deployment/${LIMA_LONGHORN_DEPLOYMENT}" -- \
    sh -ceu 'cd /data && sha256sum -c data.sha256'
}

lima_longhorn_require_volume_healthy() {
  local pv status robustness
  pv="$(
    lima_longhorn_kubectl -n "$LIMA_LONGHORN_NAMESPACE" get "pvc/${LIMA_LONGHORN_PVC}" \
      -o jsonpath='{.spec.volumeName}'
  )"
  [[ -n "$pv" ]] || return 1
  status="$(lima_longhorn_kubectl -n longhorn-system get "volume.longhorn.io/${pv}" -o json)"
  robustness="$(jq -r '.status.robustness // ""' <<<"$status")"
  [[ "$robustness" == healthy ]]
}

wait_lima_longhorn_volume_healthy() {
  local deadline
  deadline=$((SECONDS + 900))
  while ((SECONDS < deadline)); do
    if lima_longhorn_require_volume_healthy >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  return 1
}

lima_longhorn_corruption_event_report() {
  lima_longhorn_kubectl get events -A -o json | jq -r '
    .items[]
    | select(
        (.message // "") |
        test("I/O error|Input/output error|Structure needs cleaning|EXT4-fs error|XFS.*corrupt"; "i")
      )
    | [
        .metadata.namespace,
        .involvedObject.kind,
        .involvedObject.name,
        .reason,
        .message
      ]
    | @tsv
  '
}

lima_longhorn_validate_workload() {
  local event_report
  lima_longhorn_kubectl -n "$LIMA_LONGHORN_NAMESPACE" rollout status "deployment/${LIMA_LONGHORN_DEPLOYMENT}" --timeout=300s
  lima_longhorn_verify_checksum
  wait_lima_longhorn_volume_healthy || {
    lima_longhorn_kubectl -n longhorn-system get volumes.longhorn.io -o wide || true
    return 1
  }
  event_report="$(lima_longhorn_corruption_event_report)"
  [[ -z "$event_report" ]] || {
    printf '%s\n' "$event_report" >&2
    return 1
  }
}
