#!/usr/bin/env bash
# Prepare SSH access on a fresh target server (app-infra-host).
#
# Interactive by default on a TTY (Hetzner web console): prompts for values at runtime.
# No bootstrap.env required. Use --non-interactive for automation with env vars/files.
#
# Example (Hetzner console as root — one line):
#   curl -fsSL …/prepare-ssh-access.sh -o /root/prepare-ssh-access.sh \
#     && chmod +x /root/prepare-ssh-access.sh \
#     && /root/prepare-ssh-access.sh --phase enable

set -euo pipefail

if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "-" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

log()  { printf '[prepare-ssh] %s\n' "$*"; }
die()  { printf '[prepare-ssh] ERROR: %s\n' "$*" >&2; exit 1; }

load_optional_env_file() {
  local f
  for f in "${BOOTSTRAP_ENV:-}" /root/bootstrap.env ./.env ./bootstrap.env; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1090
    source "${f}"
    set +a
    log "Loaded env file: ${f}"
    return 0
  done
  return 0
}

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
  if unit="$(systemd_unit ssh)"; then :; elif unit="$(systemd_unit sshd)"; then :; else die "No ssh or sshd systemd unit found"; fi
  systemctl reload "${unit}"
}

restart_ssh_service() {
  local unit=""
  if unit="$(systemd_unit ssh)"; then :; elif unit="$(systemd_unit sshd)"; then :; else die "No ssh or sshd systemd unit found"; fi
  systemctl restart "${unit}"
}

enable_ssh_service() {
  local unit=""
  if unit="$(systemd_unit ssh)"; then :; elif unit="$(systemd_unit sshd)"; then :; else die "No ssh or sshd systemd unit found"; fi
  systemctl enable --now "${unit}"
}

usage() {
  cat <<'EOF'
Usage: prepare-ssh-access.sh --phase enable|harden|emergency

Interactive (default on TTY — Hetzner web console):
  Prompts for admin IP, SSH port, and UFW ports. No env file required.

Automation:
  prepare-ssh-access.sh --phase enable --non-interactive [--env-file PATH]
  Requires SSH_ALLOW_IP, SSH_PORT, SSH_MANAGED_PORTS via env or env file.

Example:
  curl -fsSL …/prepare-ssh-access.sh -o /root/prepare-ssh-access.sh \
    && chmod +x /root/prepare-ssh-access.sh \
    && /root/prepare-ssh-access.sh --phase enable
EOF
}

source_bootstrap_lib() {
  local name="$1" rel_path="$2" lib_path="" bucket_base=""
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

detect_ssh_port_candidate() {
  source_bootstrap_lib sshd-bootstrap lib/sshd-bootstrap.sh
  sshd_bootstrap_detect_port
}

prompt_value() {
  local name="$1" prompt_text="$2" default="${3:-}" input=""
  if [[ -n "${!name:-}" ]]; then
    return 0
  fi
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt_text} [${default}]: " input
    input="${input:-${default}}"
  else
    read -r -p "${prompt_text}: " input
    [[ -n "${input}" ]] || die "${name} is required"
  fi
  printf -v "${name}" '%s' "${input}"
}

interactive_configure() {
  local phase="$1" detected_port=""
  detected_port="$(detect_ssh_port_candidate)"

  printf '\n=== SSH bootstrap (%s) — enter values ===\n' "${phase}"
  prompt_value SSH_ALLOW_IP "Your admin/laptop public IP (UFW allowlist)" ""
  SSH_ALLOW_IPS="${SSH_ALLOW_IPS:-${SSH_ALLOW_IP}}"
  prompt_value SSH_PORT "SSH listen port" "${detected_port}"
  [[ -n "${SSH_PORT}" ]] || die "SSH_PORT is required"
  prompt_value SSH_MANAGED_PORTS "UFW-managed ports (comma-separated)" "${SSH_PORT}"

  if [[ "${phase}" == "emergency" ]]; then
    prompt_value EMERGENCY_CONFIRM "Type I_AM_LOCKED_OUT to confirm emergency recovery" ""
  fi

  printf '\n'
  log "SSH_ALLOW_IP=${SSH_ALLOW_IPS} SSH_PORT=${SSH_PORT} SSH_MANAGED_PORTS=${SSH_MANAGED_PORTS}"
}

