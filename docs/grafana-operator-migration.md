# Grafana Operator Migration Notes

The migration is being done in phases so the existing kube-prometheus-stack Grafana remains the live service until the operator-managed instance is validated.

The active Grafana instance remains managed by kube-prometheus-stack:

- Route backend: `kube-prometheus-stack-grafana`
- Existing VolSync source PVC: `storage-kube-prometheus-stack-grafana-0`
- Existing backup repository: `grafana-volsync-b2`

The side-by-side operator-managed Grafana phase adds:

- `Grafana` CR `monitoring/grafana`
- `GrafanaDatasource` CRs for Prometheus and Alertmanager
- kube-prometheus-stack generated `GrafanaDashboard` CRs via `grafana.operator.dashboardsConfigMapRefEnabled`
- native chart `GrafanaDashboard` CRs for crd-schema-publisher and renovate-operator
- manual bridge `GrafanaDashboard` CRs for external-secrets and Cilium dashboard ConfigMaps, since those charts only emit ConfigMaps

Do not disable kube-prometheus-stack Grafana, change the Grafana HTTPRoute, or alter VolSync PVC references until the operator-managed Grafana instance has been deployed and validated side by side.

Remaining follow-up migration work:

1. Add an `ExternalSecret` for admin credentials if UI login is retained.
2. Export and review the UI-created dashboards that are not currently provisioned.
3. Convert retained UI-created dashboards to first-class `GrafanaDashboard` CRs.
4. Restore or migrate persistent data to the operator-managed PVC if the side-by-side instance needs existing state.
5. Switch `apps/monitoring/grafana/manifests/httproute.yaml` to the operator-managed service.
6. Disable kube-prometheus-stack Grafana only after the operator-managed instance is healthy and reachable.
7. Update VolSync to back up the operator-managed Grafana PVC after cutover.
