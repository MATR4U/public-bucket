#!/usr/bin/env bash
# Install repo git hooks (pre-commit + pre-push identity/secret scan).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
chmod +x .githooks/pre-push .githooks/pre-commit scripts/scan-secrets.sh scripts/validate-bash-syntax.sh 2>/dev/null || true
git config core.hooksPath .githooks
printf '[install-hooks] core.hooksPath=.githooks (pre-commit + pre-push run scan-secrets.sh)\n'
