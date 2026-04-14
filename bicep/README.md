# Azure Bicep — inchambers-gateway

**One Azure VM, docker-compose inside — the cheapest Azure path.**

| Size | vCPU / RAM | Monthly | Good for |
|---|---|---|---|
| `Standard_B1s` | 1 / 1 GB | ~$8 | Trial, 1-2 seats |
| `Standard_B2s` (default) | 2 / 4 GB | **~$30** | 2-50 seats, default |
| `Standard_B2ms` | 2 / 8 GB | ~$60 | 50-100 seats, longer contexts |
| `Standard_B4ms` | 4 / 16 GB | ~$120 | 100-200 seats, heavy usage |

Plus ~$3/month for the 32 GB StandardSSD_LRS disk + egress (first 100 GB free). Total for most firms: **~$30-35/month all-in**.

## One-click

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fapp.inchambers.ai%2Fapi%2Fpublic%2Fdeploy%2Fazure)

Clicking opens the Azure Portal with all parameters including your `org_id` pre-filled (the button routes through `app.inchambers.ai/api/public/deploy/azure` which injects it). You fill only the things we can't know from the browser: resource group, SSH public key, optional OpenRouter key. Hit Create. ~3 minutes to a running gateway.

## Manual

```bash
# Generate secrets (they stay on your machine)
MASTER_KEY=$(openssl rand -base64 32)
LITELLM_KEY="sk-$(openssl rand -hex 24)"

az group create -n rg-ic-gateway -l eastus

az deployment group create \
  -g rg-ic-gateway \
  -f main.bicep \
  -p name=acme-firm \
     orgId=<your-inchambers-org-uuid> \
     adminEmail=admin@acme-firm.com \
     sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
     gatewayMasterKey="$MASTER_KEY" \
     litellmMasterKey="$LITELLM_KEY" \
     openRouterApiKey=sk-or-v1-... \
     gatewayDomain=gateway.acme-firm.com
```

The deployment outputs `gatewayUrl`, `publicIp`, `sshCommand`. Point your DNS at `publicIp` (if using a custom domain), then paste `gatewayUrl` into inchambers.ai → Org Admin → AI Platform → Gateway URL.

## What's actually running inside the VM

- **Docker Engine** (installed by cloud-init on first boot)
- **docker-compose stack**:
  - `caddy` — TLS via Let's Encrypt, reverse proxy, CORS
  - `relay` — Rust subscription-token relay
  - `litellm` — Python API-key provider router
  - `admin-ui` — React admin console
  - `postgres` — bundled, single-node (fine for <100 seats)

No Redis — the Rust relay rate-limits in-process. No managed Postgres — the VM's local Postgres is more than enough for virtual keys + audit at this scale. No ACR, no Key Vault, no Log Analytics.

## Upgrading

- **Bigger VM**: redeploy with `-p vmSize=Standard_B4ms`. Azure resizes in-place in ~30 seconds.
- **Upgrade the gateway version**: SSH in, `cd /opt/inchambers-gateway && docker compose pull && docker compose up -d`.
- **Backup**: nightly snapshot of the OS disk (`az backup` or manual disk snapshots). Postgres data lives in `/var/lib/postgresql/data` inside the `postgres-data` Docker volume.

## When to move off a single VM

- **>100 active seats** — switch to the Helm chart on AKS with external Postgres (Azure Database for PostgreSQL Flexible) for HA.
- **Multi-region** — deploy this Bicep in each region, front with Azure Front Door.
- **SOC2 / HIPAA audit wants private networking + WAF** — extend the Bicep with `Microsoft.Network/privateEndpoints` + Front Door WAF.

Don't prematurely pay for those upgrades; they're not needed for a firm running the default.
