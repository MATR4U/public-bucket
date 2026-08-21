# app-infra-host — host SSH bootstrap

Standalone **server console** scripts for fresh hosts (stage/dev/prod VMs).

**No site names, real host IPs, admin IPs, SSH ports, or SSH keys in this folder.** Pass allowlist and ports via `bootstrap.env` (or export) at runtime only.

## URL base

```text
https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/app-infra-host/bootstrap/
```

## Enable SSH (fresh server, password OK)

Provider web console as **root**. Set env from `bootstrap/bootstrap.env.example` (copy to `/root/bootstrap.env` on the host), then:

```bash
set -a; source /root/bootstrap.env; set +a
curl -fsSL https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/app-infra-host/bootstrap/prepare-ssh-access.sh \
  | bash -s -- --phase enable
```

Or pass env inline (type values in the console — do not commit them here):

```bash
curl -fsSL https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/app-infra-host/bootstrap/prepare-ssh-access.sh \
  | SSH_ALLOW_IP="$SSH_ALLOW_IP" SSH_PORT="$SSH_PORT" SSH_MANAGED_PORTS="$SSH_MANAGED_PORTS" \
    SSH_HARDEN=false SSH_PASSWORD_AUTH=true bash -s -- --phase enable
```

Paste as **one line**. Never commit real IPs or port numbers in this repo.

## Files

| Path | Purpose |
|------|---------|
| `bootstrap/prepare-ssh-access.sh` | Enable / harden / emergency SSH + UFW allowlist |
| `bootstrap/install-authorized-key.sh` | Install an authorized key (runtime) |
| `bootstrap/enable-password-root-ssh.sh` | Temporary password root SSH (break-glass style, generic name) |
| `bootstrap/lib/firewall-ssh.sh` | UFW helpers (fetched by the script when piped) |
| `bootstrap/lib/sshd-bootstrap.sh` | sshd drop-in + listen verification helpers |
| `bootstrap/bootstrap.env.example` | Required env var names (no real values) |

## Anti-patterns

| Avoid | Use instead |
|-------|-------------|
| Site-specific scripts with embedded host IP or ports | Runtime `SSH_ALLOW_IP` / `SSH_PORT` / `SSH_MANAGED_PORTS` |
| Numbered or break-glass filenames | Generic `prepare-ssh-access.sh` / `enable-password-root-ssh.sh` |
| Publishing SSH public keys in this folder | Install keys at runtime via `install-authorized-key.sh` |
