kind_cluster := env_var_or_default("KIND_CLUSTER", "home-ops-bootstrap")
kind_context := "kind-" + kind_cluster

bootstrap repo='.':
  ./hack/bootstrap/bootstrap.sh --repo '{{repo}}'

bootstrap-yes repo='.':
  ./hack/bootstrap/bootstrap.sh --repo '{{repo}}' --yes

bootstrap-dry-run repo='.':
  ./hack/bootstrap/bootstrap.sh --repo '{{repo}}' --dry-run

bootstrap-kind:
  ./hack/bootstrap/bootstrap.sh --kube-context '{{kind_context}}' --yes

bootstrap-kind-fresh: kind-reset
  ./hack/bootstrap/bootstrap.sh --kube-context '{{kind_context}}' --yes

bootstrap-kind-dry-run:
  ./hack/bootstrap/bootstrap.sh --kube-context '{{kind_context}}' --from-phase bootstrap-crds --dry-run --yes

bootstrap-kind-seed:
  @op read op://Kubernetes/op-credentials/op-credentials.yaml | ./hack/bootstrap/bootstrap.sh --kube-context '{{kind_context}}' --only-phase seed-secret --seed-secret-stdin --yes

bootstrap-kind-resume phase='bootstrap-crds':
  ./hack/bootstrap/bootstrap.sh --kube-context '{{kind_context}}' --from-phase '{{phase}}' --yes

bootstrap-live-audit context='default':
  ./hack/bootstrap/bootstrap.sh --kube-context '{{context}}' --audit-only

bootstrap-live-dry-run context='default':
  ./hack/bootstrap/bootstrap.sh --kube-context '{{context}}' --from-phase bootstrap-crds --dry-run --yes

bootstrap-live-phase phase context='default':
  ./hack/bootstrap/bootstrap.sh --kube-context '{{context}}' --only-phase '{{phase}}' --dry-run --yes

kind-reset:
  kind delete cluster --name '{{kind_cluster}}'
  kind create cluster --name '{{kind_cluster}}' --config hack/bootstrap/kind-three-node.yaml

kind-delete:
  kind delete cluster --name '{{kind_cluster}}'

bootstrap-audit:
  ./hack/bootstrap/bootstrap.sh --audit-only

bootstrap-test:
  shellcheck hack/bootstrap/bootstrap.sh hack/bootstrap/lib/*.sh hack/bootstrap/phases/*.sh hack/bootstrap/tests/*.sh
  hack/bootstrap/tests/offline-parse.sh