require_port() {
  local name="$1" value="${2:-}"
  [[ -n "${value}" ]] || die "${name} is required"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || ((value < 1 || value > 65535)); then
    die "${name} must be an integer port 1-65535 (got '${value}')"
  fi
}

apply_phase_defaults() {
  local phase="${1:-}"
  case "${phase}" in
    enable)
      : "${SSH_HARDEN:=false}"
      : "${SSH_PASSWORD_AUTH:=true}"
      ;;
    harden)
      : "${SSH_HARDEN:=true}"
      : "${SSH_PASSWORD_AUTH:=false}"
      ;;
    emergency)
      : "${SSH_HARDEN:=false}"
      : "${SSH_PASSWORD_AUTH:=true}"
      ;;
    "")
      die "--phase is required (enable|harden|emergency)"
      ;;
    *)
      die "Unknown --phase '${phase}' (use enable, harden, or emergency)"
      ;;
  esac
}

ensure_ssh_key_or_password() {
  local phase="$1"
  local has_key=false
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -f "${f}" && -s "${f}" ]] && has_key=true
  done
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
  : "${SSH_ALLOW_IPS:=${SSH_ALLOW_IP:-}}"
  [[ -n "${SSH_ALLOW_IPS}" ]] || die "SSH_ALLOW_IP is required"

  require_port SSH_PORT "${SSH_PORT:-}"
  [[ -n "${SSH_MANAGED_PORTS:-}" ]] || die "SSH_MANAGED_PORTS is required (comma-separated; must include SSH_PORT)"

  source_bootstrap_lib firewall-ssh lib/firewall-ssh.sh
  firewall_ssh_validate_ips "${SSH_ALLOW_IPS}"

  local port found=false
  IFS=',' read -r -a _ports <<< "${SSH_MANAGED_PORTS}"
  for port in "${_ports[@]}"; do
    port="$(echo "${port}" | xargs)"
    [[ -n "${port}" ]] || continue
    require_port SSH_MANAGED_PORTS "${port}"
    [[ "${port}" == "${SSH_PORT}" ]] && found=true
  done
  [[ "${found}" == "true" ]] || die "SSH_MANAGED_PORTS must include SSH_PORT=${SSH_PORT}"
}

apply_host_defaults() {
  if [[ -z "${SSH_PORT:-}" ]]; then
    source_bootstrap_lib sshd-bootstrap lib/sshd-bootstrap.sh
    local detected=""
    detected="$(sshd_bootstrap_detect_port || true)"
    [[ -n "${detected}" ]] || die "SSH_PORT not set and could not detect from listening socket, sshd_config, or ssh.socket"
    SSH_PORT="${detected}"
    log "Detected SSH_PORT=${SSH_PORT} from host"
  fi
  if [[ -z "${SSH_MANAGED_PORTS:-}" ]]; then
    SSH_MANAGED_PORTS="${SSH_PORT}"
    log "SSH_MANAGED_PORTS defaulted to ${SSH_PORT}"
  fi
}

apply_socket_defaults() {
  [[ -n "${SSH_DISABLE_SOCKET:-}" ]] && return 0
  if systemctl list-unit-files ssh.socket --no-legend 2>/dev/null | grep -qE '^ssh\.socket'; then
    SSH_DISABLE_SOCKET=true
    log "SSH_DISABLE_SOCKET=true (ssh.socket would ignore Port ${SSH_PORT})"
  fi
}

