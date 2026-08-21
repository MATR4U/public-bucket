#!/usr/bin/env bash
# Step 03 — Re-enable root password SSH on the current port (break-glass, no UFW reset).
#
# Use when vault pubkey is missing and password login was disabled during harden.
# Does NOT wipe Mailcow or mail data — only adjusts sshd (+ optional UFW allow rule).
#
# Public-bucket one-liner (values from /root/bootstrap.env only):
#   curl -fsSL https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/infra-mail-server/bootstrap/break-glass-enable-password-root-ssh.sh \
#     | SSH_ALLOW_IP="$SSH_ALLOW_IP" SSH_PORT="$SSH_PORT" bash
#
# After password works, run install-host-vault-key from laptop, then harden again.

set -euo pipefail

log() { printf '[03-enable-password-root-ssh] %s\n' "$*"; }
die() { printf '[03-enable-password-root-ssh] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: 03-enable-password-root-ssh.sh

Re-enable PasswordAuthentication and PermitRootLogin for root on SSH_PORT.

Environment:
  SSH_PORT       SSH port (from env or current sshd; no repo default)
  SSH_ALLOW_IP   Optional admin IP -- adds UFW allow if rule missing
  SSH_ALLOW_IPS  Comma-separated admin IPs (overrides SSH_ALLOW_IP)

Examples:
  set -a; source /root/bootstrap.env; set +a
  bash 03-enable-password-root-ssh.sh
EOF
}

detect_ssh_port() {
  local port=""
  if command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
  fi
  if [[ -z "${port}" && -f /etc/ssh/sshd_config ]]; then
    port="$(awk '/^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' /etc/ssh/sshd_config)"
  fi
  printf '%s' "${port}"
}

ensure_ufw_allow() {
  local port="$1"
  local allow_ips="${2:-}"
  [[ -n "${allow_ips}" ]] || return 0
  command -v ufw >/dev/null 2>&1 || {
    log "ufw not installed — skipping firewall allow"
    return 0
  }

  local ip status
  status="$(ufw status 2>/dev/null || true)"
  IFS=',' read -r -a _ips <<< "${allow_ips}"
  for ip in "${_ips[@]}"; do
    ip="$(echo "${ip}" | xargs)"
    [[ -n "${ip}" ]] || continue
    if grep -F "${port}/tcp" <<<"${status}" | grep -Fq "${ip}"; then
      log "UFW already allows ${ip} -> port ${port}"
    else
      ufw allow from "${ip}" to any port "${port}" proto tcp comment "SSH admin break-glass"
      log "UFW allow from ${ip} -> port ${port}"
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
  log "sshd restarted (${unit})"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root on the target server (Hetzner web console)"

  : "${SSH_ALLOW_IPS:=${SSH_ALLOW_IP:-}}"
  if [[ -z "${SSH_PORT:-}" ]]; then
    SSH_PORT="$(detect_ssh_port)"
  fi
  [[ -n "${SSH_PORT}" ]] || die "set SSH_PORT in env or /root/bootstrap.env (could not detect sshd port)"

  local sshd_config="/etc/ssh/sshd_config"
  [[ -f "${sshd_config}" ]] || die "Missing ${sshd_config}"

  cp "${sshd_config}" "${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"

  if grep -q '^Port ' "${sshd_config}"; then
    sed -i "s/^Port .*/Port ${SSH_PORT}/" "${sshd_config}"
  else
    echo "Port ${SSH_PORT}" >>"${sshd_config}"
  fi

  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${sshd_config}"
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${sshd_config}"
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "${sshd_config}"

  if [[ "${SSH_PORT}" != "22" ]]; then
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl mask ssh.socket 2>/dev/null || true
  fi

  restart_ssh_service
  ensure_ufw_allow "${SSH_PORT}" "${SSH_ALLOW_IPS}"

  log "SUCCESS — root password auth enabled on port ${SSH_PORT}"
  log "Next from laptop (after Hetzner root password reset if needed):"
  log "  SSH_PASSWORD='…' ./scripts/install-host-vault-key.sh --config config/sites/<site>.json"
  log "Then re-harden: curl 01-prepare-ssh-access.sh | SSH_HARDEN=true SSH_PORT=\"\$SSH_PORT\" bash -- --phase harden"
}

main "$@"
