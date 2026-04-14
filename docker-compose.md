# docker-compose — inchambers-gateway

Single-VM deployment for the smallest firms or on-prem boxes. Runs all
four services locally with ephemeral Postgres + Redis, Caddy fronting
everything with TLS.

## Quickstart

```bash
cd gateway/deploy/docker-compose
cp .env.example .env
# Edit .env — at minimum set:
#   GATEWAY_ORG_ID, GATEWAY_MASTER_KEY, LITELLM_MASTER_KEY, OPENROUTER_API_KEY
docker compose up -d
```

The compose file at `gateway/compose.yaml` (one level up) builds images
from source — that's the dev path. This deployment compose pulls from a
container registry, which is what firms should actually use in
production. Point `REGISTRY` at where your CI pushes the images.

## What runs

| Container | Port (host) | Notes |
|---|---|---|
| `caddy` | 80, 443 | TLS terminates here; ACME via GATEWAY_DOMAIN |
| `relay` | — | Rust HTTP service on 8081 (internal) |
| `litellm` | — | Python service on 4000 (internal) |
| `admin-ui` | — | nginx static on 3000 (internal) |
| `postgres` | — | Bundled Postgres 16 for the relay's schema |
| `redis` | — | Bundled Redis 7 for rate limiter |

Bundled Postgres/Redis are fine for small firms. For resilience, replace
with managed services (e.g., AWS RDS + ElastiCache) and point
`DATABASE_URL` / `REDIS_URL` at them — then remove the `postgres` and
`redis` services from the file.

## Updating

```bash
docker compose pull
docker compose up -d
```

Migrations run automatically on relay startup via `sqlx::migrate!`.

## TLS

`GATEWAY_DOMAIN` must be a real hostname pointed at this box for ACME to
work. Set `CADDY_TLS_MODE=internal` if you want Caddy to use its own CA
(fine for LAN-only deployments).
