#!/usr/bin/env bash
# Validate shell syntax for project bootstrap scripts and repo scripts.
set -euo pipefail

while IFS= read -r -d '' f; do
  bash -n "${f}"
done < <(find . -path './.git' -prune -o \( -path '*/bootstrap/*.sh' -o -path './scripts/*.sh' \) -print0)
