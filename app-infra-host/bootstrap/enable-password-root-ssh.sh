#!/usr/bin/env bash
# Re-enable root password SSH on SSH_PORT from env (break-glass).
# Requires SSH_ALLOW_IP and SSH_PORT from env or /root/bootstrap.env.

set -euo pipefail

if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "-" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

log() { printf '[enable-password-root-ssh] %s\n' "$*"; }
die() { printf '[enable-password-root-ssh] ERROR: %s\n' "$*" >&2; exit 1; }

source_bootstrap_lib() {
  local rel_path="$1" lib_path="" bucket_base=""
  bucket_base="${PUBLIC_BUCKET_BASE:-https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/app-infra-host/bootstrap}"
  if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/${rel_path}" ]]; then
    lib_path="${SCRIPT_DIR}/${rel_path}"
  else
    lib_path="/tmp/app-infra-host-$(basename "${rel_path}")"
    curl -fsSL "${bucket_base}/${rel_path}" -o "${lib_path}"
    chmod 644 "${lib_path}"
    log "Fetched ${rel_path} from public-bucket"
  fi
  # shellcheck disable=SC1090
  source "${lib_path}"
}

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
Usage: enable-password-root-ssh.sh

Required (env or /root/bootstrap.env):
  SSH_ALLOW_IP | SSH_ALLOW_IPS
  SSH_PORT
EOF
}

require_port() {
  local value="${1:-}"
  [[ -n "${value}" ]] || die "SSH_PORT is required (env or /root/bootstrap.env) — no hardcoded default"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || ((value < 1 || value > 65535)); then
    die "SSH_PORT must be 1-65535"
  fi
}

ensure_ufw_allow() {
  local port="$1"
  local allow_ips="${2:-}"
  [[ -n "${allow_ips}" ]] || return 0
  command -v ufw >/dev/null 2>&1 || return 0
  local ip status
  status="$(ufw status 2>/dev/null || true)"
  IFS=',' read -r -a _ips <<< "${allow_ips}"
  for ip in "${_ips[@]}"; do
    ip="$(echo "${ip}" | xargs)"
    [[ -n "${ip}" ]] || continue
    if grep -F "${port}/tcp" <<<"${status}" | grep -Fq "${ip}"; then
      log "UFW already allows admin -> port ${port}"
    else
      ufw allow from "${ip}" to any port "${port}" proto tcp comment "SSH admin break-glass"
      log "UFW allow admin -> port ${port}"
    fi
  done
  ufw --force enable >/dev/null 2>&1 || true
}

restart_ssh_service() {
  local unit=""
  if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q ssh.service; then
    unit=ssh
  elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q sshd.service; then
    unit=sshd
  else
    die "No ssh or sshd systemd unit found"
  fi
  sshd -t
  systemctl restart "${unit}"
}

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
  load_optional_env_file || true
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root on the target server"

  : "${SSH_ALLOW_IPS:=${SSH_ALLOW_IP:-}}"
  [[ -n "${SSH_ALLOW_IPS}" ]] || die "Set SSH_ALLOW_IP or SSH_ALLOW_IPS"
  require_port "${SSH_PORT:-}"

  source_bootstrap_lib lib/sshd-bootstrap.sh
  sshd_bootstrap_write_dropin "${SSH_PORT}" "yes" "yes"

  if [[ "${SSH_DISABLE_SOCKET:-}" == "true" ]]; then
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl mask ssh.socket 2>/dev/null || true
  fi

  restart_ssh_service
  sshd_bootstrap_assert_listening "${SSH_PORT}"
  ensure_ufw_allow "${SSH_PORT}" "${SSH_ALLOW_IPS}"
  log "SUCCESS — root password auth enabled on port ${SSH_PORT}"
}

main "$@"
