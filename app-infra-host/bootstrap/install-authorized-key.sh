#!/usr/bin/env bash
# Install one SSH public key into root authorized_keys.
# Requires VAULT_PUBKEY from env or /root/bootstrap.env — never embed keys here.

set -euo pipefail

log() { printf '[install-authorized-key] %s\n' "$*"; }
die() { printf '[install-authorized-key] ERROR: %s\n' "$*" >&2; exit 1; }

load_optional_env_file() {
  local f
  for f in "${BOOTSTRAP_ENV:-}" /root/bootstrap.env ./.env ./bootstrap.env; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    set -a
    # shellcheck disable=SC1090
    source "${f}"
    set +a
    log "Loaded env file: ${f}"
    return 0
  done
}

usage() {
  cat <<'EOF'
Usage: install-authorized-key.sh [public-key-line]

Required: VAULT_PUBKEY (env, argv, or /root/bootstrap.env)
EOF
}

validate_pubkey_line() {
  local line="$1"
  [[ -n "${line}" ]] || die "VAULT_PUBKEY is required (env, argv, or /root/bootstrap.env)"
  if [[ ! "${line}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]]; then
    die "Invalid public key format"
  fi
  if [[ "${line}" == *$'\n'* ]]; then
    die "Pass exactly one public key line"
  fi
}

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
  load_optional_env_file || true
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root on the target server"

  local pubkey="${VAULT_PUBKEY:-${1:-}}"
  validate_pubkey_line "${pubkey}"

  local auth="/root/.ssh/authorized_keys"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch "${auth}"
  chmod 600 "${auth}"

  if grep -qxF "${pubkey}" "${auth}" 2>/dev/null; then
    log "Public key already present"
  else
    printf '%s\n' "${pubkey}" >>"${auth}"
    log "Appended public key"
  fi
  log "SUCCESS — test from laptop with your private key (not in this repo)"
}

main "$@"
