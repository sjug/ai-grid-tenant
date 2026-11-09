# External services

A dedicated hub runs MaaS state itself. This app is the alternative, where one
site holds it instead: the cluster labelled `ai-grid/external-services=true`. These services are demo stand-ins for
ones the user owns in production. See
[external services](../../docs/external-services/README.md).

```sh
oc label managedcluster site-a ai-grid/external-services=true
```

The `external-services` ApplicationSet installs these on it, reusing each app's
manifests:

| Component | From |
|---|---|
| External Secrets Operator | `apps/external-secrets/manifests` |
| `maas-db` primary | `apps/maas-db/primary`, without its ServiceExport |
| Keycloak | `apps/keycloak`, without the hub's public-URL Policy |
| Limitador's Redis | `apps/limitador-redis/manifests`, without its ServiceExport |

The hub Policies here give this cluster its Keycloak public URL and `maas-api`'s
database connection, both read from this cluster's own Route and Secrets. The
tenant Policy (`apps/rhoai/hub`) finds Keycloak on this cluster through its
console-URL cluster claim.

The label selects this cluster through Argo CD's cluster Secret, which ACM never
removes a label from, and the ApplicationSet preserves what it installed, so
removing the label deletes nothing. Moving this cluster means moving its database.

Label one cluster, normally also an AI Grid site with role `ingress` or
`combined`. Other ingress sites don't get a read replica or database
credentials yet: both are copied from Secrets on the hub, where a dedicated
hub has none.
