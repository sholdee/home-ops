<div align="center" style="display: flex; align-items: center; justify-content: center;">
  <img src="docs/assets/kubernetes.svg" alt="ArgoCD Icon" width="50" height="50" style="margin-right: 10px;"/>
  
  <h1 style="margin: 0 10px;">K3s Home Operations</h1>
  
  <img src="docs/assets/kubernetes.svg" alt="Kubernetes Icon" width="50" height="50" style="margin-left: 10px;"/>
</div>
<div align="center">
  <em>... managed with ArgoCD and Renovate</em>
</div>

<div align="center" style="margin-top: 20px;">

[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A2096%2Fquery%3Fformat%3Dendpoint%26metric%3Dkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=%20)](https://k3s.io/)&nbsp;&nbsp;

</div>

<div align="center">

[![Home-Internet](https://img.shields.io/endpoint?url=https%3A%2F%2Fhealthchecks.io%2Fbadge%2F51183e61-d334-4de9-acb4-abfdf9%2F4nYMJsdM-2%2Fhome-internet.shields&color=brightgreen&label=Home%20Internet&style=for-the-badge&logo=ubiquiti&logoColor=white)](https://healthchecks.io)&nbsp;&nbsp;
[![Alertmanager](https://img.shields.io/endpoint?url=https%3A%2F%2Fhealthchecks.io%2Fbadge%2F51183e61-d334-4de9-acb4-abfdf9%2F6loCWl61-2%2Falert-manager.shields&label=alert%20manager&style=for-the-badge&logo=prometheus&logoColor=white)](https://healthchecks.io)&nbsp;&nbsp;

</div>

<div align="center">

[![Age-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A2096%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_age_days&style=flat-square&label=Age)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Uptime-Days](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A2096%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_uptime_days&style=flat-square&label=Uptime)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Node-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A2096%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_node_count&style=flat-square&label=Nodes)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Pod-Count](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A2096%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_pod_count&style=flat-square&label=Pods)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![CPU-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A2096%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_cpu_usage&style=flat-square&label=CPU)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;
[![Memory-Usage](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.sholdee.net%3A2096%2Fquery%3Fformat%3Dendpoint%26metric%3Dcluster_memory_usage&style=flat-square&label=Memory)](https://github.com/kashalls/kromgo/)&nbsp;&nbsp;

</div>

### Introduction

This repository contains the configurations for my home operations k3s cluster.

My applications are managed in GitOps fashion with ArgoCD, Renovate, and Github webhooks. Push events trigger ArgoCD to sync the cluster state with this repository. Renovate automatically scans and submits pull requests for dependency updates. This also includes upgrades to K3s itself via [system-upgrade-controller](https://github.com/rancher/system-upgrade-controller).

Cluster bootstrapping is performed with Techno-Tim's [k3s-ansible](https://github.com/techno-tim/k3s-ansible) repository, for which I contributed [Cilium CNI support](https://github.com/techno-tim/k3s-ansible/pull/435).

### Background

I was running various self-hosted services in Docker and decided to learn Kubernetes and migrate my services to it in December 2023. Everything here has been built up from scratch since that time.

### Cluster Overview

- **Cluster Type**: Home Operations
    - HA with embedded etcd
- **Kubernetes Distribution**: K3s
- **Hardware**: RPi 5 8gb with 512GB NVMe SSD via PCIe hat
- **Primary Applications**:
  - Home Assistant and related services
    - Appdaemon
    - Z-Wave JS UI
    - Mosquitto MQTT
    - Codeserver
  - Unifi
  - Wireguard
  - Adguard
  - Gravity cluster
  - Homepage
- **Storage**: Longhorn
- **Network**: Cilium
- **Control LB**: Kube-VIP
- **Service LB**: Cilium BGP