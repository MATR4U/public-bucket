#!/usr/bin/env bash
# Step 02 — Install an SSH public key into root authorized_keys (Hetzner console).
#
# Public-bucket one-liner:
#   curl -fsSL https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/infra-horizontal-services/mail-server/bootstrap/02-install-authorized-key.sh \
#     | VAULT_PUBKEY='ssh-ed25519 AAAA… comment' bash
#
# Or pass as first argument after bash -s:
#   curl -fsSL .../02-install-authorized-key.sh | bash -s -- 'ssh-ed25519 AAAA… comment'
#
# No secrets in this script — pubkey is supplied at runtime only.

set -euo pipefail

log() { printf '[02-install-authorized-key] %s\n' "$*"; }
die() { printf '[02-install-authorized-key] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: 02-install-authorized-key.sh [public-key-line]

Install one SSH public key for root (idempotent — skips if already present).

Environment:
  VAULT_PUBKEY   Full ssh-ed25519 / ssh-rsa / ecdsa public key line

Examples:
  VAULT_PUBKEY='ssh-ed25519 AAAA… user@host' ./bin/02-install-authorized-key.sh
  curl -fsSL .../02-install-authorized-key.sh | VAULT_PUBKEY='ssh-ed25519 AAAA…' bash
EOF
}

validate_pubkey_line() {
  local line="$1"
  [[ -n "${line}" ]] || die "Public key line is empty"
  if [[ ! "${line}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]]; then
    die "Invalid public key format (expected ssh-ed25519, ssh-rsa, or ecdsa line)"
  fi
  if [[ "${line}" == *$'\n'* ]]; then
    die "Pass exactly one public key line"
  fi
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root on the target server (Hetzner web console)"

  local pubkey="${VAULT_PUBKEY:-${1:-}}"
  validate_pubkey_line "${pubkey}"

  local auth="/root/.ssh/authorized_keys"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch "${auth}"
  chmod 600 "${auth}"

  if grep -qxF "${pubkey}" "${auth}" 2>/dev/null; then
    log "Public key already present in ${auth}"
  else
    printf '%s\n' "${pubkey}" >>"${auth}"
    log "Appended public key to ${auth}"
  fi

  log "Key fingerprint: $(ssh-keygen -lf "${auth}" 2>/dev/null | tail -1 || printf 'unknown')"
  log "SUCCESS — test from laptop:"
  log "  ssh -i .secrets/hosts/<provider>/<hostId>/ssh/id_ed25519 -p \"\$SSH_PORT\" root@<server>"
}

main "$@"