configure_sshd() {
  local phase="$1"
  local permit_root="" password_auth=""

  source_bootstrap_lib sshd-bootstrap lib/sshd-bootstrap.sh

  if [[ "${SSH_HARDEN}" == "true" || "${phase}" == "harden" ]]; then
    permit_root="prohibit-password"
  else
    permit_root="yes"
  fi

  if [[ "${SSH_HARDEN}" == "true" ]]; then
    password_auth="no"
    log "Password authentication disabled — ensure SSH keys work before disconnecting"
  elif [[ "${SSH_PASSWORD_AUTH}" == "false" ]]; then
    password_auth="no"
  else
    password_auth="yes"
  fi

  sshd_bootstrap_write_dropin "${SSH_PORT}" "${permit_root}" "${password_auth}"

  if ! sshd -t; then
    die "sshd config test failed — check ${SSHD_DROPIN_PATH}"
  fi

  if [[ "${SSH_DISABLE_SOCKET:-}" == "true" ]]; then
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl mask ssh.socket 2>/dev/null || true
  fi
  restart_ssh_service

  sshd_bootstrap_assert_listening "${SSH_PORT}"
}

configure_ssh_access() {
  local phase="$1" old_port="${2:-}"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y openssh-server ufw

  enable_ssh_service
  source_bootstrap_lib firewall-ssh lib/firewall-ssh.sh

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  firewall_ssh_allow_admin_ips "${SSH_PORT}" "${SSH_ALLOW_IPS}"
  if [[ -n "${old_port}" && "${old_port}" != "${SSH_PORT}" ]]; then
    log "Transitional UFW allow on port ${old_port} until sshd moves to ${SSH_PORT}"
    firewall_ssh_allow_admin_ips "${old_port}" "${SSH_ALLOW_IPS}"
  fi

  firewall_ssh_purge_world_open "${SSH_MANAGED_PORTS}"
  ufw --force enable

  configure_sshd "${phase}"

  if [[ -n "${old_port}" && "${old_port}" != "${SSH_PORT}" ]]; then
    firewall_ssh_purge_port_allow_rules "${old_port}"
    log "Removed transitional UFW allow on old port ${old_port}"
  fi
  firewall_ssh_purge_stale_ssh_ports "${SSH_PORT}" "${SSH_MANAGED_PORTS}"
  firewall_ssh_assert_restricted "${SSH_PORT}" "${SSH_ALLOW_IPS}"
  ufw status verbose
}

main() {
  local phase="" non_interactive=false env_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)            phase="${2:?}"; shift 2 ;;
      --non-interactive)  non_interactive=true; shift ;;
      --env-file)         env_file="${2:?}"; non_interactive=true; shift 2 ;;
      -h|--help)          usage; exit 0 ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
  done

  [[ -n "${phase}" ]] || die "--phase is required (enable|harden|emergency)"

  apply_phase_defaults "${phase}"

  if [[ "${non_interactive}" == "true" ]]; then
    BOOTSTRAP_ENV="${env_file:-${BOOTSTRAP_ENV:-}}"
    load_optional_env_file
    apply_host_defaults
  else
    [[ -t 0 ]] || die "Interactive mode requires a TTY (use Hetzner web console). For automation add --non-interactive."
    interactive_configure "${phase}"
  fi

  validate_ssh
  apply_socket_defaults

  if [[ "${phase}" == "emergency" ]]; then
    if [[ "${EMERGENCY_CONFIRM:-}" != "I_AM_LOCKED_OUT" ]]; then
      die "Emergency phase requires EMERGENCY_CONFIRM=I_AM_LOCKED_OUT"
    fi
    log "EMERGENCY recovery — password auth on SSH_PORT from env"
  fi

  ensure_ssh_key_or_password "${phase}"
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root on the target server"

  local old_port=""
  source_bootstrap_lib sshd-bootstrap lib/sshd-bootstrap.sh
  old_port="$(sshd_bootstrap_detect_port || true)"
  [[ -n "${old_port}" ]] && log "Detected current SSH listen port: ${old_port}"

  log "Phase: ${phase} — port=${SSH_PORT} harden=${SSH_HARDEN} password_auth=${SSH_PASSWORD_AUTH}"
  configure_ssh_access "${phase}" "${old_port}"

  log "Done. Connect from ${SSH_ALLOW_IPS} on port ${SSH_PORT}."
}

main "$@"
