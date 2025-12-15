<div align="center">

# K3s Home Operations

...managed with<br />
🤖 ArgoCD, Renovate, and GitHub Actions 🤖

</div>

<div align="center">

[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=)](https://k3s.io/)&nbsp;&nbsp;

</div>

<div align="center">

[![Home-Internet](https://img.shields.io/endpoint?url=https%3A%2F%2Fhealthchecks.io%2Fbadge%2F51183e61-d334-4de9-acb4-abfdf9%2F4nYMJsdM-2%2Fhome-internet.shields&label=Home%20Internet&style=for-the-badge&logo=mikrotik&logoColor=white)](https://healthchecks.io)&nbsp;&nbsp;
[![Alertmanager](https://img.shields.io/endpoint?url=https%3A%2F%2Fhealthchecks.io%2Fbadge%2F51183e61-d334-4de9-acb4-abfdf9%2F6loCWl61-2%2Falert-manager.shields&label=alert%20manager&style=for-the-badge&logo=prometheus&logoColor=white)](https://healthchecks.io)&nbsp;&nbsp;

</div>

<div align="center">

[![Age-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_age_days&style=flat-square&label=Age)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Uptime-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_uptime_days&style=flat-square&label=Uptime)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Node-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_node_count&style=flat-square&label=Nodes)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Pod-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_pod_count&style=flat-square&label=Pods)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![CPU-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_cpu_usage&style=flat-square&label=CPU)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Memory-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A8443%2Fcluster_memory_usage&style=flat-square&label=Memory)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;

</div>

## Overview 📔

This repository contains the configurations for my home operations k3s cluster.

My applications are managed in GitOps fashion with ArgoCD, Renovate, and Github webhooks. Repository push events trigger a webhook to ArgoCD, causing it to immediately sync the cluster state with this repository.

Renovate continuously scans the repository and submits pull requests for dependency updates. This includes upgrades to K3s itself via [system-upgrade-controller](https://github.com/rancher/system-upgrade-controller).

Pull requests for Helm application updates trigger a workflow to calculate and post the diff between the old and new versions' inflated manifests, as well as detect and pull all new container images to the cluster for verification.

Container image update pull requests against base manifests in the repository also trigger a workflow to pull the new image. This has the added benefit of caching all images in the local embedded registry mirror, Spegel, prior to merging.

### ArgoCD Project Structure 🏗️

The project utilizes ArgoCD's `ApplicationSet` custom resource with a Git directory generator, watching `apps/*`, to dynamically create all ArgoCD `Application` instances. It is self-managing and contained within the special `argocd` application, which is also an app-of-apps holding Helm applications.

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
    ArgoCD
    Cert-Manager

    ApplicationSet ||--|| "Git Generator" : "uses"
    "Git Generator" ||--|{ Directory : "scans each"
    Directory ||--|| Application : "generates"
    argocd ||..|| Application : "is a type of"
    argocd ||--|{ "Helm Applications" : "app-of-apps aggregates"
    "Helm Applications" ||--|| Cilium : "example"
    "Helm Applications" ||--|| ArgoCD : "example"
    "Helm Applications" ||--|| Cert-Manager : "example"
    argocd ||--|| ApplicationSet : "self-manages"
```

### Primary Applications ⭐

- Home Assistant and related services
  - Appdaemon
    - Custom [automations](https://github.com/sholdee/sholdee-hass-apps)
  - Z-Wave JS UI
  - HiveMQ
  - Codeserver
  - Venstar MQTT bridge
- Unifi
- Adguard
  - Custom [exporter sidecar](https://github.com/sholdee/adguard-exporter)
- Gravity DNS cluster
  - External-DNS webhook
  - etcd
- Renovate
- Portainer
  - GitOps for remote Docker hosts

### Core Components 🔥

- ArgoCD
- 1Password Connect
- External-Secrets
- External-DNS
- Envoy Gateway
- Cert-Manager
- Kube-VIP
- VolSync
- CloudNativePG
- MongoDB Controllers for Kubernetes
- Kube Prometheus Stack
- Kromgo
- System Upgrade Controller
- Kubernetes Dashboard
- Stakater Reloader
- Velero

### Network: Cilium 🕸️

- Gateway API
- Netkit
- eBPF host-routing
- Native routing
- BGP control plane
- Hubble observability

### Storage: Longhorn 💾

### Hardware 🖥️

- RPi 5 with 512GB NVMe SSD via PCIe hat
