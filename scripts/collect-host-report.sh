#!/usr/bin/env bash
# Read-only diagnostic collector for a configured app host.
#
# Run this ON the VPS when the site is down, then paste the output back. It
# answers the questions a 521 raises: is Docker up, is the app container
# running, is Traefik listening on 443, is the disk full, what do the logs say.
#
# Host identity (IP, apex, user) lives in config/hosts/<HOST_ID>.env  --  not
# here. A checkout loads that file. A standalone copy uses APEX / APP_SERVICE /
# APP_PORT from the environment if set.
#
# It CHANGES NOTHING. No start, stop, pull, prune, or config edit. Every command
# is a read. It is safe to run on a live host.
#
# Secrets: environment VALUES are never printed -- only variable NAMES. Log and
# config output passes through a redactor. Read it before you run it.
set -uo pipefail   # deliberately no -e: a failing probe must not abort the report

# --remote delegates to the workstation-side driver, which runs this same script
# on the VPS over SSH. A standalone copy downloaded onto the host has no sibling
# to delegate to, so say that plainly instead of failing obscurely.
if [ "${1:-}" = "--remote" ]; then
  shift
  _driver="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/host-report-remote.sh"
  if [ -f "$_driver" ]; then
    exec bash "$_driver" "$@"
  fi
  printf 'FAIL --remote needs scripts/host-report-remote.sh, which is not next to this file.\n' >&2
  printf 'You are running a standalone copy. Either run this script directly on the host\n' >&2
  printf '(it is already there), or use --remote from a checkout of the repo.\n' >&2
  exit 1
fi

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -n "${_here:-}" ] && [ -f "${_here}/lib/load-host-config.sh" ]; then
  ROOT="$(cd "${_here}/.." && pwd)"
  # shellcheck disable=SC1091
  . "${_here}/lib/load-host-config.sh"
  load_host_config || exit 1
fi

APP_SERVICE="${APP_SERVICE:-web}"
APP_PORT="${APP_PORT:-3000}"
APEX="${APEX:-${APEX_HOST:-}}"
ENV_GLOBS="${ENV_GLOBS:-/opt/*/.env /srv/*/.env /root/.env ./.env}"
LOG_NAME_RE="${LOG_NAME_RE:-${APP_SERVICE}|traefik}"
LOCAL_PROBE_HOST="${LOCAL_PROBE_HOST:-localhost}"

hr()  { printf '\n========== %s ==========\n' "$*"; }
sub() { printf '\n--- %s ---\n' "$*"; }
run() { printf '$ %s\n' "$*"; eval "$@" 2>&1 | redact | sed 's/^/  /' || printf '  (command failed or not available)\n'; }
have(){ command -v "$1" >/dev/null 2>&1; }

# Mask anything that looks like a credential before it reaches the report.
# Deliberately biased toward over-redaction: a benign string that merely
# contains 'secret'/'token' before a delimiter may be masked too. Losing a
# harmless value costs nothing; leaking a real one costs a rotation.
redact() {
  sed -E \
    -e 's/((PASSWORD|SECRET|TOKEN|APIKEY|API_KEY|PRIVATE_KEY|CF_DNS_API_TOKEN|ADMIN_PASSWORD)[A-Z_]*[=:])[^[:space:]"]*/\1<REDACTED>/gI' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/-]{8,}=*/\1<REDACTED>/g' \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1<REDACTED>/g' \
    -e 's/([A-Za-z0-9._%+-]+:)[^@[:space:]]{6,}(@)/\1<REDACTED>\2/g'
}

SUDO=""
if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO="sudo -n"; fi

hr "REPORT META"
printf 'generated: %s\n' "$(date -u +%FT%TZ)"
printf 'host: %s\n' "$(hostname 2>/dev/null)"
printf 'user: %s (uid %s)%s\n' "$(id -un)" "$(id -u)" "$([ -n "$SUDO" ] && echo '  --  using passwordless sudo where needed')"
printf 'script: collect-host-report.sh (read-only)\n'
[ -n "${HOST_ID:-}" ] && printf 'host_id: %s\n' "$HOST_ID"
[ -n "${APEX}" ] && printf 'apex: %s\n' "$APEX"
printf 'app_service: %s  app_port: %s\n' "$APP_SERVICE" "$APP_PORT"

