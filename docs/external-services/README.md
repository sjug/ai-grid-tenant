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
| OIDC provider | The `issuerUrl` in the tenant Policy, [apps/rhoai/hub/02-ingress-clusters-policy.yaml](../../../apps/rhoai/hub/02-ingress-clusters-policy.yaml) | The issuer URL, a client ID and an audience |
| Redis | Secret `kuadrant-system/limitador-redis`, key `URL`, which `Limitador/limitador` references | A `redis://` URL |

The tenant Policy also copies the Keycloak client secret into
`models-as-a-service/tenant-demo-oidc-client` and references it from
`AITenant.spec.oidc.clientSecretRef` so the consumer portal auth proxy can use
the same OIDC client as the API.

The MaaS Gateway listener hostname is `maas.<cluster-ingress-domain>`, where
the ingress domain starts with `apps.`. `apps/rhoai/values.yaml` owns the
`maas` prefix, and a target-cluster ConfigurationPolicy appends the cluster's
ingress domain to both listeners.
The Keycloak app runs a CronJob that lists active ingress and combined
ManagedClusters, derives the same domain from each cluster's console claim, and
reconciles `tenant-demo` to exactly those `https://.../oauth2/callback` URIs
plus `http://localhost:8000/callback`.

## Current limits

The demo Keycloak and Gateway hostnames are policy-driven. Policies write the
database Secret and the Redis Secret, and the tenant Policy finds Keycloak on
the labelled cluster or the hub. Using your own services means changing those
Policies. Nothing here has run against user-owned services.
