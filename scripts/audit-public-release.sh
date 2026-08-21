#!/usr/bin/env bash
# Fail closed: public-bucket must not ship operator-only or cross-project artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

log()  { printf '[audit-public-release] %s\n' "$*"; }
fail() { printf '[audit-public-release] FAIL: %s\n' "$*" >&2; exit 1; }

FOUND=0
note() { log "$1"; FOUND=$((FOUND + 1)); }

BOOTSTRAP="${ROOT}/app-infra-host/bootstrap"
ALLOWED_BOOTSTRAP=(
  prepare-ssh-access.sh
  install-authorized-key.sh
  enable-password-root-ssh.sh
  bootstrap.env.example
  README.md
  lib/firewall-ssh.sh
  lib/sshd-bootstrap.sh
)

[[ -d "${BOOTSTRAP}" ]] || fail "Missing ${BOOTSTRAP}"

# --- Operator-only filenames (must never be published) ---
FORBIDDEN_NAMES=(
  prestage-ssh.sh
  .env
  bootstrap.env
)
for name in "${FORBIDDEN_NAMES[@]}"; do
  while IFS= read -r -d '' path; do
    note "operator-only file published: ${path#${ROOT}/}"
  done < <(find app-infra-host -name "${name}" -print0 2>/dev/null || true)
done

while IFS= read -r -d '' path; do
  note "env file published (only *.example allowed): ${path#${ROOT}/}"
done < <(find app-infra-host -name '*.env' ! -name '*.example' -print0 2>/dev/null || true)

while IFS= read -r -d '' path; do
  note "operator env example must not ship: ${path#${ROOT}/}"
done < <(find app-infra-host -name '.env.example' -print0 2>/dev/null || true)

# --- Bootstrap allowlist (no stale / retired scripts) ---
while IFS= read -r -d '' path; do
  rel="${path#${BOOTSTRAP}/}"
  [[ "${rel}" == lib/firewall-ssh.sh || "${rel}" == lib/sshd-bootstrap.sh ]] && continue
  case " ${ALLOWED_BOOTSTRAP[*]} " in
    *" ${rel} "*) continue ;;
  esac
  note "unexpected bootstrap artifact: app-infra-host/bootstrap/${rel}"
done < <(find "${BOOTSTRAP}" -type f -print0)

# --- Cross-project / private-repo references in published tree ---
REF_PATTERNS=(
  'IFEOMA-CLOUD360'
  'IFEOMA_CLOUD360'
  'prestage-ssh'
  'sync-public-bucket'
  'infra-mail-server'
  'certificate-manager'
  'app-infra-operator'
  'github\.com/[^/]+/app-infra-host'
  '\bSSOT\b'
  'private repo'
  'private-repo'
)
for pattern in "${REF_PATTERNS[@]}"; do
  if grep -rE --include='*.md' --include='*.sh' --include='*.example' -l "${pattern}" app-infra-host 2>/dev/null; then
    while IFS= read -r path; do
      note "cross-project reference (${pattern}): ${path#${ROOT}/}"
    done < <(grep -rE --include='*.md' --include='*.sh' --include='*.example' -l "${pattern}" app-infra-host 2>/dev/null || true)
  fi
done

# --- Sensitive assignment patterns in published bootstrap ---
while IFS= read -r -d '' path; do
  if grep -qE '^\s*(STAGE_HOST|STAGE_SSH_|CERT_MANAGER_)=' "${path}" 2>/dev/null; then
    note "operator prestaging key in published file: ${path#${ROOT}/}"
  fi
done < <(find app-infra-host/bootstrap -type f \( -name '*.sh' -o -name '*.example' -o -name 'README.md' \) -print0)

if [[ "${FOUND}" -gt 0 ]]; then
  fail "${FOUND} public-release policy violation(s)"
fi

log "OK — app-infra-host/ contains only allowed public bootstrap artifacts"
