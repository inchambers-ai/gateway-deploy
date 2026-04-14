# Railway — inchambers-gateway one-click deploy

Railway is the fastest hosted path for firms that don't already run Azure /
AWS / GCP. The four gateway services plus Postgres + Redis spin up in a
single project in ~3-5 minutes.

## One-click

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template?template=https%3A%2F%2Fgithub.com%2Finchambers-ai%2Finchambers%2Ftree%2Fmain%2Fgateway&plugins=postgresql%2Credis)

Click the button, sign in with your Railway account, fill in the three
required fields, and hit Deploy:

| Field | Where to get it |
|---|---|
| `GATEWAY_ORG_ID` | inchambers.ai → Org Admin → Settings → *Organization ID* |
| `GATEWAY_MASTER_KEY` | Railway auto-generates a 32-byte secret; accept the default |
| `LITELLM_MASTER_KEY` | Railway auto-generates; accept the default |

Optional (you can add later from the Railway dashboard):

- `OPENROUTER_API_KEY` — enables all API-key providers
- `AZURE_FOUNDRY_URL` + `AZURE_FOUNDRY_KEY` — direct Foundry routing
- `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` — Bedrock

## What gets provisioned

| Service | Purpose | Image |
|---|---|---|
| `caddy` | Public ingress (TLS terminates at Railway) | `gateway/caddy/Dockerfile` |
| `relay` | Subscription-token AI (ChatGPT Plus / Claude Pro) | `gateway/services/relay/Dockerfile` |
| `litellm` | API-key providers (OpenRouter / Foundry / Bedrock / Vertex) | `gateway/services/litellm/Dockerfile` |
| `admin-ui` | Firm admin React app | `gateway/admin-ui/Dockerfile` |
| Postgres 16 plugin | Virtual keys, audit, encrypted subscription cookies | Railway native |
| Redis 7 plugin | Rate limiter + JWKS cache | Railway native |

Total cost at idle: **~$5-10/month** (Railway's Hobby plan + minimal Postgres/Redis).
Active workload (5 attorneys): **~$25-40/month**.

## After deploy

1. Railway assigns an `https://your-project-caddy.up.railway.app` URL to the
   `caddy` service. Copy it.
2. In inchambers.ai → Org Admin → Settings → AI Platform → *Firm-hosted
   Gateway*, paste that URL and save.
3. Open `https://your-project-caddy.up.railway.app/admin/` and sign in with
   your inchambers.ai org-admin JWT to configure ChatGPT Plus / Claude Pro
   cookies.
4. (Optional) Add a custom domain in Railway → caddy service → Settings.

## Custom domains

Railway auto-provisions TLS for any custom CNAME. Point `gateway.yourfirm.com`
at the Railway `*.up.railway.app` URL; set `ALLOWED_ORIGIN` on the Caddy
service if your add-in hostname is non-default.

## Updates

Railway watches the `main` branch of `inchambers-ai/inchambers` by default
— pushes to main trigger rebuilds of the four services. Pin to a specific
tag by editing each service's *Source* settings in the Railway dashboard.
