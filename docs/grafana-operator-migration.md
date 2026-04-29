# Grafana Operator Migration Notes

The first Grafana Operator change only installs the operator and CRDs through ArgoCD.

The active Grafana instance remains managed by kube-prometheus-stack:

- Route backend: `kube-prometheus-stack-grafana`
- Existing VolSync source PVC: `storage-kube-prometheus-stack-grafana-0`
- Existing backup repository: `grafana-volsync-b2`

Do not disable kube-prometheus-stack Grafana, change the Grafana HTTPRoute, or alter VolSync PVC references until an operator-managed Grafana instance has been deployed and validated side by side.

Follow-up migration should be planned separately and include:

1. Add a `Grafana` CR in `apps/monitoring/grafana`.
2. Add an `ExternalSecret` for admin credentials if UI login is retained.
3. Inventory dashboards from the current Grafana API and from dashboard ConfigMaps labeled for the kube-prometheus-stack sidecar.
4. Decide which UI-created dashboards need first-class `GrafanaDashboard` CRs.
5. For kube-prometheus-stack default dashboards, prefer enabling `grafana.operator.dashboardsConfigMapRefEnabled` and setting `grafana.operator.matchLabels` to the labels on the operator-managed `Grafana` instance instead of hand-converting every default dashboard.
6. Add datasource CRs, including a Prometheus datasource that matches the names expected by migrated dashboards.
7. Restore or migrate persistent data to the operator-managed PVC.
8. Switch `apps/monitoring/grafana/manifests/httproute.yaml` to the operator-managed service.
9. Disable kube-prometheus-stack Grafana only after the operator-managed instance is healthy and reachable.
