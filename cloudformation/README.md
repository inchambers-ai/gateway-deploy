# AWS CloudFormation — inchambers-gateway

**One EC2 VM, docker-compose inside — the cheapest AWS path.**

| InstanceType | vCPU / RAM (ARM) | Monthly | Good for |
|---|---|---|---|
| `t4g.micro` | 2 / 1 GB | ~$6 | Trial |
| `t4g.small` (default) | 2 / 2 GB | **~$12** | 2-50 seats, default |
| `t4g.medium` | 2 / 4 GB | ~$25 | 50-100 seats |
| `t4g.large` | 2 / 8 GB | ~$49 | 100-200 seats |

Plus ~$2/mo for 20 GB gp3 + egress (first 100 GB free per region).
Total for most firms: **~$14-16/mo all-in**.

## One-click

Click the button in your inchambers.ai org admin dashboard — it redirects
to the CloudFormation QuickCreate URL with `OrgId` pre-filled and the
template URL pointing at the public copy of `gateway.yaml`.

Manual equivalent:

```
https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate
  ?templateURL=https://raw.githubusercontent.com/inchambers-ai/gateway-deploy/main/cloudformation/gateway.yaml
  &stackName=ic-gateway
  &param_OrgId=<your-inchambers-org-uuid>
  &param_ImageRegistry=ghcr.io/inchambers-ai
  &param_ImageTag=latest
```

In the CloudFormation wizard you fill the remaining params:

| Param | Source |
|---|---|
| `AdminEmail` | Let's Encrypt registration (anything you own) |
| `SSHKeyName` | Pick from the dropdown (existing EC2 key pair in this region) |
| `GatewayMasterKey` | `openssl rand -base64 32` |
| `LitellmMasterKey` | `sk-$(openssl rand -hex 24)` |
| `OpenRouterApiKey` | Optional |
| `GatewayDomain` | `gateway.acme-firm.com` (leave blank for HTTP-only with the raw IP) |

Hit Create. In about 3 minutes the stack outputs `GatewayUrl`, `PublicIp`,
and `SshCommand`. Point DNS at `PublicIp`, then paste `GatewayUrl` into
inchambers.ai → Org Admin → AI Platform → Firm-hosted Gateway URL.

## Manual deploy via CLI

```bash
aws cloudformation deploy \
  --stack-name ic-gateway \
  --template-file gateway.yaml \
  --parameter-overrides \
    Name=ic-gateway \
    OrgId=<uuid> \
    AdminEmail=admin@firm.com \
    SSHKeyName=my-key \
    GatewayDomain=gateway.firm.com \
    GatewayMasterKey=$(openssl rand -base64 32) \
    LitellmMasterKey="sk-$(openssl rand -hex 24)" \
    OpenRouterApiKey=sk-or-v1-... \
  --capabilities CAPABILITY_NAMED_IAM
```

## Upgrading

- **Bigger instance**: change `InstanceType` in the stack and update.
  AWS stops/resizes/restarts in ~60 seconds.
- **New gateway version**: SSH to the VM, `cd /opt/inchambers-gateway`,
  `docker compose pull && docker compose up -d`.
- **Backups**: snapshot the root EBS volume (`aws ec2 create-snapshot`)
  nightly via EventBridge Scheduler or AWS Backup.

## When to move off a single EC2

- **>100 active seats** — switch to the ECS Fargate Terraform at
  `../terraform/aws/` for auto-scaling + multi-AZ.
- **SOC2 audit mandates private networking** — extend this template
  with a NAT Gateway + private subnet + VPC endpoints for SSM.
- **Multi-region** — deploy the stack in each region, front with
  Route 53 latency routing or CloudFront.

Don't prematurely pay for those upgrades; they're not needed below a
few hundred seats.
