# Helm — inchambers-gateway

Kubernetes install via Helm. Runs all four services as Deployments, Caddy
exposed as LoadBalancer (or behind your Ingress controller).

## Quickstart

```bash
helm install acme-firm ./gateway/deploy/helm \
  --namespace ic-gateway --create-namespace \
  --set orgId=<your-inchambers-org-uuid> \
  --set gatewayDomain=gateway.acme-firm.com \
  --set secret.gatewayMasterKey=$(openssl rand -base64 32) \
  --set secret.litellmMasterKey="sk-$(openssl rand -hex 24)" \
  --set secret.openRouterApiKey=sk-or-v1-... \
  --set externalDatabase.url='postgres://user:pass@rds-host:5432/gateway?sslmode=require' \
  --set externalRedis.url='redis://redis-host:6379/0'
```

The chart deliberately disables its bundled Postgres/Redis subcharts —
production deployments should point at managed services (RDS, Cloud SQL,
Azure Database for Postgres, ElastiCache, Memorystore, Azure Cache for
Redis) via `externalDatabase.url` and `externalRedis.url`.

## Ingress

Two modes:

1. **Caddy-exposed (default)** — Caddy runs as `type: LoadBalancer`,
   handles TLS via its internal CA (add your own cert for production,
   or set `gatewayDomain` to a real hostname and Caddy will ACME-issue).
2. **Ingress controller** — set `ingress.enabled=true` + provide
   `ingress.className` (nginx, traefik, …). Caddy falls back to
   ClusterIP; TLS terminates at the Ingress.

## Secrets via external-secrets

Leave `secret.create=false` and point at a pre-existing Secret:

```bash
helm install … --set secret.create=false --set secret.existingName=ic-gateway-secrets
```

Populate the referenced Secret with keys `gateway-master-key`,
`litellm-master-key`, optionally `openrouter-api-key`,
`azure-foundry-key`, `pg-password`. External Secrets Operator /
Sealed Secrets both work.

## What this does not include

- Managed Postgres/Redis subcharts (intentionally off — use managed services)
- Cert-manager — point your Ingress annotations at it if you need ACME
- HPA — add `autoscaling/v2 HorizontalPodAutoscaler` per-service if you
  expect concurrent load spikes; default is fixed replicas
