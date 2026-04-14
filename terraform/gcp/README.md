# Terraform GCP — inchambers-gateway

Deploys the gateway to GCP Cloud Run with Cloud SQL Postgres, Memorystore
Redis, Artifact Registry, Secret Manager.

## Quickstart

```bash
cd gateway/deploy/terraform/gcp
terraform init

MASTER_KEY=$(openssl rand -base64 32)
PG_PASSWORD=$(openssl rand -base64 24)

terraform apply \
  -var project_id=my-firm-gcp \
  -var name=acme-firm \
  -var org_id=<inchambers-org-uuid> \
  -var gateway_master_key="$MASTER_KEY" \
  -var pg_admin_password="$PG_PASSWORD" \
  -var openrouter_api_key=sk-or-v1-...
```

Outputs:

- `gateway_url` — Cloud Run URL for Caddy; paste into inchambers.ai org admin.
- `artifact_registry_url` — push images here.

## Build + push images

```bash
REGION=$(terraform output -raw region 2>/dev/null || echo us-central1)
REPO=$(terraform output -raw artifact_registry_url)

gcloud auth configure-docker ${REGION}-docker.pkg.dev

for svc in relay litellm admin-ui caddy; do
  case $svc in
    admin-ui) ctx=./gateway/admin-ui ;;
    caddy)    ctx=./gateway/caddy ;;
    *)        ctx=./gateway/services/$svc ;;
  esac
  docker build -t $REPO/ic-gateway-$svc:latest $ctx
  docker push    $REPO/ic-gateway-$svc:latest
done

# Force new revision with fresh image
for svc in acme-firm-relay acme-firm-litellm acme-firm-admin acme-firm-caddy; do
  gcloud run services update $svc --region=$REGION --platform=managed
done
```

## Cost estimate (us-central1, low utilization)

| Resource | Monthly |
|---|---|
| Cloud Run (4 services, min 0–1 replica) | ~$5–15 |
| Cloud SQL db-f1-micro | ~$10 |
| Memorystore Redis 1 GB | ~$35 |
| Artifact Registry | ~$0.10 |
| Secret Manager | ~$0.30 |
| VPC connector | ~$10 |
| **Total** | **~$60–70/month** |

Cheaper than AWS Fargate; slightly more than Azure Container Apps because Memorystore has a fixed minimum. Fine for firms already running GCP.
