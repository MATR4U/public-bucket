#!/usr/bin/env bash
# Step 01 — Prepare SSH access on a fresh target server.
# Restricts SSH to configured admin IP(s) via UFW.
#
# Phases (see docs/bootstrap-process.md):
#   --phase enable     Step 01 — SSH + UFW; password still allowed (Hetzner console)
#   --phase harden     Step 03b — disable password; requires public key in authorized_keys
#   --phase emergency  Step 00 — break-glass only; requires EMERGENCY_CONFIRM or --confirm
#
# From repo:
#   ./bin/01-prepare-ssh-access.sh --phase enable --config config/sites/<site>.json
#   ./bin/01-prepare-ssh-access.sh --phase harden --config config/sites/<site>.json
#
# One-liner Step 01 from public-bucket (values from /root/bootstrap.env only):
#   curl -fsSL .../01-prepare-ssh-access.sh | SSH_ALLOW_IP="$SSH_ALLOW_IP" SSH_PORT="$SSH_PORT" SSH_HARDEN=false bash
#
# Optional env vars:
#   SSH_ALLOW_IP, SSH_ALLOW_IPS, SSH_PORT, SSH_HARDEN, SSH_PASSWORD_AUTH

set -euo pipefail

if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "-" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  SCRIPT_DIR=""
  REPO_ROOT=""
fi

if [[ -n "${REPO_ROOT}" && -f "${REPO_ROOT}/lib/ssh-emergency.sh" ]]; then
  # shellcheck source=lib/ssh-emergency.sh
  source "${REPO_ROOT}/lib/ssh-emergency.sh"
fi

log()  { printf '[01-prepare-ssh] %s\n' "$*"; }
die()  { printf '[01-prepare-ssh] ERROR: %s\n' "$*" >&2; exit 1; }

systemd_unit() {
  local name="$1"
  if systemctl list-unit-files "${name}.service" --no-legend 2>/dev/null | grep -q "${name}.service"; then
    printf '%s' "${name}"
    return 0
  fi
  return 1
}

reload_ssh_service() {
  local unit=""
  if unit="$(systemd_unit ssh)"; then
    :
  elif unit="$(systemd_unit sshd)"; then
    :
  else
    die "No ssh or sshd systemd unit found"
  fi
  systemctl reload "${unit}"
}

restart_ssh_service() {
  local unit=""
  if unit="$(systemd_unit ssh)"; then
    :
  elif unit="$(systemd_unit sshd)"; then
    :
  else
    die "No ssh or sshd systemd unit found"
  fi
  systemctl restart "${unit}"
}

enable_ssh_service() {
  local unit=""
  if unit="$(systemd_unit ssh)"; then
    :
  elif unit="$(systemd_unit sshd)"; then
    :
  else
    die "No ssh or sshd systemd unit found"
  fi
  systemctl enable --now "${unit}"
}

usage() {
  cat <<'EOF'
Usage: 01-prepare-ssh-access.sh [options]

Prepare SSH on the target server: install openssh + ufw, allow SSH only
from configured admin IP(s).

Options:
  -c, --config PATH    Site config — JSON SSOT or derived `.env` (requires cloned repo on server)
  --phase PHASE        enable | harden (see docs/bootstrap-process.md)
  -h, --help           Show this help

Phases:
  enable     Install SSH + UFW allowlist on SSH_PORT; keep password auth (step 01)
  harden     Use SSH_PORT from env, disable password auth (step 03b)
  emergency  Break-glass reset — password on SSH_PORT; requires EMERGENCY_CONFIRM

Environment (curl one-liner or when no --config):
  SSH_ALLOW_IP         Single admin public IP (required if no config)
  SSH_ALLOW_IPS        Comma-separated admin IPs/CIDRs
  SSH_PORT             SSH port (required; no default in this repo)
  SSH_MANAGED_PORTS    Ports to reconcile in UFW (default: SSH_PORT)
  SSH_HARDEN           true|false — disable password auth
  SSH_PASSWORD_AUTH    true|false
  EMERGENCY_CONFIRM    I_AM_LOCKED_OUT — required for --phase emergency

Examples:
  set -a; source /root/bootstrap.env; set +a
  ./bin/01-prepare-ssh-access.sh --phase enable
  ./bin/01-prepare-ssh-access.sh --phase harden --config config/sites/<site>.json
  curl ... | SSH_ALLOW_IP="$SSH_ALLOW_IP" SSH_PORT="$SSH_PORT" SSH_HARDEN=true bash
EOF
}

