#!/usr/bin/env bash
# Shared sshd drop-in helpers for bootstrap scripts.
# Writes /etc/ssh/sshd_config.d/00-bootstrap.conf so settings win over cloud-init includes.

SSHD_DROPIN_PATH="/etc/ssh/sshd_config.d/00-bootstrap.conf"

sshd_bootstrap_die() {
  printf '[sshd-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

sshd_bootstrap_log() {
  printf '[sshd-bootstrap] %s\n' "$*"
}

sshd_bootstrap_detect_port() {
  local port="" sshd_config="/etc/ssh/sshd_config"

  if command -v ss >/dev/null 2>&1; then
    port="$(ss -tlnHp 2>/dev/null | awk '
      /sshd/ {
        split($1, a, ":")
        p = a[length(a)]
        gsub(/[^0-9]/, "", p)
        if (p ~ /^[0-9]+$/) { print p; exit }
      }')"
  fi
  if [[ -n "${port}" ]]; then
    printf '%s' "${port}"
    return 0
  fi

  if [[ -f "${sshd_config}" ]]; then
    port="$(awk '/^[[:space:]]*Port[[:space:]]+/ { print $2; exit }' "${sshd_config}" 2>/dev/null || true)"
  fi
  if [[ -z "${port}" ]] && systemctl list-unit-files ssh.socket --no-legend 2>/dev/null | grep -qE '^ssh\.socket'; then
    port="$(systemctl show ssh.socket -p ListenStream --value 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true)"
  fi
  if [[ -n "${port}" ]]; then
    printf '%s' "${port}"
  fi
}

sshd_bootstrap_write_dropin() {
  local port="${1:?}" permit_root="${2:?}" password_auth="${3:?}"
  local dropin_dir dropin_path="${SSHD_DROPIN_PATH}"

  dropin_dir="$(dirname "${dropin_path}")"
  mkdir -p "${dropin_dir}"
  if [[ -f "${dropin_path}" ]]; then
    cp "${dropin_path}" "${dropin_path}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat >"${dropin_path}" <<EOF
# Managed by app-infra-host bootstrap (00- sorts first; overrides cloud-init includes).
Port ${port}
PermitRootLogin ${permit_root}
PubkeyAuthentication yes
PasswordAuthentication ${password_auth}
EOF
  sshd_bootstrap_log "Wrote ${dropin_path}"
}

sshd_bootstrap_assert_listening() {
  local port="${1:?}"
  if ! command -v ss >/dev/null 2>&1; then
    sshd_bootstrap_die "ss not available — cannot verify sshd listens on port ${port}"
  fi
  if ! ss -tlnHp sport = :"${port}" 2>/dev/null | grep -q sshd; then
    local listeners
    listeners="$(ss -tlnp 2>/dev/null | grep sshd || echo 'none')"
    sshd_bootstrap_die "sshd is not listening on TCP port ${port}. sshd listeners: ${listeners}"
  fi
  sshd_bootstrap_log "Verified sshd listening on port ${port}"
}
