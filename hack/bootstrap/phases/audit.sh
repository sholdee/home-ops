#!/usr/bin/env bash

log "Helm releases"
helm_cluster_cmd list -A || true

log "Helm release Secrets"
kubectl_cmd get secret -A -l owner=helm -o name || true

log "Helm release ConfigMaps"
kubectl_cmd get configmap -A -l owner=helm -o name || true

log "ArgoCD apps"
kubectl_cmd get app -n argocd || true

log "Core deployments"
kubectl_cmd get deploy -n argocd || true
kubectl_cmd get deploy -n external-secrets || true
kubectl_cmd get deploy -n cert-manager || true
kubectl_cmd get deploy -n dragonfly-operator || true