load_config_file() {
  local config_file="$1"
  [[ -f "${config_file}" ]] || die "Config not found: ${config_file}"
  # shellcheck source=lib/source-site-config.sh
  source "${REPO_ROOT}/lib/source-site-config.sh"
  source_site_config_env "${config_file}" "${REPO_ROOT}" \
    || die "Failed to load site config (JSON requires npx + tsx): ${config_file}"
  log "Loaded: ${config_file}"
}

apply_ssh_defaults() {
  : "${SSH_ALLOW_IPS:=${SSH_ALLOW_IP:-}}"
  : "${SSH_PORT:?set SSH_PORT in env, /root/bootstrap.env, or --config}"
  : "${SSH_MANAGED_PORTS:=${SSH_PORT}}"
  : "${SSH_HARDEN:=${SSH_HARDEN:-false}}"
  : "${SSH_PASSWORD_AUTH:=${SSH_PASSWORD_AUTH:-true}}"
}

apply_phase_defaults() {
  local phase="${1:-}"
  case "${phase}" in
    enable)
      SSH_HARDEN=false
      SSH_PASSWORD_AUTH=true
      ;;
    harden)
      SSH_HARDEN=true
      SSH_PASSWORD_AUTH=false
      ;;
    emergency)
      SSH_HARDEN=false
      SSH_PASSWORD_AUTH=true
      ;;
    "")
      ;;
    *)
      die "Unknown --phase '${phase}' (use enable, harden, or emergency)"
      ;;
  esac
}

ensure_ssh_key_or_password() {
  local has_key=false
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -f "${f}" && -s "${f}" ]] && has_key=true
  done
  # Emergency recovery intentionally re-enables password without requiring a key.
  if [[ "${phase}" == "emergency" ]]; then
    return 0
  fi
  if [[ "${SSH_PASSWORD_AUTH}" == "false" || "${SSH_HARDEN}" == "true" ]]; then
    if [[ "${has_key}" != "true" ]]; then
      die "No SSH authorized_keys found. Add your public key before disabling password auth."
    fi
  fi
}

validate_ssh() {
  [[ -n "${SSH_ALLOW_IPS}" ]] || die "Set SSH_ALLOW_IP or SSH_ALLOW_IPS (your admin workstation public IP)"

  local ip
  IFS=',' read -r -a _ips <<< "${SSH_ALLOW_IPS}"
  for ip in "${_ips[@]}"; do
    ip="$(echo "${ip}" | xargs)"
    [[ -n "${ip}" ]] || continue
    if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
      die "Invalid IP/CIDR: ${ip}"
    fi
  done
}

