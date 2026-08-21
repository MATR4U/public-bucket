# Host SSH bootstrap

Generic scripts for fresh VMs.  
**No** site names, personal names, real IPs, or port numbers in tracked files.

Host SSH + UFW only — interactive prompts at runtime (no env file required on the server).

## Hetzner / fresh server (one command)

Paste as **root** in the provider web console:

```bash
curl -fsSL https://raw.githubusercontent.com/IFEOMA-CLOUD360/public-bucket/main/app-infra-host/bootstrap/prepare-ssh-access.sh -o /root/prepare-ssh-access.sh && chmod +x /root/prepare-ssh-access.sh && /root/prepare-ssh-access.sh --phase enable
```

The script downloads, then **asks** for your admin IP, SSH port, and UFW ports. No `/root/bootstrap.env` needed.

## Phases

| Phase | When |
|-------|------|
| `enable` | First access — password OK |
| `harden` | After your SSH key works — disable password |
| `emergency` | Locked out — confirms `I_AM_LOCKED_OUT` at prompt |

## Automation (optional)

```bash
/root/prepare-ssh-access.sh --phase enable --non-interactive --env-file /root/bootstrap.env
```