hr "SYSTEM"
run "uname -a"
run "uptime"
have timedatectl && run "timedatectl" || run "date -u"

hr "DISK AND MEMORY"
# A full disk is the most common reason containers die and never come back.
run "df -h /"
run "df -h /var/lib/docker 2>/dev/null || true"
run "df -i / | tail -2"
run "free -m"

hr "DOCKER"
if ! have docker; then
  printf 'docker NOT INSTALLED  --  this is not the app host, or Docker was removed.\n'
else
  run "docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version"
  if ! $SUDO docker info >/dev/null 2>&1; then
    printf '\n*** docker info FAILED  --  daemon down or permission denied. This alone explains a 521. ***\n'
    run "$SUDO systemctl status docker --no-pager -l 2>/dev/null | head -20"
  fi
  sub "containers (all)"
  run "$SUDO docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'"
  sub "compose projects"
  run "$SUDO docker compose ls 2>/dev/null || true"
  sub "networks"
  run "$SUDO docker network ls"
  # The app must share the external 'traefik' network under alias 'web'.
  run "$SUDO docker network inspect traefik --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo 'no traefik network'"
  sub "volumes (ACME cert storage lives here)"
  run "$SUDO docker volume ls"
  sub "unhealthy containers"
  run "$SUDO docker ps -a --filter health=unhealthy --format '{{.Names}}: {{.Status}}'"
fi

hr "LISTENERS (who holds 80 / 443 / APP_PORT)"
PORT_RE=":(80|443|${APP_PORT})\\b"
if have ss; then
  run "$SUDO ss -tlnp 2>/dev/null | grep -E '${PORT_RE}' || echo 'NOTHING listening on 80/443/${APP_PORT}'"
elif have netstat; then
  run "$SUDO netstat -tlnp 2>/dev/null | grep -E '${PORT_RE}' || echo 'NOTHING listening on 80/443/${APP_PORT}'"
else
  printf 'neither ss nor netstat available\n'
fi

hr "LOCAL HTTP PROBES (from the host itself)"
sub "app container direct :$APP_PORT"
run "curl -sS -m 5 -o /dev/null -w 'http_code=%{http_code}\\n' http://${LOCAL_PROBE_HOST}:${APP_PORT}/api/health || true"
run "curl -sS -m 5 http://${LOCAL_PROBE_HOST}:${APP_PORT}/api/health/ready || true"
if [ -n "${APEX}" ]; then
  sub "through Traefik on :443 with Host: ${APEX}"
  run "curl -skS -m 8 -o /dev/null -w 'http_code=%{http_code}\\n' -H 'Host: ${APEX}' https://${LOCAL_PROBE_HOST}/api/health || true"
  sub "through :80"
  run "curl -sS -m 8 -o /dev/null -w 'http_code=%{http_code}\\n' -H 'Host: ${APEX}' http://${LOCAL_PROBE_HOST}/api/health || true"
else
  printf 'APEX / APEX_HOST unset  --  skipped Host-header probes. Set APEX or add config/hosts/<id>.env\n'
fi

hr "FIREWALL"
have ufw && run "$SUDO ufw status verbose" || true
have nft && run "$SUDO nft list ruleset 2>/dev/null | head -40" || true
have iptables && run "$SUDO iptables -S 2>/dev/null | head -30" || true

hr "LOGS (last 40 lines each, redacted)"
if have docker; then
  for c in $($SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ei "${LOG_NAME_RE}" | head -5); do
    sub "docker logs $c"
    run "$SUDO docker logs --tail 40 --timestamps '$c' 2>&1"
  done
fi
have journalctl && { sub "journal: docker unit"; run "$SUDO journalctl -u docker --no-pager -n 25 2>/dev/null"; } || true

hr "ENVIRONMENT KEY NAMES ONLY (no values)"
# shellcheck disable=SC2086
for f in $ENV_GLOBS; do
  [ -f "$f" ] || continue
  sub "$f"
  run "cut -d= -f1 '$f' | grep -v '^#' | grep -v '^$' | sort"
done

hr "END OF REPORT"
printf 'Nothing above was modified. Paste this whole report back.\n'
printf 'If a section says permission denied, re-run with: sudo bash %s\n' "$0"
