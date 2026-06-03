# Contributing

Thanks for your interest! This is a personal homelab GitOps repository, but pull requests are welcome for bug fixes or improvements.

## Setup

```bash
brew install mise
mise install --locked --yes
just hooks-install
```

Local hooks run automatically on `git commit`. Use
`lefthook run pre-commit --file <changed-file>` for the smallest file-scoped
validation, `just lint` for full lint validation, and `just check` for full
local validation. Keep using drydock for app and component render/diff changes.
Renovate validation is CI-gated.

## Guidelines

- All manifests must target `linux/arm64` — this is a Raspberry Pi cluster
- Follow [Conventional Commits](https://www.conventionalcommits.org/) for commit messages
- All changes require a pull request — direct pushes to `master` are blocked
- CI gates validation on PRs; image verification on self-hosted runners is restricted to authorized users
