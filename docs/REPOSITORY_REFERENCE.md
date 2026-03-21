# home-ops Repository Reference

Comprehensive architectural reference for the `sholdee/home-ops` K3s GitOps repository. This document is designed so that any LLM or engineer can ingest it and make expert-level changes to any part of the repository.

---

## Table of Contents

1. [Repository Overview](#repository-overview)
2. [Directory Structure](#directory-structure)
3. [ArgoCD Architecture](#argocd-architecture)
4. [App Deployment Patterns](#app-deployment-patterns)
5. [Kustomize Components](#kustomize-components)
6. [Networking & Gateway Architecture](#networking--gateway-architecture)
7. [Secrets Management](#secrets-management)
8. [Storage & Backup Architecture](#storage--backup-architecture)
9. [Database Architecture](#database-architecture)
10. [Monitoring Stack](#monitoring-stack)
11. [CI/CD & Automation](#cicd--automation)
12. [Renovate Dependency Management](#renovate-dependency-management)
13. [Complete App Inventory](#complete-app-inventory)
14. [How-To: Common Operations](#how-to-common-operations)

---

## Repository Overview

| Property | Value |
|---|---|
| **Repository** | `sholdee/home-ops` (GitHub) |
| **Branch** | `master` (single branch, no develop/staging) |
| **Cluster** | K3s on 5x Raspberry Pi 5 (ARM64) with 512GB NVMe SSDs -- 3 control-plane (16GB RAM) + 2 workers (8GB RAM) |
| **GitOps Engine** | ArgoCD with GitHub webhook triggers |
| **Dependency Management** | Renovate (self-hosted via operator in-cluster) |
| **CI/CD** | GitHub Actions (helm diff, image verification) |
| **CNI** | Cilium (eBPF, native routing, BGP, Gateway API) |
| **Storage** | Longhorn (distributed block storage) |
| **Backup** | VolSync (Restic to Backblaze B2), Velero, CNPG barman-cloud |
| **Secrets** | 1Password Connect + External Secrets Operator |
| **Ingress** | Envoy Gateway + Cilium Gateway API (no traditional Ingress) |
| **DNS** | Gravity (CoreDNS-based) + External-DNS + AdGuard |
| **TLS** | cert-manager with Cloudflare DNS-01 |
| **Node IPs** | k3s-master-0/1/2: 192.168.99.10-12, k3s-worker-0/1: 192.168.99.20-21 |

---

## Directory Structure

```
home-ops/
├── apps/                          # All application definitions (ArgoCD watches apps/*)
│   ├── adguard/                   # Simple kustomize app (manifests only)
│   ├── argocd/                    # Self-managing ArgoCD + app-of-apps for Helm charts
│   ├── cert-manager/              # Helm chart via kustomize helmCharts
│   ├── cnpg-system/               # CNPG operator + barman-cloud plugin
│   ├── envoy-gateway-system/      # Envoy Gateway operator (Helm)
│   ├── external-dns/              # External-DNS (Helm + CRDs from URL)
│   ├── external-secrets/          # ESO + 1Password Connect (dual Helm charts)
│   ├── gateway/                   # Gateway API resources (Gateway, HTTPRoute, etc.)
│   ├── gravity/                   # CoreDNS-based DNS (plain manifests)
│   ├── hass/                      # Grouped app: HA + appdaemon + zwave + codeserver + db + mqtt
│   ├── headlamp/                  # Helm chart (Kubernetes dashboard)
│   ├── hivemq/                    # HiveMQ operator (Helm) + platform CR
│   ├── kube-system/               # Grouped: Cilium BGP config + kube-vip + external-snapshotter
│   ├── longhorn-system/           # Longhorn post-install resources (StorageClass, etc.)
│   ├── mealie/                    # Kustomize app with VolSync
│   ├── mongodb-operator/          # MongoDB Community Operator (Helm)
│   ├── monitoring/                # Grouped: kube-prometheus-stack (Helm) + Grafana/Prometheus/AlertManager/Kromgo resources
│   ├── portainer/                 # Kustomize app with VolSync
│   ├── renovate/                  # Renovate operator (OCI Helm chart)
│   ├── system-upgrade/            # K3s system-upgrade-controller + upgrade plans
│   ├── unifi/                     # Grouped: UniFi controller + MongoDB ReplicaSet + guest portal
│   └── velero/                    # Velero backup (Helm)
├── components/                    # Reusable Kustomize Components
│   ├── namespace/                 # Docker Hub pull secret + imagePullSecrets for default SA
│   └── volsync/                   # VolSync PVC template
│       └── b2/                    # Backblaze B2 backup: ExternalSecret + ReplicationSource + ReplicationDestination
├── docs/                          # Operational documentation
│   ├── cilium-setup-commands.md
│   ├── etcd-restore.md
│   ├── helm-commands.md
│   └── kube-prometheus-customization.md
└── .github/
    ├── renovate.json5             # Renovate configuration
    ├── workflows/
    │   ├── helm-diff.yml          # PR workflow: Helm manifest diff + image verification
    │   └── pull-image.yml         # PR workflow: Docker image pull verification (ARM64)
    └── scripts/
        ├── helm_diff.sh           # Helm diff script (processes ArgoCD Apps + Kustomize helmCharts)
        └── extract_image_info.py  # Extracts image info from PR diffs
```

---

## ArgoCD Architecture

### Self-Bootstrapping Design

ArgoCD is **self-managing**. The `argocd` app directory contains:

- The ArgoCD Helm chart itself (via kustomize `helmCharts`)
- The `ApplicationSet` that generates all other apps
- Helm `Application` CRs for infrastructure components (app-of-apps pattern)
- ArgoCD configuration (project, repos, webhook/security setup)

### The ApplicationSet: `k3s-apps`

**File:** `apps/argocd/manifests/app-set.yaml`

The single `ApplicationSet` named `k3s-apps` uses a **Git directory generator** scanning `apps/*` (one level deep). For each directory found, it creates an ArgoCD `Application`:

```
Generator: git directory → apps/*
  Each directory → one Application
    name: {{.path.basename}}
    namespace: {{ regexReplaceAll "-conf$" .path.basename "" }}
    path: {{.path.path}}
```

**Key behaviors:**

- **Namespace derivation:** The destination namespace equals the directory basename, with a `-conf` suffix stripped (e.g., `longhorn-system` stays `longhorn-system`; a hypothetical `foo-conf` would deploy to namespace `foo`)
- **Auto-sync with prune:** `syncPolicy.automated.prune: true` -- deleted resources are removed
- **Server-side apply:** All apps use `ServerSideApply=true`
- **Server-side diff:** Annotations set `ServerSideDiff=true` and `SkipDryRunOnMissingResource=true`
- **Create namespaces:** `CreateNamespace=true` for all generated apps
- **Respect ignore differences:** `RespectIgnoreDifferences=true`

**Template patches** (conditional per app):

- `monitoring`: Ignores Grafana secret data and StatefulSet checksum annotations

### The AppProject: `k3s`

**File:** `apps/argocd/manifests/app-project.yaml`

Single project `k3s` with:

- All cluster resources whitelisted (`*/*`)
- All namespace resources whitelisted (`*/*`)
- Destination: `in-cluster` with all namespaces (`*`)
- Source repos: only `https://github.com/sholdee/home-ops`

### App-of-Apps: Helm Applications in ArgoCD

**File:** `apps/argocd/manifests/apps.yaml`

This file contains ArgoCD `Application` CRs for Helm charts that don't need extra customization beyond Helm values. This is a legacy pattern carried over from earlier iterations of the repo -- it's simpler for standalone charts that don't benefit from kustomize's patching/overlay capabilities. These are embedded within the `argocd` Application directory, making ArgoCD an **app-of-apps**:

| Application | Chart | Repo | Namespace |
|---|---|---|---|
| **cilium** | `cilium` | `https://helm.cilium.io/` | `kube-system` |
| **longhorn** | `longhorn` | `https://charts.longhorn.io` | `longhorn-system` |
| **reloader** | `reloader` | `https://stakater.github.io/stakater-charts` | `default` |
| **volsync** | `volsync` | `https://backube.github.io/helm-charts/` | `volsync-system` |

**File:** `apps/argocd/manifests/cilium-preflight.yaml`

A separate `Application` for Cilium preflight checks (this validates version compatibility and pre-pulls critical CNI images):

- Same chart version as main Cilium
- `preflight.enabled: true`, `agent: false`, `operator.enabled: false`
- **Manual sync** (no `syncPolicy.automated`) -- this is intentional
- In its own file so Renovate creates a separate PR from the main Cilium chart

**Cilium upgrade workflow:**

1. Renovate opens two PRs simultaneously: one for `cilium-preflight.yaml`, one for `cilium` in `apps.yaml`
2. Merge the preflight PR first
3. Manually sync the cilium-preflight Application in ArgoCD, verify it succeeds
4. Delete the preflight Application (it's a one-shot validation)
5. Merge the main Cilium PR (auto-syncs)

### Repository Secrets

**File:** `apps/argocd/manifests/repos.yaml`

ArgoCD repo credentials for:

- `home-ops` (git)
- `longhorn` (helm)
- `cilium` (helm)
- `stakater` (helm/reloader)
- `backube` (helm/volsync)

### ArgoCD Helm Values

**File:** `apps/argocd/manifests/values.yaml`

Key configuration:

- `kustomize.buildOptions: --enable-helm` -- allows kustomize to render Helm charts
- `resource.exclusions`: CiliumIdentity resources excluded from tracking
- Anonymous read-only access enabled (`users.anonymous.enabled: "true"`, `policy.default: 'role:readonly'`)
- Controller has node affinity preferring non-control-plane nodes

### ArgoCD External Access

- Exposed via `external-gateway` (Envoy) at `argocd.sholdee.net`
- Protected by **Cloudflare Access JWT validation** via Envoy `SecurityPolicy`
- Two separate HTTPRoutes: one for UI (allows private CIDRs + Cloudflare JWT), one for webhooks (JWT-only POST)
- Uses a `BackendTLSPolicy` for upstream TLS to ArgoCD server
- TLS certificate sourced from External Secrets (`ClusterSecretStore: gateway` -> `external-wildcard`)
- CiliumNetworkPolicy restricts ingress to envoy-gateway-system pods only

---

## App Deployment Patterns

There are **5 distinct patterns** for deploying applications in this repo. Understanding these is critical for adding or modifying apps.

### Pattern 1: Plain Kustomize (Manifests Only)

**Examples:** `adguard`, `gravity`

Structure:

```
apps/<name>/
├── kustomization.yaml
└── manifests/
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── httproute.yaml
    ├── externalsecret.yaml (optional)
    └── ... other resources
```

The `kustomization.yaml` lists resources and includes the namespace component:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <name>
components:
  - ../../components/namespace
resources:
  - manifests/namespace.yaml
  - manifests/deployment.yaml
  - ...
```

### Pattern 2: Kustomize + Helm Charts (helmCharts in kustomization.yaml)

**Examples:** `cert-manager`, `external-secrets`, `cnpg-system`, `envoy-gateway-system`, `external-dns`, `hivemq`, `mongodb-operator`, `renovate`, `velero`, `headlamp`, `monitoring`

Structure:

```
apps/<name>/
├── kustomization.yaml      # Contains helmCharts: section
└── manifests/
    ├── values.yaml          # Helm values file (referenced by valuesFile)
    ├── namespace.yaml
    └── ... additional resources (CRDs, ExternalSecrets, etc.)
```

The `kustomization.yaml` uses kustomize's built-in Helm support:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <name>
components:
  - ../../components/namespace
resources:
  - manifests/namespace.yaml
  - manifests/externalsecret.yaml
helmCharts:
  - name: <chart-name>
    repo: <repo-url>           # HTTP(S) or OCI
    version: <version>
    releaseName: <release>
    namespace: <namespace>
    valuesFile: manifests/values.yaml   # or valuesInline: {}
```

**Important:** ArgoCD is configured with `kustomize.buildOptions: --enable-helm`, which allows kustomize to render Helm charts during sync.

Some apps use `valuesInline:` instead of `valuesFile:` for simpler configs (e.g., `mongodb-operator`, `hivemq`).

Some apps use OCI registries: `repo: oci://ghcr.io/mogenius/helm-charts` (renovate), `repo: oci://mirror.gcr.io/envoyproxy` (envoy-gateway).

**Multiple Helm charts** can be deployed from a single kustomization (e.g., `external-secrets` deploys both ESO and 1Password Connect).

### Pattern 3: ArgoCD Application CRs (App-of-Apps)

**Examples:** Cilium, Longhorn, Reloader, VolSync (in `apps/argocd/manifests/apps.yaml`)

These are raw ArgoCD `Application` resources defined within the `argocd` app directory. They use `spec.source.helm.valuesObject` for inline Helm values:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cilium
spec:
  destination:
    name: in-cluster
    namespace: kube-system
  project: k3s
  source:
    chart: cilium
    repoURL: https://helm.cilium.io/
    targetRevision: 1.19.1
    helm:
      valuesObject:
        # ... inline values
  syncPolicy:
    automated:
      prune: true
    syncOptions:
      - ServerSideApply=true
```

**When to use this pattern vs. Pattern 2:**

- Use Pattern 3 (ArgoCD Application CRs) for simple Helm deployments that don't need extra customization beyond Helm values. This is a legacy pattern that remains because it's straightforward for standalone charts.
- Use Pattern 2 (kustomize helmCharts) when you need fine-grained control: combining Helm output with additional manifests, patching or overriding any resource rendered by the chart via kustomize patches. This pattern provides an extremely high level of control over exactly what is deployed for a given Helm app.

### Pattern 4: Grouped Apps (Multi-Service Namespaces)

**Examples:** `hass`, `unifi`, `monitoring`, `kube-system`

For namespaces containing multiple services, a parent kustomization references sub-directories:

```
apps/<group>/
├── kustomization.yaml           # References sub-apps as resources
├── namespace.yaml (optional)    # Shared namespace
├── values.yaml (optional)       # Shared Helm values
├── sub-app-1/
│   ├── kustomization.yaml
│   └── manifests/
├── sub-app-2/
│   ├── kustomization.yaml
│   └── manifests/
└── sub-app-3/
    ├── kustomization.yaml
    └── manifests/
```

Parent `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <group>
components:
  - ../../components/namespace
resources:
  - sub-app-1
  - sub-app-2
  - sub-app-3
```

**Key examples:**

**`hass/`** (Home Assistant ecosystem):

- `hass/hass/` - Home Assistant deployment + VolSync backup
- `hass/appdaemon/` - AppDaemon automation + VolSync
- `hass/zwave/` - Z-Wave JS UI + VolSync
- `hass/codeserver/` - VS Code server + VolSync (mounts hass/appdaemon/zwave PVCs)
- `hass/hass-db/` - CloudNativePG PostgreSQL cluster (3 instances, barman-cloud backup)
- `hass/mqtt-venstar-bridge/` - MQTT-to-Venstar thermostat bridge

**`unifi/`**:

- `unifi/unifi/` - UniFi controller + backup cleaner sidecar + VolSync
- `unifi/unifi-db/` - MongoDB ReplicaSet (3 members, TLS enabled)
- `unifi/unifi-guest/` - Caddy-based guest portal landing page

**`monitoring/`**:

- Parent kustomization deploys `kube-prometheus-stack` Helm chart + patches
- `monitoring/alertmanager/` - HTTPRoute + ExternalSecret for config
- `monitoring/grafana/` - HTTPRoute + VolSync backup
- `monitoring/prometheus/` - HTTPRoute + PrometheusRule (custom alert rules)
- `monitoring/kromgo/` - Kromgo deployment (Kubernetes metrics as badge endpoints)

**`kube-system/`**:

- `kube-system/cilium/` - CiliumBGPClusterConfig + Hubble UI resources
- `kube-system/kube-vip/` - DaemonSet + RBAC for control plane VIP
- `kube-system/external-snapshotter/` - CSI snapshot controller + RBAC (from upstream URLs)

### Pattern 5: Kustomize with VolSync Components

**Examples:** `portainer`, `mealie`, `hass/hass`, `hass/appdaemon`, `hass/zwave`, `hass/codeserver`, `unifi/unifi`, `monitoring/grafana`

Apps that need persistent data with Backblaze B2 backup include VolSync components and apply kustomize patches to customize the generic templates:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - manifests/deployment.yaml
  - manifests/service.yaml
  - manifests/httproute.yaml
components:
  - ../../../components/volsync        # Provides PVC template
  - ../../../components/volsync/b2     # Provides ExternalSecret + ReplicationSource + ReplicationDestination
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

---

## Kustomize Components

### `components/namespace/`

Included by nearly every app via `components: [../../components/namespace]`. Provides:

1. **`externalsecret.yaml`**: Creates a `docker-hub` pull secret (from 1Password item `default`) containing `.dockerconfigjson`
2. **`serviceaccount.yaml`**: Patches the `default` ServiceAccount to include `imagePullSecrets: [{name: docker-hub}]`

This ensures every namespace has Docker Hub authentication to avoid rate limiting.

### `components/volsync/`

Provides a generic PVC template:

**`pvc.yaml`**: A `PersistentVolumeClaim` named `app-pvc` with:

- `ReadWriteOnce` access (overridable via patch)
- `5Gi` storage
- `storageClassName: longhorn`
- `dataSourceRef` pointing to `app-bootstrap` ReplicationDestination (for initial restore)

### `components/volsync/b2/`

Provides Backblaze B2 backup infrastructure:

1. **`externalsecret.yaml`**: Creates a secret named `app-volsync-b2` from 1Password item `cluster`, containing:
   - `RESTIC_REPOSITORY` (S3-compatible URL)
   - `RESTIC_PASSWORD`
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

2. **`replicationsource.yaml`**: `ReplicationSource` named `app` with:
   - `copyMethod: Clone`
   - `schedule: "0 6 * * *"` (daily at 6 AM UTC)
   - `retain: { daily: 14, hourly: 24 }`
   - `pruneIntervalDays: 7`
   - `storageClassName: longhorn`
   - `cacheStorageClassName: local-path`
   - `moverSecurityContext: { runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534 }`

3. **`replicationdestination.yaml`**: `ReplicationDestination` named `app-bootstrap` with:
   - `trigger: { manual: restore-once }` (only runs on manual trigger)
   - `copyMethod: Snapshot`
   - `storageClassName: longhorn-retain`
   - `volumeSnapshotClassName: longhorn`
   - `enableFileDeletion: false`

---

## Networking & Gateway Architecture

### Three Gateways

The cluster runs **three separate Kubernetes Gateways**, each with its own LoadBalancer IP (advertised via Cilium BGP):

| Gateway | IP | Domain | GatewayClass | Purpose |
|---|---|---|---|---|
| `external-gateway` | `192.168.77.31` | `*.sholdee.net` | `envoy` | Public-facing (via Cloudflare tunnel/proxy) |
| `envoy-gateway` | `192.168.77.32` | `*.mgmt.sholdee.net` | `envoy` | Internal management services |
| `guest-gateway` | `192.168.77.33` | `*.guest.sholdee.net` | `cilium` | Guest WiFi captive portal |

**Gateway definitions:** `apps/gateway/manifests/`

### GatewayClass: `envoy`

- Controller: `gateway.envoyproxy.io/gatewayclass-controller`
- Configured via `EnvoyProxy` resource with:
  - HPA: 2-5 replicas (CPU 60%, memory 80%)
  - PDB: `minAvailable: 1`
  - Topology spread constraints across nodes
  - Image: `mirror.gcr.io/envoyproxy/envoy`
  - `externalTrafficPolicy: Cluster` (Cilium DSR preserves source IP)
  - 180s drain timeout

### GatewayClass: `cilium`

- Controller: Cilium's built-in Gateway API support
- Used only for `guest-gateway`

### Envoy Gateway Configuration

Both `external-gateway` and `envoy-gateway` have:

- **ClientTrafficPolicy**: HTTP/2, HTTP/3, TLS 1.2+, TCP keepalive
- **BackendTrafficPolicy**: Buffer limits, TCP keepalive, compression (Zstd, Brotli, Gzip)
- **HTTP-to-HTTPS redirect**: Dedicated HTTPRoute on port 80

`external-gateway` additionally has:

- `clientIPDetection.customHeader.name: Cf-Connecting-Ip` (Cloudflare)

### envoy-gateway Listeners

The internal `envoy-gateway` has special listeners:

- `unifi-inform` (TCP port 8080): For UniFi device adoption
- `mqtt-proxy` (TLS port 8883): For HiveMQ MQTT over TLS

### Cert-Manager Integration

All three gateways have `cert-manager.io/cluster-issuer: cloudflare` annotations. cert-manager automatically provisions wildcard TLS certificates for each gateway's listeners.

### Security: Cloudflare Access

The `external-gateway` uses Envoy `SecurityPolicy` resources for JWT-based authentication:

- UI routes: Allow private CIDRs (10.6.0.0/24, 192.168.99.0/24) + Cloudflare Access JWT
- Webhook routes: Require Cloudflare Access JWT + POST method only

### CiliumNetworkPolicy

Several apps define `CiliumNetworkPolicy` resources to restrict ingress:

- `argocd`: Only from envoy-gateway-system (external-gateway) pods
- `unifi`: From envoy-gateway-system + unifi-landing pods
- `unifi-db`: Only from other MongoDB replicas + unifi controller
- `unifi-landing`: Only from ingress entity

### BGP Configuration

**File:** `apps/kube-system/cilium/manifests/CiliumBGPClusterConfig.yaml`

Cilium BGP control plane advertises LoadBalancer service IPs to the network. The config defines peering with the local router for service advertisement.

### Kube-VIP

**File:** `apps/kube-system/kube-vip/`

DaemonSet providing a virtual IP for the Kubernetes API server (high availability). Runs on control-plane nodes.

---

## Secrets Management

### Architecture

```
1Password Vault
    ↓ (1Password Connect API)
1Password Connect Server (deployed in external-secrets namespace)
    ↓ (ClusterSecretStore: onepassword-connect)
External Secrets Operator
    ↓ (ExternalSecret CRs)
Kubernetes Secrets
```

### Bootstrap Secret ("Secret Zero")

The entire secrets pipeline depends on a single manually applied secret that is **not managed by GitOps**:

```
Name:       op-credentials
Namespace:  external-secrets
Type:       Opaque
Data:
  1password-credentials.json  (1Password Connect server credentials)
  token                       (1Password Connect API token)
```

This must be applied before 1Password Connect can start. Without it, all ExternalSecret resources will fail to sync, cascading into failures across every app that depends on secrets. During a full cluster rebuild, this is the first secret to apply after the external-secrets namespace exists.

### ClusterSecretStores

1. **`onepassword-connect`**: Primary store for all application secrets. Uses 1Password Connect server deployed as a Helm chart alongside ESO.

2. **`gateway`**: A special store that sources TLS certificates. Used by apps needing wildcard certs:
   - `argocd` -> `external-wildcard`
   - `unifi` -> `mgmt-wildcard`

### ExternalSecret Patterns

**Standard pattern** (most apps):

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

**With Base64 decoding** (database credentials):

```yaml
  dataFrom:
    - extract:
        key: <1password-item-name>
        decodingStrategy: Base64
```

**TLS certificate pattern** (from gateway store):

```yaml
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: gateway
  target:
    template:
      type: kubernetes.io/tls
  data:
    - secretKey: tls.crt
      remoteRef:
        key: <cert-name>
        property: tls.crt
    - secretKey: tls.key
      remoteRef:
        key: <cert-name>
        property: tls.key
```

### 1Password Items Used

| 1Password Item | Used By | Fields |
|---|---|---|
| `default` | namespace component | `DOCKER_CONFIG_JSON` |
| `cluster` | volsync/b2 component | `VOLSYNC_RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| `appdaemon` | hass/appdaemon | `APPDAEMON_API_TOKEN` |
| `zwave` | hass/zwave | `ZWAVE_PASSWORD` |
| `hivemq` | hivemq, mqtt-venstar-bridge | `VENSTAR_PWD`, MQTT credentials |
| `hass-db` | hass-db | `HASS_DB_APP_USER/PASSWORD`, `HASS_DB_SUPER_USER/PASSWORD`, `HASS_DB_BACKUP_KEY_ID/SECRET`, `MEALIE_APP_USER/PASSWORD` |
| `unifi` | unifi-db | `MONGO_PASS` |
| `gravity` | gravity | DNS config secrets |
| `adguard` | adguard | AdGuard config |
| `alertmanager` | monitoring/alertmanager | Alertmanager configuration YAML |
| `renovate` | renovate | GitHub App credentials |

---

## Storage & Backup Architecture

### Longhorn

**Deployed via:** ArgoCD Application in `apps/argocd/manifests/apps.yaml`

Key settings:

- `defaultDataLocality: best-effort`
- `replicaAutoBalance: best-effort`
- `backupTarget: nfs://10.2.0.110:/volume1/longhorn` (NAS NFS backup)
- `nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod`

**Storage Classes** (defined in `apps/longhorn-system/manifests/storageclass.yaml`):

- `longhorn` (default) - Standard replicated storage
- `longhorn-retain` - Retain policy (used by VolSync restore)
- `longhorn-noreplicas` - No replication (used by CNPG, which has its own HA)
- `longhorn-mongo` - For MongoDB data/logs

**Volume Snapshot Class:** `longhorn` (used by VolSync snapshot-based restores)

### VolSync Backup Flow

```
Application PVC
    ↓ (Clone)
ReplicationSource (daily at 6 AM UTC)
    ↓ (Restic)
Backblaze B2 (s3:s3.us-west-002.backblazeb2.com/sholdee-volsync/<app>)
```

**Restore flow** (manual trigger):

```
Backblaze B2
    ↓ (Restic)
ReplicationDestination (manual trigger: restore-once)
    ↓ (Snapshot)
PVC (dataSourceRef → ReplicationDestination)
```

### Velero

Deployed via Helm chart in `apps/velero/`. Provides cluster-wide backup/restore capabilities separate from VolSync's per-PVC approach.

---

## Database Architecture

### CloudNativePG (PostgreSQL)

**Operator:** Deployed in `cnpg-system` namespace via Helm chart + barman-cloud plugin.

**Cluster:** `hass-db2` in `hass` namespace:

- 3 instances
- PostgreSQL 18 (from `ClusterImageCatalog`)
- Storage: `longhorn-noreplicas` (CNPG handles replication)
- Databases: `hass` (Home Assistant), `mealie` (recipe manager)
- Managed roles: `hass`, `mealie`
- Monitoring: PodMonitor enabled

**Connection pooling:** PgBouncer pooler (`hass-db-pooler-rw`):

- 3 instances with pod anti-affinity
- Transaction pool mode
- `max_client_conn: 1000`, `default_pool_size: 10`

**Backup:** barman-cloud to Backblaze B2:

- Bucket: `s3://sholdee-cnpg-hass/`
- WAL archiving with gzip + AES256
- Daily scheduled backup
- 30-day retention
- Bootstrap from barman-cloud recovery

### MongoDB (UniFi)

**Operator:** MongoDB Community Operator in `mongodb-operator` namespace, watching `unifi` namespace.

**ReplicaSet:** `unifi-db` in `unifi` namespace:

- 3 members
- MongoDB 8.0.x
- TLS enabled (cert-manager self-signed CA)
- SCRAM-SHA-1/256 authentication
- Topology spread constraints
- Storage: `longhorn-mongo` for data (5Gi) and logs (1Gi)
- CiliumNetworkPolicy for pod-to-pod restriction

---

## Monitoring Stack

### Kube-Prometheus-Stack

**Deployed via:** kustomize `helmCharts` in `apps/monitoring/kustomization.yaml`

**Components:**

- **Prometheus**: 50Gi persistent storage, 2Gi memory, node affinity
- **Alertmanager**: 3 replicas, 10Gi storage, config from ExternalSecret
- **Grafana**: Persistent StatefulSet (20Gi), VolSync backup to B2

**Disabled components:** kubeControllerManager, kubeScheduler, kubeProxy

**Kubelet monitoring** includes extensive metric relabelings to:

- Fix instance labels for k3s
- Keep only relevant metrics (drop unnecessary ones)
- Drop high-cardinality labels

**etcd monitoring:** Direct endpoints to 192.168.99.10-12

### Custom PrometheusRules

**File:** `apps/monitoring/prometheus/manifests/rules/`

Custom alert rules for:

- VolSync backup failures
- Longhorn volume health
- Application-specific alerts

### Kromgo

Lightweight service that exposes cluster metrics as badge endpoints (shields.io compatible) for the README:

- Kubernetes version, cluster age, uptime, node count, pod count, CPU/memory usage
- Accessible at `kromgo.sholdee.net:8443`

### Hubble (Cilium Observability)

- Hubble relay + UI enabled in Cilium config
- Exposed via `envoy-gateway` at `hubble.mgmt.sholdee.net`
- TLS certificate from External Secrets
- CiliumNetworkPolicy restricting access

---

## CI/CD & Automation

### GitHub Workflows

#### 1. Helm App Diff (`helm-diff.yml`)

**Trigger:** PRs modifying `**/kustomization.yaml`, `**/values*.yaml`, `apps/argocd/manifests/apps.yaml`, or `apps/argocd/manifests/cilium-preflight.yaml`

**What it does:**

1. Checks PR author against authorized list (`sholdee`, `pull-bunyan[bot]`)
2. Creates a base worktree from the target branch
3. Runs `helm_diff.sh` which:
   - Fetches PR changed files from GitHub API
   - For ArgoCD Application CRs: extracts old/new Helm chart versions and values, templates both, diffs
   - For kustomize helmCharts: runs `kustomize build --enable-helm` on old/new, diffs
   - Strips Secret resources and noisy labels from diff output
4. Posts diff as PR comment (truncated at 61KB with artifact link)
5. Uploads full diff as artifact (30-day retention)
6. **verify-new-images** job: Extracts new container images from the diff, pulls them on ARM64 runner, verifies `linux/arm64` platform support

#### 2. Verify Docker Image (`pull-image.yml`)

**Trigger:** PRs with title starting with `chore(deps)` containing `docker tag` or `docker digest` (Renovate image update PRs), **excluding** files already handled by helm-diff

**What it does:**

1. Checks authorized PR author
2. Extracts image/tag/digest from PR diff
3. Pulls image on ARM64 runner using `crictl`
4. Verifies `linux/arm64` platform
5. Posts result table as PR comment

Both workflows use a **GitHub App token** (`BOT_APP_ID` / `BOT_APP_PRIVATE_KEY`) for posting comments.

### GitHub Actions Runners

- `ubuntu-latest` for diff computation
- `ARM64` (self-hosted) for actual image pulling/verification

### ArgoCD Webhook

GitHub push events trigger a webhook to ArgoCD at `argocd.sholdee.net/api/webhook`, causing immediate sync. This is secured via Cloudflare Access JWT.

---

## Renovate Dependency Management

### Configuration

**File:** `.github/renovate.json5`

**Runtime:** Self-hosted Renovate operator deployed in-cluster (`apps/renovate/`)

### Key Settings

- Extends: `config:recommended`, `docker:enableMajor`, `:semanticCommits`
- Platform automerge enabled
- Kubernetes manager scans: `/apps/.*\.ya?ml$/`
- ArgoCD manager scans: `apps/argocd/manifests/apps.yaml`, `apps/argocd/manifests/cilium-preflight.yaml`

### Package Rules

**Separate PRs:**

- Cilium main and cilium-preflight get separate PRs/branches

**Version constraints:**

- MongoDB Community Server: `< 8.1`
- Portainer EE: `< 2.40`
- PostgreSQL: `< 19`
- Renovate: scheduled `before 6am`

**Automerge (minor/patch/digest):**

- renovate, cert-manager, kube-prometheus-stack, kubernetes-dashboard, reloader, velero, postgresql, code-server, CSI components, kromgo, kubectl, portainer, caddy, adguard-exporter, system-upgrade-controller, k8s-sidecar, mealie, headlamp, external-secrets, busybox, velero-plugin-for-aws
- GitHub Actions: minor/patch/digest

### Custom Managers (Regex)

| Target | File | What It Tracks |
|---|---|---|
| K3s version | `apps/system-upgrade/manifests/plan.yaml` | `version: v1.x.x+k3s1` |
| kubectl image in SUC | `apps/system-upgrade/manifests/controller.yaml` | `SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE` |
| MongoDB version | `apps/unifi/unifi-db/manifests/replicaset.yaml` | `version: "x.x.x"` |
| barman-cloud plugin | `apps/cnpg-system/kustomization.yaml` | GitHub release URL |
| Gateway API CRDs | `apps/gateway/kustomization.yaml` | GitHub release URL |
| external-snapshotter | `apps/kube-system/external-snapshotter/kustomization.yaml` | GitHub release URL |
| external-dns CRDs | `apps/external-dns/kustomization.yaml` | GitHub release URL |
| system-upgrade-controller | `apps/system-upgrade/kustomization.yaml` | GitHub release URL |
| HiveMQ RBAC extension | `apps/hivemq/manifests/platform.yaml` | Version in ZIP URL |

### Custom Datasource: K3s

Fetches the latest stable K3s version from `https://update.k3s.io/v1-release/channels`.

---

## Complete App Inventory

### Infrastructure (Critical Path)

| App | Type | Namespace | Helm? | VolSync? |
|---|---|---|---|---|
| argocd | App-of-apps + Helm | argocd | Yes (argo-cd) | No |
| cilium | ArgoCD Application | kube-system | Yes (cilium) | No |
| cilium-preflight | ArgoCD Application | kube-system | Yes (cilium) | No |
| longhorn | ArgoCD Application | longhorn-system | Yes (longhorn) | No |
| volsync | ArgoCD Application | volsync-system | Yes (volsync) | No |
| reloader | ArgoCD Application | default | Yes (reloader) | No |
| cert-manager | Kustomize+Helm | cert-manager | Yes | No |
| envoy-gateway-system | Kustomize+Helm | envoy-gateway-system | Yes | No |
| external-secrets | Kustomize+Helm (x2) | external-secrets | Yes (ESO + 1Password) | No |
| gateway | Kustomize | gateway | No | No |
| kube-system | Grouped | kube-system | No | No |
| longhorn-system | Kustomize | longhorn-system | No | No |

### Applications

| App | Type | Namespace | Helm? | VolSync? | Database |
|---|---|---|---|---|---|
| hass | Grouped (6 sub-apps) | hass | No | Yes (4 apps) | CNPG PostgreSQL |
| unifi | Grouped (3 sub-apps) | unifi | No | Yes (unifi) | MongoDB ReplicaSet |
| monitoring | Grouped+Helm | monitoring | Yes (kube-prom-stack) | Yes (grafana) | No |
| adguard | Kustomize | adguard | No | No | No |
| gravity | Kustomize | gravity | No | No | etcd cluster |
| mealie | Kustomize+VolSync | mealie | No | Yes | Uses hass-db PostgreSQL |
| portainer | Kustomize+VolSync | portainer | No | Yes | No |
| headlamp | Kustomize+Helm | headlamp | Yes | No | No |
| hivemq | Kustomize+Helm | hivemq | Yes (operator) | No | No |
| renovate | Kustomize+Helm | renovate | Yes (OCI) | No | No |
| velero | Kustomize+Helm | velero | Yes | No | No |
| external-dns | Kustomize+Helm | external-dns | Yes | No | No |
| cnpg-system | Kustomize+Helm | cnpg-system | Yes | No | No |
| mongodb-operator | Kustomize+Helm | mongodb-operator | Yes | No | No |
| system-upgrade | Kustomize | system-upgrade | No | No | No |

---

## How-To: Common Operations

### Adding a New Simple App (Kustomize Only)

1. Create `apps/<name>/kustomization.yaml`:

```yaml
---
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

1. Create `apps/<name>/manifests/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <name>
```

1. Create deployment, service, and HTTPRoute manifests in `manifests/`

2. The ApplicationSet automatically picks up the new `apps/<name>/` directory

**Conventions:**

- All deployments use `securityContext` with `runAsNonRoot: true`, `runAsUser/Group: 65534`, `fsGroup: 65534`, `seccompProfile: RuntimeDefault`
- All containers use `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`
- All deployments specify resource requests and limits
- Use `emptyDir: {}` for tmp/cache volumes
- Use `reloader.stakater.com/auto: "true"` annotation when deployment depends on secrets/configmaps

### Adding a New Helm App

1. Create `apps/<name>/kustomization.yaml`:

```yaml
---
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
    valuesFile: manifests/values.yaml  # or valuesInline: {}
```

1. Create `manifests/values.yaml` with Helm values
2. Create `manifests/namespace.yaml`

### Adding VolSync Backup to an App

1. Add components and patches to the app's `kustomization.yaml`:

```yaml
components:
  - ../../components/volsync      # or ../../../components/volsync for nested apps
  - ../../components/volsync/b2
patches:
  # Copy the standard VolSync patches from Pattern 5 above
  # Replace all occurrences of <app-name> with the actual app name
```

1. Ensure the deployment references `<app-name>-pvc` as its PVC

2. Create the B2 bucket path (or it will be auto-created by Restic)

### Adding Secrets via External Secrets

1. Create the item in 1Password
2. Create `manifests/externalsecret.yaml`:

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

1. Reference the secret in the deployment via `secretKeyRef`

### Exposing an App via HTTPRoute

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

### Adding a New App to a Grouped Namespace

1. Create `apps/<group>/<sub-app>/kustomization.yaml` and `manifests/`
2. Add the sub-app as a resource in the parent `apps/<group>/kustomization.yaml`:

```yaml
resources:
  - existing-sub-app
  - <new-sub-app>    # Add this line
```

### Updating a Helm Chart Version

For kustomize helmCharts: Edit the `version:` field in the relevant `kustomization.yaml`.

For ArgoCD Application CRs: Edit `targetRevision:` in `apps/argocd/manifests/apps.yaml` or `cilium-preflight.yaml`.

Renovate handles this automatically for most charts.

### Adding Network Policies

Use `CiliumNetworkPolicy` (not standard NetworkPolicy):

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

### YAML Schema Annotations

All YAML files use `yaml-language-server` schema comments for IDE validation:

```yaml
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/...
# yaml-language-server: $schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/...
```

### Conventions Checklist

- [ ] Namespace component included (`../../components/namespace`)
- [ ] Explicit namespace.yaml resource
- [ ] Security context on all pods (non-root, read-only FS, drop all caps)
- [ ] Resource requests and limits on all containers
- [ ] Reloader annotation if deployment uses secrets/configmaps
- [ ] HTTPRoute for web-accessible services
- [ ] ExternalSecret for any credentials (never hardcode)
- [ ] yaml-language-server schema comment on all YAML files
- [ ] CiliumNetworkPolicy for services exposed via gateway (when security matters)
- [ ] topologySpreadConstraints for spreading replicas across nodes
