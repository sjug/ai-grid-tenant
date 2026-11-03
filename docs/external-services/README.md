# MaaS external services

MaaS depends on a database, an OIDC provider and a Redis. In production the user owns and operates these. This repository installs stand-ins for demos only.

## Demo install

Label one cluster `ai-grid/external-services=true`. [apps/external-services](../../../apps/external-services/README.md) then installs these on it:

| Service | Demo stand-in |
|---|---|
| Database | PostgreSQL through CloudNativePG, `maas-db` |
| OIDC provider | Keycloak |
| Redis for Limitador | `limitador-redis` |
| Secret delivery | External Secrets Operator |

These are not supported for production. They have no backup, sizing or upgrade plan here.

## What MaaS needs

| Service | Where MaaS reads it | Value |
|---|---|---|
| Database | Secret `redhat-ai-gateway-infra/maas-db-config` | `DB_CONNECTION_URL` and `DB_READ_CONNECTION_URL`, PostgreSQL URLs with `sslmode=require` |
| OIDC provider | The `issuerUrl` in the tenant Policy, [apps/rhoai/hub/02-tenant-policy.yaml](../../../apps/rhoai/hub/02-tenant-policy.yaml) | The issuer URL, a client ID and an audience |
| Redis | Secret `kuadrant-system/limitador-redis`, key `URL`, which `Limitador/limitador` references | A `redis://` URL |

## Current limits

None of these has a setting yet. Policies write the database Secret and the Redis Secret, and the tenant Policy finds Keycloak on the labelled cluster or the hub. Using your own services means changing those Policies. Nothing here has run against user-owned services.
