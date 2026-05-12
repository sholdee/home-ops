#!/usr/bin/env bash
set -euo pipefail

git diff --no-index --color=always -- "$@"
