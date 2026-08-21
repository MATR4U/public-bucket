# infra-mail-server  --  generic SSH bootstrap

Env-driven only. **No** site names, host IPs, admin IPs, SSH ports, or keys in this folder.

Copy `bootstrap.env.example` to `/root/bootstrap.env` on the server and fill values there (or export them). Site files in the private mail-server repo (`config/sites/<site>.env`) are the operator SSOT.

```bash
set -a; source /root/bootstrap.env; set +a
curl -fsSL https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/infra-mail-server/bootstrap/01-prepare-ssh-access.sh \
  | bash -s -- --phase enable
```
