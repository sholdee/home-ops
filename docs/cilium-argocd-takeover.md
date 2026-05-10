# Cilium ArgoCD Takeover

## References

- ArgoCD renders Helm charts with `helm template`; ArgoCD, not Helm, owns application lifecycle afterward:
  <https://argo-cd.readthedocs.io/en/latest/user-guide/helm/>
- Helm uninstall removes release resources and release history unless history is explicitly kept:
  <https://docs.helm.sh/docs/helm/helm_uninstall/>
- Helm chart metadata commonly includes Helm-oriented labels and annotations:
  <https://helm.sh/docs/chart_best_practices/labels/>

## Problem

Cilium must be installed before ArgoCD so the cluster has networking. After ArgoCD syncs the
`cilium` Application, Helm release state from bootstrap can remain in `kube-system` even though
ArgoCD is now reconciling the rendered resources.

The dangerous cleanup is `helm uninstall cilium -n kube-system`. Helm may delete the CNI resources
that ArgoCD has adopted.

## Detect

```sh
kubectl get app -n argocd cilium kube-system
helm list -n kube-system
kubectl get secret -n kube-system -l owner=helm,name=cilium
```

If ArgoCD is `Synced` and `Healthy`, and Helm still lists `cilium`, the remaining Helm release
Secrets are stale lifecycle state. With Helm's default Secret storage driver, they are the
authoritative orphaned Helm installation state.

Optional metadata inventory for common Cilium chart resources:

```sh
kubectl get all,cm,secret,sa,role,rolebinding -n kube-system -o json \
  | jq -r '.items[]
    | select(.metadata.annotations["meta.helm.sh/release-name"] == "cilium")
    | [.kind, .metadata.name, .metadata.annotations["argocd.argoproj.io/tracking-id"] // ""]
    | @tsv'

kubectl get clusterrole,clusterrolebinding -o json \
  | jq -r '.items[]
    | select(.metadata.annotations["meta.helm.sh/release-name"] == "cilium")
    | [.kind, .metadata.name, .metadata.annotations["argocd.argoproj.io/tracking-id"] // ""]
    | @tsv'
```

## Cleanup Plan

1. Install Cilium with Helm during bootstrap.
2. Install ArgoCD.
3. Let ArgoCD sync the `cilium` Application.
4. Confirm `cilium` and `kube-system` are `Synced` and `Healthy`.
5. Delete only Helm release state:

```sh
kubectl delete secret -n kube-system -l owner=helm,name=cilium
```

1. Confirm Helm no longer sees Cilium:

```sh
helm list -n kube-system
kubectl get secret -n kube-system -l owner=helm,name=cilium
```

1. Confirm Cilium stayed healthy:

```sh
kubectl get app -n argocd cilium kube-system
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl get pods -n kube-system -l k8s-app=hubble-relay
```

## Optional Metadata Cleanup

Removing old Helm metadata is cosmetic once the release Secrets are gone. Do it only after ArgoCD
is healthy and the Helm release state has been deleted. Prefer removing the Helm release annotations
first; they are more specifically tied to Helm ownership than labels are.

```sh
kubectl get all,cm,secret,sa,role,rolebinding -n kube-system -o json \
  | jq -r '.items[]
    | select(.metadata.annotations["meta.helm.sh/release-name"] == "cilium")
    | "\(.kind | ascii_downcase)/\(.metadata.name)"' \
  | while read -r resource; do
      kubectl annotate -n kube-system "${resource}" \
      meta.helm.sh/release-name- \
      meta.helm.sh/release-namespace-
    done

kubectl get clusterrole,clusterrolebinding -o json \
  | jq -r '.items[]
    | select(.metadata.annotations["meta.helm.sh/release-name"] == "cilium")
    | "\(.kind | ascii_downcase)/\(.metadata.name)"' \
  | while read -r resource; do
      kubectl annotate "${resource}" \
      meta.helm.sh/release-name- \
      meta.helm.sh/release-namespace-
    done
```

If a completely clean metadata inventory is desired, first render the current chart and confirm it no
longer emits Helm ownership metadata:

```sh
yq 'select(.metadata.name == "cilium") | .spec.source.helm.valuesObject' \
  apps/argocd/manifests/apps.yaml > /tmp/home-ops-cilium-values.yaml

helm template cilium cilium \
  --repo https://helm.cilium.io/ \
  --version "$(yq 'select(.metadata.name == "cilium") | .spec.source.targetRevision' apps/argocd/manifests/apps.yaml)" \
  --namespace kube-system \
  -f /tmp/home-ops-cilium-values.yaml \
  | rg 'app.kubernetes.io/managed-by|meta.helm.sh/release'
```

Only then remove `app.kubernetes.io/managed-by=Helm` from ArgoCD-tracked Cilium resources:

```sh
kubectl get all,cm,secret,sa,role,rolebinding -n kube-system -o json \
  | jq -r '.items[]
    | select((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith("cilium:"))
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "Helm")
    | "\(.kind | ascii_downcase)/\(.metadata.name)"' \
  | while read -r resource; do
      kubectl label -n kube-system "${resource}" app.kubernetes.io/managed-by-
    done

kubectl get clusterrole,clusterrolebinding -o json \
  | jq -r '.items[]
    | select((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith("cilium:"))
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "Helm")
    | "\(.kind | ascii_downcase)/\(.metadata.name)"' \
  | while read -r resource; do
      kubectl label "${resource}" app.kubernetes.io/managed-by-
    done
```

Verify the optional cleanup:

```sh
kubectl get all,cm,secret,sa,role,rolebinding -n kube-system -o json \
  | jq -r '[.items[]
    | select((.metadata.annotations["meta.helm.sh/release-name"] // "") == "cilium")]
    | length'

kubectl get clusterrole,clusterrolebinding -o json \
  | jq -r '[.items[]
    | select((.metadata.annotations["meta.helm.sh/release-name"] // "") == "cilium")]
    | length'

kubectl get all,cm,secret,sa,role,rolebinding -n kube-system -o json \
  | jq -r '[.items[]
    | select((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith("cilium:"))
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "Helm")]
    | length'

kubectl get clusterrole,clusterrolebinding -o json \
  | jq -r '[.items[]
    | select((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith("cilium:"))
    | select(.metadata.labels["app.kubernetes.io/managed-by"] == "Helm")]
    | length'
```

Each command should return `0`.
