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

### Overview 📔

This repository contains the configurations for my home operations k3s cluster.

My applications are managed in GitOps fashion with ArgoCD, Renovate, and Github webhooks. Push events trigger ArgoCD to sync the cluster state with this repository.

Renovate automatically scans the repository and submits pull requests for dependency updates. This includes upgrades to K3s itself via [system-upgrade-controller](https://github.com/rancher/system-upgrade-controller).

Image update pull requests trigger a workflow to pull the new image to the cluster for verification. This has the added benefit of caching images in the local embedded registry mirror, Spegel, prior to merging.

#### Primary Applications ⭐
  - Home Assistant and related services
    - Appdaemon
      - Custom [automations](https://github.com/sholdee/sholdee-hass-apps) 
    - Z-Wave JS UI
    - EMQX Cluster
    - Codeserver
    - Venstar MQTT bridge
  - Unifi
  - Wireguard
  - Adguard
    - Custom [exporter sidecar](https://github.com/sholdee/adguard-exporter)
  - Gravity cluster
  - Renovate
  - Portainer
    - GitOps for remote Docker hosts
#### Core Components 🔥
  - ArgoCD
  - 1Password Connect
  - External Secrets
  - Cert-Manager
  - Kube-VIP
  - CloudNativePG
  - EMQX Operator
  - ETCD Operator
  - MongoDB Community Operator
  - Kube Prometheus Stack
  - Kromgo
  - System Upgrade Controller
  - Ingress-NGINX
  - Kubernetes Dashboard
  - Stakater Reloader
  - Velero
#### Network: Cilium 🕸️
  - Gateway API
  - Netkit
  - eBPF host-routing
  - Native routing
  - BGP control plane
  - Hubble observability
#### Storage: Longhorn 💾
#### Hardware 🖥️
  - RPi 5 8gb with 512GB NVMe SSD via PCIe hat
