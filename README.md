# inchambers.ai Gateway — deploy manifests

**One-click deploy the inchambers.ai Gateway into your own cloud or
on-prem.** All artifacts in this repo are generated from the private
source repo; Docker images live at
[`ghcr.io/inchambers-ai/ic-gateway-*`](https://github.com/orgs/inchambers-ai/packages).
The source stays private, the deploy bits are Apache-2.0 so you can
fork, audit, and customize freely.

---

## One-click deploy

Every button below routes through
[`app.inchambers.ai/api/public/deploy/<platform>?org_id=<your-uuid>`](https://app.inchambers.ai)
which pre-fills your `org_id` server-side before redirecting.

| Platform | Cost (5 seats) | Button |
|---|---|---|
| **Azure** (VM + docker-compose) | ~$30/mo | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Finchambers-ai%2Fgateway-deploy%2Fmain%2Fbicep%2Fazuredeploy.json) |
| **AWS** (EC2 + docker-compose) | ~$14/mo | [Launch stack →](https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateURL=https://raw.githubusercontent.com/inchambers-ai/gateway-deploy/main/cloudformation/gateway.yaml&stackName=ic-gateway) |
| **Google Cloud** (Cloud Shell) | ~$9/mo | [Open in Cloud Shell →](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https%3A%2F%2Fgithub.com%2Finchambers-ai%2Fgateway-deploy&cloudshell_tutorial=terraform%2Fgcp%2FTUTORIAL.md) |
| **Render** (Blueprint) | ~$34/mo | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/inchambers-ai/gateway-deploy) |
| **Railway** (template) | ~$20/mo | [![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template?template=https%3A%2F%2Fgithub.com%2Finchambers-ai%2Fgateway-deploy&plugins=postgresql) |
| **Docker Compose** (any VM) | ~$5/mo + VM | See [docker-compose.md](./docker-compose.md) for the one-liner |
| **Kubernetes** (Helm) | varies | See [helm/](./helm/) for `helm install` |

Cheapest end-to-end: **Hetzner CAX11 ($4.50/mo) + docker-compose** via
the install-script one-liner.

---

## What this repo contains

```
.
├── docker-compose.yaml      ← pulls GHCR images; used by VM cloud-init scripts
├── install.sh               ← one-liner installer for any Docker host
├── .env.example             ← env vars the compose stack reads
├── caddy/
│   ├── Caddyfile            ← TLS-terminating reverse proxy
│   └── Caddyfile.notls      ← plain-HTTP variant for LB-fronted deploys
├── bicep/                   ← Azure Resource Manager deploy
├── cloudformation/          ← AWS CloudFormation deploy
├── helm/                    ← Kubernetes Helm chart
├── terraform/
│   ├── aws/                 ← AWS ECS Fargate alternative (managed)
│   └── gcp/                 ← GCP Cloud Run alternative + TUTORIAL.md
├── railway.toml             ← Railway template manifest
├── render.yaml              ← Render Blueprint
└── README.md                ← this file
```

---

## Don't open PRs here

This repo is generated — pushes happen automatically when the private
source repo updates. File issues at
[inchambers-ai/inchambers](https://github.com/inchambers-ai/inchambers)
(or via your inchambers.ai support contact) instead. You can fork this
repo freely for your own customizations under the Apache-2.0 license.

---

## What's inside the gateway

Four services:

| Service | Image | Purpose |
|---|---|---|
| `caddy` | `ghcr.io/inchambers-ai/ic-gateway-caddy` | TLS, reverse proxy, CORS, model-name-based routing |
| `relay` | `ghcr.io/inchambers-ai/ic-gateway-relay` | Subscription-token AI (ChatGPT Plus, Claude Pro) — Rust |
| `litellm` | `ghcr.io/inchambers-ai/ic-gateway-litellm` | API-key providers (OpenRouter, Foundry, Bedrock, Vertex) — Python fork of BerriAI/litellm with inchambers.ai JWT auth plugin |
| `admin-ui` | `ghcr.io/inchambers-ai/ic-gateway-admin-ui` | React admin console — Providers / Users / Usage / Health tabs |

Plus bundled Postgres (virtual keys + audit log + encrypted subscription
cookies). No Redis — the relay rate-limits in-memory at default scale.

---

## License

Deploy manifests in this repo are Apache-2.0 — fork and modify freely.
See [LICENSE](./LICENSE).

The Docker images at `ghcr.io/inchambers-ai/ic-gateway-*` bundle
proprietary inchambers.ai code and are licensed per the EULA shipped
inside each image; pulling and running them in your own environment is
permitted under the terms of your inchambers.ai subscription.
