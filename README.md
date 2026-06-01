<div align="center">

# K3s Home Operations

...managed with<br />
🤖 ArgoCD, Ansible, Renovate, and GitHub Actions 🤖

</div>

<div align="center">

[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=)](https://k3s.io/)&nbsp;&nbsp;

</div>

<div align="center">

[![Home-Internet](https://img.shields.io/endpoint?url=https%3A%2F%2Fhealthchecks.io%2Fbadge%2F51183e61-d334-4de9-acb4-abfdf9%2F4nYMJsdM-2%2Fhome-internet.shields&label=Home%20Internet&style=for-the-badge&logo=mikrotik&logoColor=white)](https://healthchecks.io)&nbsp;&nbsp;
[![Alertmanager](https://img.shields.io/endpoint?url=https%3A%2F%2Fhealthchecks.io%2Fbadge%2F51183e61-d334-4de9-acb4-abfdf9%2F6loCWl61-2%2Falert-manager.shields&label=alert%20manager&style=for-the-badge&logo=prometheus&logoColor=white)](https://healthchecks.io)&nbsp;&nbsp;

</div>

<div align="center">

[![Age-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_age_days&style=flat-square&label=Age)](https://github.com/home-operations/kromgo/)&nbsp;&nbsp;
[![Uptime-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_uptime_days&style=flat-square&label=Uptime)](https://github.com/home-operations/kromgo/)&nbsp;&nbsp;
[![Node-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_node_count&style=flat-square&label=Nodes)](https://github.com/home-operations/kromgo/)&nbsp;&nbsp;
[![Pod-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_pod_count&style=flat-square&label=Pods)](https://github.com/home-operations/kromgo/)&nbsp;&nbsp;
[![CPU-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_cpu_usage&style=flat-square&label=CPU)](https://github.com/home-operations/kromgo/)&nbsp;&nbsp;
[![Memory-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_memory_usage&style=flat-square&label=Memory)](https://github.com/home-operations/kromgo/)&nbsp;&nbsp;

</div>

## Overview 📔

This repository defines my Raspberry Pi K3s self-hosting platform, including
bootable node images, Ansible host convergence, and ArgoCD-managed Kubernetes
applications.

My applications are managed in GitOps fashion with ArgoCD, Renovate, and GitHub webhooks. Repository push events trigger a webhook to ArgoCD, causing it to immediately sync the cluster state with this repository.

Renovate continuously scans the repository and submits pull requests for dependency updates, including K3s version upgrades delivered by [system-upgrade-controller](https://github.com/rancher/system-upgrade-controller). A scheduled OS update workflow also opens opt-in `system-upgrade-controller` plan PRs for node package upgrades.

A unified CI pipeline runs on all pull requests, conditionally triggering the appropriate checks:

- **Drydock GitOps validation** — uses [drydock](https://github.com/sholdee/drydock) to render and test ArgoCD Applications, produce desired-state diffs, and identify newly rendered container images
- **ARM64 image verification** — pulls drydock-detected new images on a self-hosted ARM64 runner and verifies `linux/arm64` platform support
- **Pre-commit** — validates YAML syntax, Kubernetes schemas, workflow syntax, shell scripts, Markdown, Renovate config, and code quality
- **Bootstrap tests** — shellchecks and exercises the offline bootstrap, Ansible, Lima, and node lifecycle test suite

All checks feed into a single required status gate for branch protection and automerge.

### Repository Structure 📂

```text
📁 apps/              # Application definitions -- one ArgoCD Application per directory
├── 📁 argocd/        # Self-managing ArgoCD + ApplicationSet + app-of-apps Helm charts
├── 📁 hass/          # Grouped: Home Assistant, Appdaemon, Z-Wave, Codeserver, CNPG, MQTT bridge
├── 📁 unifi/         # Grouped: UniFi controller, MongoDB ReplicaSet, guest portal proxy
├── 📁 monitoring/    # Grouped: kube-prometheus-stack, Grafana Operator, Prometheus, Alertmanager, Kromgo
├── 📁 kube-system/   # Grouped: Cilium BGP config, kube-vip
└── 📁 .../           # Each remaining directory is a standalone app (Helm or plain manifests)
📁 components/        # Reusable Kustomize Components (namespace pull secrets, Dragonfly, VolSync backups)
📁 docs/              # Operational documentation
📁 hack/bootstrap/    # Bootstrap, node lifecycle, and Raspberry Pi reimage tooling
📁 .github/           # CI workflows, composite actions, and Renovate config
```

### Cluster Bootstrap & Lifecycle 🚀

This repository also owns the operational platform for building, testing, and
maintaining the physical cluster. The framework under `hack/bootstrap/` combines
small Bash phase runners, an in-repo Ansible backend, `just` recipes, and
kind/Lima harnesses so cluster lifecycle work can be rehearsed and repeated
from source control.

It can prepare fresh Debian-family Raspberry Pi nodes, install K3s, seed the
minimum secrets, bootstrap the dependencies needed for ArgoCD takeover, and
then let ArgoCD reconcile the steady-state application graph. The same tooling
also validates bootstrap ordering in disposable kind and Lima clusters,
including a lightweight Longhorn lifecycle profile and a fuller app profile
for VolSync, CNPG restores, and external-writer safety.

For existing clusters, the node lifecycle commands cover status, drain, safe
reboot, Longhorn replica eviction, Kubernetes node deletion, embedded-etcd
member cleanup, inventory-based joins, temporary scheduling taints, and
uncordon/finalization. Raspberry Pi nodes can also be replaced in place by
building a per-node OS image, serving it from another cluster node, staging a
one-shot initramfs reimage payload, rebooting into the network reimage, and
joining the rebuilt node back into K3s.

Bootstrap stays narrower than steady-state GitOps: it prepares only the
dependencies required for ArgoCD takeover, then normal workloads return to
ArgoCD. See [hack/bootstrap/README.md](hack/bootstrap/README.md) for the
framework overview and [docs/cluster-operations.md](docs/cluster-operations.md)
for the operator runbook. Local operator tooling is pinned with
[`mise`](https://mise.jdx.dev/); on a fresh workstation install `mise`, run
`mise install --locked --yes`, then use `mise exec -- just ...` until your
shell has mise activated.

### ArgoCD Project Structure 🏗️

An `ApplicationSet` with a Git directory generator watches `apps/*` and dynamically creates an ArgoCD `Application` for each directory. Generated applications auto-sync with pruning and use server-side apply/diff by default. The `argocd` application is special — it manages itself and also serves as an app-of-apps that aggregates Helm-based applications (Cilium, Longhorn, etc.).

```mermaid
erDiagram
    ApplicationSet {
      string name "k3s-apps"
      boolean goTemplate "true"
      string kind "ApplicationSet"
    }
    "Git Generator" {
      string repoURL "https:&sol;&sol;github&period;com/sholdee/home-ops"
      string path "apps/*"
    }
    Directory
    Application {
      string name ".path.basename"
      string destinationNamespace ".path.basename (minus '-conf' suffix if present)"
      string path ".path.path"
      string kind "Application"
    }
    argocd {
      string name "argocd"
      string destinationNamespace "argocd"
      string path "apps/argocd"
      string kind "Application"
    }
    "Helm Applications"
    Cilium
    Longhorn
    VolSync

    ApplicationSet ||--|| "Git Generator" : "uses"
    "Git Generator" ||--|{ Directory : "scans each"
    Directory ||--|| Application : "generates"
    argocd ||..|| Application : "is a type of"
    argocd ||--|{ "Helm Applications" : "app-of-apps aggregates"
    "Helm Applications" ||--|| Cilium : "example"
    "Helm Applications" ||--|| Longhorn : "example"
    "Helm Applications" ||--|| VolSync : "example"
    argocd ||--|| ApplicationSet : "self-manages"
```

### Primary Applications ⭐

- **Home Assistant** — home automation platform
  - **Appdaemon** — custom python [automations](https://github.com/sholdee/sholdee-hass-apps)
  - **Z-Wave JS UI** — Z-Wave Control Panel and MQTT Gateway
  - **Codeserver** — VS Code in the browser
  - **Venstar MQTT bridge** — thermostat integration
- **HiveMQ** — MQTT broker
- **Mealie** — recipe manager
- **Unifi** — wireless network controller
- **Adguard** — DNS-based ad blocking with custom [exporter sidecar](https://github.com/sholdee/adguard-exporter)
- **PowerDNS** — authoritative DNS server
  - **dnsdist** — DNS load balancer and router
  - **Poweradmin** — web management UI
  - Backed by CNPG PostgreSQL with pgbouncer
- **Renovate Operator** — automated dependency update PRs
- **Portainer** — GitOps for remote Docker hosts

### Core Components 🔥

#### GitOps & Configuration

- **ArgoCD** — GitOps continuous delivery
- **Stakater Reloader** — rolling restarts on Secret/ConfigMap changes
- **System Upgrade Controller** — automated K3s and OS package upgrades
- **[CRD Schema Publisher](https://github.com/sholdee/crd-schema-publisher)** — watches for CRD changes and publishes JSON schemas to Cloudflare Pages

#### Secrets & Certificates

- **1Password Connect** — secrets backend for External-Secrets
- **External-Secrets** — syncs secrets from 1Password into Kubernetes
- **Cert-Manager** — automated TLS certificate management

#### Networking

- **Cilium** — CNI with Gateway API, Netkit, eBPF host-routing, BGP control plane, and Hubble observability
- **Envoy Gateway** — Gateway API implementation for ingress routing
- **External-DNS** — automated DNS record management
- **Kube-VIP** — virtual IP for the Kubernetes control plane

#### Storage & Backup

- **Longhorn** — distributed block storage with recurring backups to NAS
- **Barman-cloud** — PostgreSQL backups and WAL streaming to Backblaze B2
- **VolSync** — PVC replication with Restic to Backblaze B2
- **Velero** — cluster-wide backup and disaster recovery

#### Monitoring & Observability

- **Kube Prometheus Stack** — Prometheus, Alertmanager, rules, ServiceMonitors, and dashboard ConfigMaps
- **Grafana** — operator-managed dashboard UI using GrafanaDashboard CRs
- **Kromgo** — exposes cluster metrics as badge endpoints
- **Headlamp** — Kubernetes web dashboard

#### Operators

- **CloudNativePG** — PostgreSQL operator with automated failover and backups
- **Dragonfly Operator** — manages Redis-compatible HA cache instances
- **Grafana Operator** — manages Grafana instances, datasources, and dashboard imports
- **HiveMQ Platform Operator** — manages HiveMQ MQTT broker
- **MongoDB Controllers for Kubernetes** — manages MongoDB ReplicaSets

### Hardware 🖥️

| Node | Role | RAM | Storage |
| --- | --- | --- | --- |
| k3s-master-0 | Control plane | 16GB | 512GB NVMe SSD |
| k3s-master-1 | Control plane | 16GB | 512GB NVMe SSD |
| k3s-master-2 | Control plane | 16GB | 512GB NVMe SSD |
| k3s-worker-0 | Worker | 8GB | 512GB NVMe SSD |
| k3s-worker-1 | Worker | 8GB | 512GB NVMe SSD |

All nodes are Raspberry Pi 5 boards with NVMe SSDs attached via PCIe HAT.
