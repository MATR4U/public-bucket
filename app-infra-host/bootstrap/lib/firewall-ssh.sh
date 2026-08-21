#!/usr/bin/env bash
# Shared UFW SSH allowlist helpers.
# No site names, host IPs, or default ports in this file — callers pass ports from env.

firewall_ssh_die() {
  printf '[firewall-ssh] ERROR: %s\n' "$*" >&2
  exit 1
}

firewall_ssh_log() {
  printf '[firewall-ssh] %s\n' "$*"
}

firewall_ssh_normalize_ips() {
  local raw="${1:-}"
  local ip
  IFS=',' read -r -a _ips <<< "${raw}"
  for ip in "${_ips[@]}"; do
    ip="$(echo "${ip}" | xargs)"
    [[ -n "${ip}" ]] || continue
    printf '%s\n' "${ip}"
  done
}

firewall_ssh_normalize_ports() {
  local raw="${1:-}"
  local port
  IFS=',' read -r -a _ports <<< "${raw}"
  for port in "${_ports[@]}"; do
    port="$(echo "${port}" | xargs)"
    [[ -n "${port}" ]] || continue
    if [[ ! "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
      firewall_ssh_die "Invalid SSH managed port: ${port}"
    fi
    printf '%s\n' "${port}"
  done
}

firewall_ssh_valid_ipv4_cidr() {
  local ip="${1:?}" base prefix octet
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    return 1
  fi
  base="${ip%/*}"
  IFS='.' read -r -a _octets <<<"${base}"
  for octet in "${_octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    ((10#${octet} >= 0 && 10#${octet} <= 255)) || return 1
  done
  if [[ "${ip}" == */* ]]; then
    prefix="${ip#*/}"
    ((prefix >= 0 && prefix <= 32)) || return 1
  fi
  return 0
}

firewall_ssh_valid_ipv6_cidr() {
  local ip="${1:?}" addr prefix
  if [[ "${ip}" == */* ]]; then
    addr="${ip%/*}"
    prefix="${ip#*/}"
    [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
    ((prefix >= 0 && prefix <= 128)) || return 1
  else
    addr="${ip}"
  fi
  [[ "${addr}" == *:* ]] || return 1
  [[ "${addr}" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
  return 0
}

firewall_ssh_valid_ip_cidr() {
  local ip="${1:?}"
  if [[ "${ip}" == *.* ]]; then
    firewall_ssh_valid_ipv4_cidr "${ip}"
    return $?
  fi
  if [[ "${ip}" == *:* ]]; then
    firewall_ssh_valid_ipv6_cidr "${ip}"
    return $?
  fi
  return 1
}

firewall_ssh_validate_ips() {
  local raw="${1:-}"
  [[ -n "${raw//[,\ ]/}" ]] || firewall_ssh_die "SSH_ALLOW_IPS empty — refusing SSH UFW sync (would lock out admin)"
  local ip
  while IFS= read -r ip; do
    firewall_ssh_valid_ip_cidr "${ip}" || firewall_ssh_die "Invalid SSH allow IP/CIDR: ${ip}"
  done < <(firewall_ssh_normalize_ips "${raw}")
}

firewall_ssh_delete_numbered_rules_matching() {
  local pattern="$1"
  local line num
  mapfile -t _lines < <(ufw status numbered 2>/dev/null | tac | grep -E "${pattern}" || true)
  for line in "${_lines[@]}"; do
    [[ -n "${line}" ]] || continue
    num="$(sed -n 's/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' <<<"${line}")"
    [[ -n "${num}" ]] || continue
    ufw --force delete "${num}" >/dev/null 2>&1 || true
  done
}

# Remove world-open SSH allows on each managed port (from env, not hardcoded).
firewall_ssh_purge_world_open() {
  local managed_ports="${1:?}"
  local port
  while IFS= read -r port; do
    firewall_ssh_delete_numbered_rules_matching "${port}/tcp[[:space:]].*ALLOW IN[[:space:]].*Anywhere"
    firewall_ssh_delete_numbered_rules_matching "${port}[[:space:]].*ALLOW IN[[:space:]].*Anywhere"
  done < <(firewall_ssh_normalize_ports "${managed_ports}")
}

# Drop rules for managed ports that are not the active SSH_PORT.
firewall_ssh_purge_stale_ssh_ports() {
  local active_port="${1:?}"
  local managed_ports="${2:?}"
  local port
  while IFS= read -r port; do
    [[ "${port}" == "${active_port}" ]] && continue
    firewall_ssh_purge_port_allow_rules "${port}"
  done < <(firewall_ssh_normalize_ports "${managed_ports}")
}

firewall_ssh_purge_port_allow_rules() {
  local port="${1:?}"
  firewall_ssh_delete_numbered_rules_matching "${port}/tcp[[:space:]].*ALLOW IN"
}

firewall_ssh_allow_admin_ips() {
  local ssh_port="${1:?}"
  local allow_ips="${2:?}"
  local ip
  while IFS= read -r ip; do
    ufw allow from "${ip}" to any port "${ssh_port}" proto tcp comment "SSH admin ${ip}"
    firewall_ssh_log "Allowed SSH from ${ip} -> port ${ssh_port}"
  done < <(firewall_ssh_normalize_ips "${allow_ips}")
}

firewall_ssh_assert_restricted() {
  local ssh_port="${1:?}"
  local allow_ips="${2:?}"
  local status
  status="$(ufw status verbose 2>/dev/null || true)"

  if ! grep -q "Status: active" <<<"${status}"; then
    firewall_ssh_die "UFW is not active"
  fi

  local port_token="${ssh_port}/tcp"
  if grep -qE "${port_token}.*ALLOW IN.*Anywhere" <<<"${status}"; then
    firewall_ssh_die "UFW allows ${port_token} from Anywhere"
  fi

  local ip missing=()
  while IFS= read -r ip; do
    if ! grep -F "${port_token}" <<<"${status}" | grep -Fq "${ip}"; then
      missing+=("${ip}")
    fi
  done < <(firewall_ssh_normalize_ips "${allow_ips}")

  if ((${#missing[@]} > 0)); then
    firewall_ssh_die "No UFW ALLOW rule for ${port_token} from admin IP(s): ${missing[*]}"
  fi
  firewall_ssh_log "SSH restricted to admin on port ${ssh_port}"
}
