# Helm to ArgoCD Takeover Cleanup

## References

- ArgoCD renders Helm charts with `helm template`; ArgoCD, not Helm, owns
  application lifecycle afterward:
  <https://argo-cd.readthedocs.io/en/latest/user-guide/helm/>
- Helm uninstall removes release resources and release history unless history is
  explicitly kept:
  <https://docs.helm.sh/docs/helm/helm_uninstall/>
- Helm chart metadata commonly includes Helm-oriented labels and annotations:
  <https://helm.sh/docs/chart_best_practices/labels/>

## Problem

Some platform components must be installed before ArgoCD can fully manage the
cluster. Cilium must exist before ArgoCD has networking, and ArgoCD itself is
initially bootstrapped before it can manage its own chart.

After ArgoCD syncs the matching Application, the rendered resources can be
healthy under ArgoCD while Helm release state from bootstrap still remains in
the cluster. The dangerous cleanup is `helm uninstall`. Helm may delete
resources that ArgoCD has already adopted.

## Signals

Authoritative orphaned Helm release state is Helm release storage, not ordinary
chart labels:

```sh
helm list -A
kubectl get secret -A -l owner=helm
kubectl get configmap -A -l owner=helm
```

With Helm's default Secret storage driver, stale
`sh.helm.release.v1.<release>.v<revision>` Secrets are the lifecycle state that
makes Helm think a release still exists.

`app.kubernetes.io/managed-by=Helm` is usually normal chart output when ArgoCD
renders a Helm chart. Do not remove that label as a general cleanup step.

`meta.helm.sh/release-*` annotations are a stronger Helm ownership signal, but
even those can be desired chart output. Render the current chart before removing
them.

## Detect

Check ArgoCD first:

```sh
kubectl get app -n argocd
```

Then check all live Helm releases and Helm storage:

```sh
helm list -A
kubectl get secret -A -l owner=helm -o json \
  | jq -r '.items[]?
    | [.metadata.namespace, .metadata.name, (.metadata.labels.name // "")]
    | @tsv'
kubectl get configmap -A -l owner=helm -o json \
  | jq -r '.items[]?
    | [.metadata.namespace, .metadata.name, (.metadata.labels.name // "")]
    | @tsv'
```

If an ArgoCD app is `Synced` and `Healthy`, and Helm still lists the same
release, delete only Helm release storage. Do not run `helm uninstall`.

## Release Cleanup

Delete stale release storage by release name and namespace:

```sh
release_namespace=argocd
release_name=argocd

kubectl delete secret -n "${release_namespace}" \
  -l "owner=helm,name=${release_name}"
kubectl delete configmap -n "${release_namespace}" \
  -l "owner=helm,name=${release_name}"
```

For the completed bootstrap cleanup, this applied to:

```sh
kubectl delete secret -n kube-system -l owner=helm,name=cilium
kubectl delete secret -n argocd -l owner=helm,name=argocd
```

Confirm Helm no longer sees the release:

```sh
helm list -A
kubectl get secret -A -l owner=helm
kubectl get configmap -A -l owner=helm
```

## Annotation Inventory

Inventory remaining Helm release annotations across namespaced and
cluster-scoped resources:

```sh
{
  kubectl api-resources --verbs=list --namespaced=true -o name \
    | while IFS= read -r resource; do
        kubectl get "${resource}" -A -o json --ignore-not-found 2>/dev/null \
          | jq -r --arg resource "${resource}" '.items[]?
            | select((.metadata.annotations["meta.helm.sh/release-name"] // "") != "")
            | [
                $resource,
                .metadata.namespace,
                .metadata.name,
                .metadata.annotations["meta.helm.sh/release-name"],
                .metadata.annotations["meta.helm.sh/release-namespace"],
                (.metadata.annotations["argocd.argoproj.io/tracking-id"] // "")
              ]
            | @tsv'
      done

  kubectl api-resources --verbs=list --namespaced=false -o name \
    | while IFS= read -r resource; do
        kubectl get "${resource}" -o json --ignore-not-found 2>/dev/null \
          | jq -r --arg resource "${resource}" '.items[]?
            | select((.metadata.annotations["meta.helm.sh/release-name"] // "") != "")
            | [
                $resource,
                "",
                .metadata.name,
                .metadata.annotations["meta.helm.sh/release-name"],
                .metadata.annotations["meta.helm.sh/release-namespace"],
                (.metadata.annotations["argocd.argoproj.io/tracking-id"] // "")
              ]
            | @tsv'
      done
} | sort -u | tee /tmp/home-ops-helm-meta.tsv
```