configure_sshd() {
  local sshd_config="/etc/ssh/sshd_config"
  cp "${sshd_config}" "${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"

  if grep -q '^Port ' "${sshd_config}"; then
    sed -i "s/^Port .*/Port ${SSH_PORT}/" "${sshd_config}"
  else
    echo "Port ${SSH_PORT}" >> "${sshd_config}"
  fi

  if [[ "${SSH_HARDEN}" == "true" || "${phase}" == "harden" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "${sshd_config}"
  else
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${sshd_config}"
  fi
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "${sshd_config}"

  if [[ "${SSH_HARDEN}" == "true" ]]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "${sshd_config}"
    log "Password authentication disabled — ensure SSH keys work before disconnecting"
  elif [[ "${SSH_PASSWORD_AUTH}" == "false" ]]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "${sshd_config}"
  else
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${sshd_config}"
  fi

  if sshd -t; then
    if [[ "${SSH_PORT}" != "22" ]]; then
      if [[ -n "${REPO_ROOT}" && -f "${REPO_ROOT}/lib/sshd-reconcile.sh" ]]; then
        # shellcheck source=lib/sshd-reconcile.sh
        source "${REPO_ROOT}/lib/sshd-reconcile.sh"
        sshd_reconcile_remove_conflicting_dropins "${SSH_PORT}"
      fi
      systemctl stop ssh.socket 2>/dev/null || true
      systemctl disable ssh.socket 2>/dev/null || true
      systemctl mask ssh.socket 2>/dev/null || true
    fi
    if [[ "${SSH_PORT}" == "22" ]]; then
      reload_ssh_service
    else
      restart_ssh_service
    fi
    log "sshd active on port ${SSH_PORT}"
  else
    die "sshd config test failed — check ${sshd_config}"
  fi
}

configure_ufw_ssh_only() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y openssh-server ufw

  enable_ssh_service

  local fw_lib=""
  local bucket_base="${PUBLIC_BUCKET_BASE:-https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/infra-mail-server/bootstrap}"
  if [[ -n "${REPO_ROOT}" && -f "${REPO_ROOT}/lib/firewall-ssh.sh" ]]; then
    fw_lib="${REPO_ROOT}/lib/firewall-ssh.sh"
  elif [[ -f /root/lib/firewall-ssh.sh ]]; then
    fw_lib="/root/lib/firewall-ssh.sh"
  else
    fw_lib="/tmp/infra-mail-firewall-ssh.sh"
    curl -fsSL "${bucket_base}/lib/firewall-ssh.sh" -o "${fw_lib}"
    chmod 644 "${fw_lib}"
    log "Fetched lib/firewall-ssh.sh from public-bucket"
  fi
  # shellcheck source=lib/firewall-ssh.sh
  source "${fw_lib}"

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  firewall_ssh_allow_admin_ips "${SSH_PORT}" "${SSH_ALLOW_IPS}"
  firewall_ssh_purge_world_open "${SSH_MANAGED_PORTS}"
  firewall_ssh_purge_stale_ssh_ports "${SSH_PORT}" "${SSH_MANAGED_PORTS}"
  ufw --force enable
  firewall_ssh_assert_restricted "${SSH_PORT}" "${SSH_ALLOW_IPS}"
  ufw status verbose
}

main() {
  local config_file=""
  local phase=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config) config_file="${2:?}"; shift 2 ;;
      --phase)     phase="${2:?}"; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
  done

  if [[ -n "${config_file}" ]]; then
    [[ -n "${REPO_ROOT}" ]] || die "--config requires running from cloned repo (not curl pipe)"
    if [[ "${config_file}" != /* ]]; then
      config_file="${REPO_ROOT}/${config_file}"
    fi
    load_config_file "${config_file}"
  fi

  apply_phase_defaults "${phase}"
  apply_ssh_defaults
  validate_ssh

  if [[ "${phase}" == "emergency" ]]; then
    if declare -F ssh_emergency_require_confirm &>/dev/null; then
      ssh_emergency_require_confirm "${EMERGENCY_CONFIRM:+locked-out}"
    elif [[ "${EMERGENCY_CONFIRM:-}" != "I_AM_LOCKED_OUT" ]]; then
      die "Emergency phase requires EMERGENCY_CONFIRM=I_AM_LOCKED_OUT"
    fi
    log "EMERGENCY recovery — resetting SSH to SSH_PORT=${SSH_PORT} with password auth"
  fi

  ensure_ssh_key_or_password

  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root on the target server"

  if [[ "${phase}" == "emergency" || "${phase}" == "enable" || "${SSH_HARDEN}" == "false" ]]; then
    log "Phase: ${phase:-enable} — SSH + UFW (password auth remains on)"
  elif [[ "${phase}" == "harden" || "${SSH_HARDEN}" == "true" ]]; then
    log "Phase: harden — SSH_PORT=${SSH_PORT}, password auth disabled"
  fi

  log "Preparing SSH (port ${SSH_PORT}, password auth=${SSH_PASSWORD_AUTH})"
  configure_ufw_ssh_only
  configure_sshd

  log "Done. Connect from an allowed IP with your server address."
  if [[ "${phase}" == "emergency" ]]; then
    log "Emergency recovery complete — password SSH on SSH_PORT=${SSH_PORT}."
    log "Next: ssh root@<server> -> re-install public key -> update SSH_ALLOW_IP -> --phase harden"
    log "See docs/ssh-bootstrap.md section After emergency recovery"
  elif [[ "${SSH_HARDEN}" == "true" ]]; then
    log "Next: ./bin/04-bootstrap-host.sh --config config/sites/<site>.json"
    log "SSH: ssh -i .secrets/hosts/<provider>/<hostId>/ssh/id_ed25519 -p \"\$SSH_PORT\" root@<server>"
  else
    log "Next: step 02 on your machine (bin/02-generate-ssh-key.sh), install .pub, then --phase harden"
    log "      — or run bin/03-remote-bootstrap.sh to automate steps 02–05"
    log "See docs/bootstrap-process.md"
  fi
}

main "$@"
