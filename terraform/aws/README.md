# Terraform AWS — inchambers-gateway

Deploys the gateway to AWS Fargate with RDS Postgres, ElastiCache Redis, ECR, Secrets Manager, and an ALB.

## Quickstart

```bash
cd gateway/deploy/terraform/aws
terraform init

MASTER_KEY=$(openssl rand -base64 32)
PG_PASSWORD=$(openssl rand -base64 24)

terraform apply \
  -var name=acme-firm \
  -var org_id=<your-inchambers-org-uuid> \
  -var gateway_master_key="$MASTER_KEY" \
  -var pg_admin_password="$PG_PASSWORD" \
  -var openrouter_api_key=sk-or-v1-... \
  -var domain_name=gateway.acme-firm.com \
  -var hosted_zone_id=Z0123456789ABCDEFGHIJ
```

Outputs:

- `gateway_url` — paste into **inchambers.ai org admin → AI Platform → Gateway URL**
- `ecr_relay_repo`, `ecr_litellm_repo` — push image targets

## Build + push images

```bash
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account -o tsv)
AWS_REGION=$(terraform output -raw region || echo us-east-1)
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

for svc in relay litellm admin-ui caddy; do
  case $svc in
    admin-ui) ctx=./gateway/admin-ui ;;
    caddy)    ctx=./gateway/caddy ;;
    *)        ctx=./gateway/services/$svc ;;
  esac
  docker build -t $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/ic-gateway-$svc:latest $ctx
  docker push    $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/ic-gateway-$svc:latest
done

# Force redeploy
for svc in acme-firm-relay acme-firm-litellm acme-firm-admin acme-firm-caddy; do
  aws ecs update-service --cluster acme-firm-cluster --service $svc --force-new-deployment
done
```

## Cost estimate (us-east-1, low utilization)

| Resource | Monthly |
|---|---|
| Fargate (4 tasks × 0.5 vCPU × 1 GB avg) | ~$35 |
| RDS t4g.micro + 20 GB gp3 | ~$15 |
| ElastiCache t4g.micro | ~$12 |
| ALB | ~$18 (base) |
| NAT Gateway | ~$35 |
| Secrets Manager (4 secrets) | ~$2 |
| CloudWatch Logs | ~$3 |
| **Total** | **~$120/month** |

Pricier than Azure Container Apps because of the NAT + ALB base costs. For smaller firms, the Bicep template is usually the better fit.

## Custom domain + Route 53

Only works if you already have a Route 53 hosted zone. Pass `-var hosted_zone_id=...` and the module will:

1. Create an ACM cert with DNS validation
2. Create the validation CNAME automatically
3. Create an A record pointing to the ALB
4. Attach an HTTPS listener on the ALB with that cert

## Without a custom domain

Leave `domain_name` empty and `terraform apply` — the ALB gives you a default hostname like `acme-firm-alb-123456.us-east-1.elb.amazonaws.com`. HTTP only (no cert). Fine for staging; production should use a real domain.