## Annotation Cleanup

Only remove `meta.helm.sh/release-*` annotations after confirming the current
GitOps render does not include them for that chart:

```sh
kustomize build --enable-helm apps/<app> \
  | rg 'meta\.helm\.sh/release'
```

For explicit ArgoCD Helm Applications, render the chart with the same
`releaseName`, `targetRevision`, namespace, and values from
`apps/argocd/manifests/apps.yaml`.

If the current render does not include those annotations, remove only the
release annotations:

```sh
# Save the inventory command output from the previous section first.
awk -F '\t' '{print $1 "|" $2 "|" $3}' /tmp/home-ops-helm-meta.tsv \
  | while IFS='|' read -r resource namespace name; do
      [ -n "${resource}" ] || continue
      if [ -n "${namespace}" ]; then
        kubectl annotate -n "${namespace}" "${resource}/${name}" \
          meta.helm.sh/release-name- \
          meta.helm.sh/release-namespace- \
          --overwrite
      else
        kubectl annotate "${resource}/${name}" \
          meta.helm.sh/release-name- \
          meta.helm.sh/release-namespace- \
          --overwrite
      fi
    done
```

Do not remove `app.kubernetes.io/managed-by=Helm` labels unless the current
render proves the label is stale and ArgoCD remains `Synced` afterward. Most
Helm charts in this repo intentionally emit that label.

## Known Exceptions

Reloader currently renders Helm release annotations as desired output:

```sh
helm template reloader reloader \
  --repo https://stakater.github.io/stakater-charts \
  --version 2.2.11 \
  --namespace default \
  --set fullnameOverride=reloader \
  --set reloader.readOnlyRootFileSystem=true \
  --set reloader.podMonitor.enabled=true \
  | rg 'meta\.helm\.sh/release'
```

Keep those annotations on:

- `ServiceAccount/default/reloader`
- `Deployment/default/reloader`
- `Role/default/reloader-metadata-role`
- `RoleBinding/default/reloader-metadata-role-binding`
- `ClusterRole/reloader-role`
- `ClusterRoleBinding/reloader-role-binding`

The Deployment's current ReplicaSet may also inherit the annotations. Removing
the desired Reloader annotations makes the `reloader` Application `OutOfSync`.

## Completed Follow-Up Cleanup

The follow-up audit found and cleaned more than the original Cilium bootstrap
release:

- Removed stale Helm release storage for the bootstrap `argocd` release.
- Removed stale `meta.helm.sh/release-*` annotations from adopted ArgoCD,
  External Secrets CRDs, Longhorn, Cilium leftovers, Grafana Operator leftovers,
  and old test resources.
- Deleted stale `argo-cd-argocd-*` ClusterRoles and ClusterRoleBindings. Those
  bindings referenced ServiceAccounts in the non-existent `argo-cd` namespace
  and were not present in the current ArgoCD render.
- Restored the six chart-rendered Reloader annotations because they are desired
  state.

Final expected state:

```sh
helm list -A
kubectl get secret -A -l owner=helm
kubectl get configmap -A -l owner=helm
kubectl get app -n argocd argocd external-secrets cilium longhorn reloader
```

`helm list -A` and Helm storage queries should be empty. The checked ArgoCD
Applications should be `Synced` and `Healthy`.

A final annotation inventory should return only desired Reloader annotations,
including its current ReplicaSet if the Deployment has generated one.
