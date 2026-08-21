#!/usr/bin/env bash
# Fail closed on credentials OR identity reverse-links before push/commit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

log()  { printf '[scan-secrets] %s\n' "$*"; }
fail() { printf '[scan-secrets] FAIL: %s\n' "$*" >&2; exit 1; }

mapfile -t FILES < <(
  {
    git ls-tree -r HEAD --name-only 2>/dev/null || true
    git diff --name-only 2>/dev/null || true
    git diff --cached --name-only 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sort -u | grep -v '^$' || true
)

[[ ${#FILES[@]} -gt 0 ]] || fail "No files to scan (not a git repo?)"

BLOCKED_NAMES=('*.pem' '*.key' 'id_rsa' 'id_ed25519' '*.p12' '*.pfx' 'credentials.json' '.env')
BLOCKED_PATH_REGEX='(01-prepare|break-glass)'

is_allowed_path() {
  local path="$1"
  [[ "${path}" == *.env.example ]] && return 0
  [[ "${path}" == */bootstrap.env.example ]] && return 0
  [[ "${path}" == */secret-scan-allowlist.txt ]] && return 0
  [[ "${path}" == scripts/scan-secrets.sh ]] && return 0
  # Published mail-server bootstrap scripts (names match bin/01-prepare*, break-glass*).
  [[ "${path}" == infra-mail-server/bootstrap/* ]] && return 0
  return 1
}

matches_name() {
  local path="$1" pattern base
  base="$(basename "${path}")"
  for pattern in "${BLOCKED_NAMES[@]}"; do
    case "${pattern}" in
      \*.*) [[ "${base}" == *"${pattern#\*}" ]] && return 0 ;;
      *) [[ "${base}" == "${pattern}" ]] && return 0 ;;
    esac
  done
  return 1
}

is_placeholder_value() {
  local value="$1"
  [[ -z "${value}" ]] && return 0
  [[ "${value}" =~ ^(YOUR_|CHANGEME|REPLACE_ME|xxx+|example|placeholder|<[^>]+>|\.\.\.|\$) ]] && return 0
  [[ "${value}" == *YOUR_* ]] && return 0
  return 1
}

FOUND=0

for path in "${FILES[@]}"; do
  [[ -f "${path}" ]] || continue

  if is_allowed_path "${path}"; then
    continue
  fi

  if matches_name "${path}"; then
    log "blocked filename: ${path}"; FOUND=$((FOUND + 1)); continue
  fi

  if [[ "${path}" =~ ${BLOCKED_PATH_REGEX} ]]; then
    log "traceable path/filename: ${path}"; FOUND=$((FOUND + 1)); continue
  fi

  if grep -qE 'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY' "${path}" 2>/dev/null; then
    log "private key material: ${path}"; FOUND=$((FOUND + 1))
  fi
  if grep -qE '(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}' "${path}" 2>/dev/null; then
    log "GitHub token pattern: ${path}"; FOUND=$((FOUND + 1))
  fi
  if grep -qE 'AKIA[0-9A-Z]{16}' "${path}" 2>/dev/null; then
    log "AWS access key pattern: ${path}"; FOUND=$((FOUND + 1))
  fi
  if grep -qE 'sk-[A-Za-z0-9]{20,}' "${path}" 2>/dev/null; then
    log "sk- API key pattern: ${path}"; FOUND=$((FOUND + 1))
  fi
  if grep -qE '\b(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]]+AAAA[A-Za-z0-9+/=]+' "${path}" 2>/dev/null; then
    log "embedded SSH public key material: ${path}"; FOUND=$((FOUND + 1))
  fi

  # Any IPv4 literal — even documentation placeholders must be env vars
  if grep -qE '\b([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?\b' "${path}" 2>/dev/null; then
    log "hardcoded IPv4 (use env / bootstrap.env): ${path}"; FOUND=$((FOUND + 1))
  fi

  # Hardcoded port assignments
  if grep -qE '(SSH_PORT|SSH_MANAGED_PORTS)[[:space:]]*=[[:space:]]*[0-9]+' "${path}" 2>/dev/null; then
    log "hardcoded SSH port assignment (use env): ${path}"; FOUND=$((FOUND + 1))
  fi
  if grep -qE '(^|[[:space:]])Port[[:space:]]+[0-9]+' "${path}" 2>/dev/null; then
    log "hardcoded sshd Port directive (use SSH_PORT env): ${path}"; FOUND=$((FOUND + 1))
  fi

  # Common SSH port literals (22 / 2222) outside env-var references
  if grep -vE '\$\{?SSH_|YOUR_|MANAGED_PORTS|<port>' "${path}" \
    | grep -qE '(^|[^0-9])(22|2222)([^0-9]|$)' 2>/dev/null; then
    log "hardcoded SSH port literal (use SSH_PORT / SSH_MANAGED_PORTS env): ${path}"
    FOUND=$((FOUND + 1))
  fi

  while IFS= read -r line; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${line}" =~ ^[[:space:]]*([A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY)[A-Za-z0-9_]*)=(.+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[3]}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      val="${val%\"}"; val="${val#\"}"
      val="${val%\'}"; val="${val#\'}"
      [[ "${key}" == SSH_PASSWORD_AUTH || "${key}" == SSH_HARDEN ]] && continue
      if ! is_placeholder_value "${val}"; then
        log "sensitive assignment ${key}=*** in ${path}"; FOUND=$((FOUND + 1))
      fi
    fi
  done < "${path}" || true
done

if [[ "${FOUND}" -gt 0 ]]; then
  fail "${FOUND} potential secret/identity issue(s) — remove before commit/push"
fi

log "OK — no credential or identity patterns in ${#FILES[@]} file(s)"
