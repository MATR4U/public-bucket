# public-bucket

Public curl/wget download bucket for **multiple MATR4U projects**.  
No shared secrets, no private application code, **no site/personal identity**, **no hardcoded IPs or SSH ports**.

## Projects

| Folder | Contents |
|--------|----------|
| **[app-infra-host/](app-infra-host/)** | Generic host SSH bootstrap (env-driven only) |
| **[infra-mail-server/](infra-mail-server/bootstrap/)** | Generic mail-host SSH bootstrap (env-driven only) |

## URL pattern

```text
https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/<project>/bootstrap/<script>.sh
```

### Enable SSH (fresh server)

Create `/root/bootstrap.env` on the host from `bootstrap.env.example` (fill real values only on the server), then:

```bash
set -a; source /root/bootstrap.env; set +a
curl -fsSL https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/app-infra-host/bootstrap/prepare-ssh-access.sh \
  | bash -s -- --phase enable
```

Required env keys: `SSH_ALLOW_IP`, `SSH_PORT`, `SSH_MANAGED_PORTS`.  
Scripts refuse to run without them — there are no defaults in the repo.

## Maintainer tooling

| Path | Purpose |
|------|---------|
| `scripts/scan-secrets.sh` | Block credentials **and** identity/IP/port leaks |
| `scripts/audit-public-release.sh` | Fail if operator-only or cross-project artifacts ship |
| `scripts/validate-bash-syntax.sh` | `bash -n` on bootstrap and repo scripts |
| `scripts/install-hooks.sh` | Enable local git hooks |
| `.github/workflows/ci.yml` | CI: scan + audit + syntax on push/PR |

```bash
./scripts/install-hooks.sh
bash scripts/scan-secrets.sh
bash scripts/audit-public-release.sh
bash scripts/validate-bash-syntax.sh
```

Do not put API tokens, private keys, real `.env` files, site names, personal names, IPs, or SSH port numbers in this repo.
