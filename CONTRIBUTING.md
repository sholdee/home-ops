# Contributing

Thanks for your interest! This is a personal homelab GitOps repository, but pull requests are welcome for bug fixes or improvements.

## Setup

```bash
brew install pre-commit kubeconform shellcheck actionlint kustomize helm
pre-commit install
```

Pre-commit hooks run automatically on `git commit` and validate YAML syntax, Kubernetes schemas, kustomize builds, shell scripts, GitHub Actions workflows, and markdown.

## Guidelines

- All manifests must target `linux/arm64` — this is a Raspberry Pi cluster
- Follow [Conventional Commits](https://www.conventionalcommits.org/) for commit messages
- All changes require a pull request — direct pushes to `master` are blocked
- Pre-commit checks run on all PRs; image verification on self-hosted runners is restricted to authorized users
