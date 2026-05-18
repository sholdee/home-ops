# How-To Templates

Reference templates for common operations. Read this file when adding new apps, setting up VolSync, secrets, networking, or network policies.

## Adding a New Simple App (Kustomize Only)

1. Create `apps/<name>/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <name>
components:
  - ../../components/namespace
resources:
  - manifests/namespace.yaml
  - manifests/deployment.yaml
  - manifests/service.yaml
  - manifests/httproute.yaml
```

1. Create `apps/<name>/manifests/namespace.yaml`, deployment, service, and HTTPRoute manifests
2. The ApplicationSet automatically picks up the new `apps/<name>/` directory

## Adding a New Helm App

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <name>
components:
  - ../../components/namespace
resources:
  - manifests/namespace.yaml
helmCharts:
  - name: <chart-name>
    repo: <repo-url>
    version: <version>
    releaseName: <release-name>
    namespace: <name>
    valuesFile: manifests/values.yaml
```

## VolSync Backup Setup

Apps needing persistent data backup include two components and apply patches:

```yaml
components:
  - ../../components/volsync        # PVC template
  - ../../components/volsync/b2     # B2 backup (ExternalSecret + ReplicationSource + ReplicationDestination)
```

Then patch all four resources to replace generic `app` names with the actual app name:

```yaml
patches:
  - target:
      kind: ReplicationSource
      name: app
    patch: |-
      - op: replace
        path: /metadata/name
        value: <app-name>
      - op: replace
        path: /spec/sourcePVC
        value: <app-name>-pvc
      - op: replace
        path: /spec/restic/repository
        value: <app-name>-volsync-b2
  - target:
      kind: ReplicationDestination
      name: app-bootstrap
    patch: |-
      - op: replace
        path: /metadata/name
        value: <app-name>-bootstrap
      - op: replace
        path: /spec/restic/repository
        value: <app-name>-volsync-b2
  - target:
      kind: ExternalSecret
      name: app-volsync-b2
    patch: |-
      - op: replace
        path: /metadata/name
        value: <app-name>-volsync-b2
      - op: replace
        path: /spec/target/name
        value: <app-name>-volsync-b2
      - op: replace
        path: /spec/target/template/data/RESTIC_REPOSITORY
        value: "s3:s3.us-west-002.backblazeb2.com/sholdee-volsync/<app-name>"
  - target:
      kind: PersistentVolumeClaim
      name: app-pvc
    patch: |-
      - op: replace
        path: /metadata/name
        value: <app-name>-pvc
      - op: replace
        path: /spec/dataSourceRef/name
        value: <app-name>-bootstrap
```

Some apps also override `accessModes` to `ReadWriteMany` (e.g., hass, zwave, mealie).

## Adding Secrets via External Secrets

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <secret-name>
  namespace: <namespace>
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: <secret-name>
    template:
      engineVersion: v2
      data:
        <key>: "{{ .<1PASSWORD_FIELD> }}"
  dataFrom:
    - extract:
        key: <1password-item-name>
```

## Exposing an App via HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>
  namespace: <namespace>
spec:
  parentRefs:
    - name: envoy-gateway         # Internal: *.mgmt.sholdee.net
      namespace: gateway
      # OR
    - name: external-gateway      # External: *.sholdee.net
      namespace: gateway
  hostnames:
    - <app>.mgmt.sholdee.net      # or <app>.sholdee.net
  rules:
    - backendRefs:
        - name: <service-name>
          namespace: <namespace>
          port: <port>
```

## Adding a CiliumNetworkPolicy

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: <app>
  namespace: <namespace>
spec:
  endpointSelector:
    matchLabels:
      app: <app-label>
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            gateway.envoyproxy.io/owning-gateway-name: envoy-gateway
      toPorts:
        - ports:
            - port: "<port>"
              protocol: TCP
```
