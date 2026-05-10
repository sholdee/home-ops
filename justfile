bootstrap repo='.':
  ./hack/bootstrap/bootstrap.sh --repo '{{repo}}'

bootstrap-yes repo='.':
  ./hack/bootstrap/bootstrap.sh --repo '{{repo}}' --yes

bootstrap-dry-run repo='.':
  ./hack/bootstrap/bootstrap.sh --repo '{{repo}}' --dry-run

bootstrap-kind:
  ./hack/bootstrap/bootstrap.sh --kube-context kind-kind --yes

bootstrap-kind-fresh: kind-reset
  ./hack/bootstrap/bootstrap.sh --kube-context kind-kind --yes

bootstrap-kind-dry-run:
  ./hack/bootstrap/bootstrap.sh --kube-context kind-kind --from-phase bootstrap-crds --dry-run --yes

bootstrap-kind-seed:
  @op read op://Kubernetes/op-credentials/op-credentials.yaml | ./hack/bootstrap/bootstrap.sh --kube-context kind-kind --only-phase seed-secret --seed-secret-stdin --yes

bootstrap-kind-resume phase='bootstrap-crds':
  ./hack/bootstrap/bootstrap.sh --kube-context kind-kind --from-phase '{{phase}}' --yes

bootstrap-live-audit context='default':
  ./hack/bootstrap/bootstrap.sh --kube-context '{{context}}' --audit-only

bootstrap-live-dry-run context='default':
  ./hack/bootstrap/bootstrap.sh --kube-context '{{context}}' --from-phase bootstrap-crds --dry-run --yes

bootstrap-live-phase phase context='default':
  ./hack/bootstrap/bootstrap.sh --kube-context '{{context}}' --only-phase '{{phase}}' --dry-run --yes

kind-reset:
  kind delete cluster --name kind
  kind create cluster --name kind --config hack/bootstrap/kind-three-node.yaml

bootstrap-audit:
  ./hack/bootstrap/bootstrap.sh --audit-only

bootstrap-test:
  shellcheck hack/bootstrap/bootstrap.sh hack/bootstrap/lib/*.sh hack/bootstrap/phases/*.sh hack/bootstrap/tests/*.sh
  hack/bootstrap/tests/offline-parse.sh
