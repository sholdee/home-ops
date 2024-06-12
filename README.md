# K3s Home Ops

## Introduction

This repository contains the configurations for my home operations k3s cluster.

My applications are managed in GitOps fashion with ArgoCD, Renovate, and Github webhooks.

Cluster bootstrapping is performed with Techno-Tim's [k3s-ansible](https://github.com/techno-tim/k3s-ansible) repository, for which I contributed [Cilium CNI support](https://github.com/techno-tim/k3s-ansible/pull/435).

## Background

I was running various self-hosted services in Docker and decided to learn Kubernetes and migrate my services to it in December 2023. Everything here has been built up from scratch since that time.

## Cluster Overview

- **Cluster Type**: Home Operations
    - HA with embedded etcd
- **Kubernetes Distribution**: K3s
- **Hardware**: RPi 5 8gb with 512GB NVMe SSD via PCIe hat x4
- **Primary Applications**:
  - Home Assistant and related services
  - Unifi
  - Wireguard
  - Adguard
  - Gravity
- **Storage**: Longhorn
- **Network**: Cilium
- **Control LB**: Kube-VIP
