# Deploy inchambers-gateway on Google Cloud — Cloud Shell Walkthrough

<walkthrough-author name="inchambers.ai"/>

Deploys the gateway to one `e2-small` Compute Engine VM running
`docker-compose`. Cost: **~$7/mo** for the VM + ~$2/mo for a static
external IP + egress.

**Estimated time:** 5-7 minutes, entirely inside this Cloud Shell. No
local CLI needed.

Click **Start** to begin.

---

## Step 1 — Pick your project

<walkthrough-project-setup></walkthrough-project-setup>

All commands below run against the project you picked. The current
project is:

```bash
echo "Project: $DEVSHELL_PROJECT_ID"
```

<walkthrough-footnote>
If no project shows, click the project picker in the top-left of Cloud
Shell and create one.
</walkthrough-footnote>

---

## Step 2 — Enable the Compute Engine API

<walkthrough-enable-apis apis="compute.googleapis.com"></walkthrough-enable-apis>

If the button above hasn't already enabled it:

```bash
gcloud services enable compute.googleapis.com
```

Takes ~30 seconds the first time; no-op after that.

---

## Step 3 — Set deployment variables

Paste your org UUID from inchambers.ai (Org Admin → Settings →
*Organization ID*) and your chosen domain. The OpenRouter key is
optional — you can also add it later via the gateway admin UI.

```bash
# Required:
export ORG_ID="00000000-0000-0000-0000-000000000000"
export GATEWAY_DOMAIN="gateway.yourfirm.com"
export ADMIN_EMAIL="admin@yourfirm.com"

# Optional — leave blank to skip for now:
export OPENROUTER_API_KEY=""

# Infra knobs (sensible defaults):
export REGION="us-central1"
export ZONE="us-central1-a"
export VM_NAME="ic-gateway"
export MACHINE_TYPE="e2-small"      # 2 vCPU, 2 GB, ~$7/mo
```

Generate the secrets locally (they never leave Cloud Shell):

```bash
export GATEWAY_MASTER_KEY="$(openssl rand -base64 32)"
export LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)"
export PG_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
```

---

## Step 4 — Generate the cloud-init script

```bash
cat > /tmp/ic-gateway-cloud-init.yaml <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - gnupg
runcmd:
  - curl -fsSL https://get.docker.com | sh
  # cloud-init runs as root, so \$USER is unset at exec time. Hardcode
  # the default Ubuntu login user on GCE's ubuntu-2404-lts-amd64 image
  # so SSH-ing in later lets you run docker without sudo.
  - usermod -aG docker ubuntu || true
  - mkdir -p /opt/inchambers-gateway/caddy
  - curl -fsSL https://raw.githubusercontent.com/inchambers-ai/gateway-deploy/main/docker-compose.yaml -o /opt/inchambers-gateway/docker-compose.yaml
  - curl -fsSL https://raw.githubusercontent.com/inchambers-ai/gateway-deploy/main/caddy/Caddyfile       -o /opt/inchambers-gateway/caddy/Caddyfile
  - curl -fsSL https://raw.githubusercontent.com/inchambers-ai/gateway-deploy/main/caddy/Caddyfile.notls -o /opt/inchambers-gateway/caddy/Caddyfile.notls
  - |
    cat > /opt/inchambers-gateway/.env <<ENV
    GATEWAY_ORG_ID=${ORG_ID}
    GATEWAY_DOMAIN=${GATEWAY_DOMAIN}
    CADDY_TLS_MODE=auto
    CADDY_ACME_EMAIL=${ADMIN_EMAIL}
    ALLOWED_ORIGIN=https://app.inchambers.ai
    JWKS_URL=https://app.inchambers.ai/.well-known/jwks.json
    GATEWAY_MASTER_KEY=${GATEWAY_MASTER_KEY}
    LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
    OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
    PG_PASSWORD=${PG_PASSWORD}
    REGISTRY=ghcr.io/inchambers-ai
    IMAGE_TAG=latest
    ENV
  - chmod 600 /opt/inchambers-gateway/.env
  - cd /opt/inchambers-gateway && docker compose pull && docker compose up -d
EOF
```

<walkthrough-footnote>
The cloud-init file lives only in `/tmp` on this Cloud Shell session —
it's used once to bootstrap the VM and never uploaded anywhere else.
</walkthrough-footnote>

---

## Step 5 — Reserve a static external IP

A static IP survives VM restarts so your DNS record stays stable.

```bash
gcloud compute addresses create "${VM_NAME}-ip" --region="${REGION}"
export VM_IP="$(gcloud compute addresses describe ${VM_NAME}-ip --region=${REGION} --format='value(address)')"
echo "Static IP: ${VM_IP}"
```

---

## Step 6 — Open HTTP/HTTPS on the network firewall

```bash
gcloud compute firewall-rules create "${VM_NAME}-allow-https" \
  --network=default \
  --allow=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=ic-gateway || echo "already exists"
```

---

## Step 7 — Create the VM

```bash
gcloud compute instances create "${VM_NAME}" \
  --zone="${ZONE}" \
  --machine-type="${MACHINE_TYPE}" \
  --image-family="ubuntu-2404-lts-amd64" \
  --image-project="ubuntu-os-cloud" \
  --boot-disk-size=20GB \
  --boot-disk-type=pd-balanced \
  --tags="ic-gateway" \
  --address="${VM_IP}" \
  --metadata-from-file="user-data=/tmp/ic-gateway-cloud-init.yaml"
```

~60 seconds. Docker + the gateway stack take another ~2 minutes to start
inside the VM via cloud-init.

---

## Step 8 — Wait for the gateway to come up

```bash
until curl -fsS --max-time 3 "http://${VM_IP}/health" > /dev/null; do
  echo "waiting for gateway on ${VM_IP}…"
  sleep 5
done
echo ""
echo "✅ Gateway is reachable at http://${VM_IP}/health"
```

---

## Step 9 — Point DNS, then paste into inchambers.ai

1. Add an `A` record: **`${GATEWAY_DOMAIN}` → `${VM_IP}`** in your DNS
   provider.
2. Wait ~60 seconds for DNS propagation.
3. Open your inchambers.ai dashboard:
   <walkthrough-inline-feedback></walkthrough-inline-feedback>

   **Org Admin → Settings → AI Platform → Firm-hosted Gateway URL**

   Paste: `https://${GATEWAY_DOMAIN}`

4. Visit `https://${GATEWAY_DOMAIN}/admin/` and sign in with your
   inchambers.ai org-admin JWT to add ChatGPT Plus / Claude Pro cookies.

---

## Done

Your gateway is running. Commands to remember:

```bash
# SSH in to check logs / run docker compose commands:
gcloud compute ssh ${VM_NAME} --zone=${ZONE}

# Upgrade to a new gateway version:
gcloud compute ssh ${VM_NAME} --zone=${ZONE} \
  --command="cd /opt/inchambers-gateway && sudo docker compose pull && sudo docker compose up -d"

# Tear everything down:
gcloud compute instances delete ${VM_NAME} --zone=${ZONE} --quiet
gcloud compute addresses delete ${VM_NAME}-ip --region=${REGION} --quiet
gcloud compute firewall-rules delete ${VM_NAME}-allow-https --quiet
```

Questions? See the main docs at
<walkthrough-editor-open-file filePath="README.md">README.md</walkthrough-editor-open-file>.
