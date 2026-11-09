# Keycloak

This app migrates the Keycloak component from
`lphiri/maas-portal-integration-poc` into a dedicated Argo CD Application. The
bootstrap ApplicationSet discovers `apps/keycloak/application.yaml` automatically.

## Install profiles

The app has two profiles. Each profile is a kustomize overlay.

- `overlays/default` installs Keycloak and the example realms. It adds the
  `grid-tenant-1-idp` and `grid-tenant-2-idp` realms, the example identity
  providers and organizations in the `saas` realm, and the two example signing
  keys. This is the default.
- `overlays/core` installs Keycloak and only the `saas` broker realm. The core
  realm has the broker client and its signing key. It has no identity
  providers, organizations, or example tenants.

The `saas` broker mints `org_id` from the identity provider binding. The token
carries flat `org_id`, `org_name`, and `roles` claims and plain `groups`.

To install only the core realm, set the keycloak Application source path to
`apps/keycloak/overlays/core`. The default path is
`apps/keycloak/overlays/default`.

## Direct install

For a cluster without Argo CD, run:

```sh
apps/keycloak/install.sh
```

Use `--render` to print the manifests without applying them. The script uses
the default profile and installs in the `maas-db` namespace. It reads the Route
host assigned by OpenShift and creates the `keycloak-public-url` ConfigMap. It
does not install or use Argo CD or ACM. It still requires the CloudNativePG
cluster, External Secrets, and cert-manager to be installed.
The direct installer creates namespace `maas-db` when it does not exist.

## Topology

- Keycloak runs in `maas-db` on the GitOps hub cluster, while remaining a
  separate Argo CD Application from `maas-db`.
- The app reuses the healthy `maas-db` CloudNativePG cluster. Its
  `DatabaseRole` and `Database` resources create a dedicated `keycloak` role
  and database without sharing credentials with the API database user.
- Keycloak connects to `maas-db-rw` with TLS and verifies the server against
  the existing `maas-db-ca` Secret.
- The default install imports the core `saas` broker realm and the example
  `grid-tenant-1-idp` and `grid-tenant-2-idp` realms, each when it does not
  exist. The `core` overlay excludes the examples. See
  [Realm Imports and Git Edits](#realm-imports-and-git-edits) and
  [Example Tenant Identity Providers](#example-tenant-identity-providers).
- The upstream example `AITenant` resource is intentionally not applied by this
  app; the tenant-facing application should own its consumer configuration.

The app intentionally does not create the `maas-db` namespace or a second
PostgreSQL cluster. It can initially report missing namespace or resource
errors until the `maas-db` Application has created the namespace and installed
the CloudNativePG CRDs. Its retry policy refreshes and retries automatically.

## Generated Secrets

Git does not store Keycloak, client, broker, test-user, or database secret
values. The app depends on the `external-secrets` Application and uses Password
generators to create these Secrets in `maas-db`:

- `keycloak-db` holds the dedicated PostgreSQL role credentials consumed by
  CloudNativePG and Keycloak.
- `keycloak-secrets` holds Keycloak bootstrap, client, broker, and test-user
  values.
- `keycloak-redirect-uris-secret` and `keycloak-realm-sync-secret` hold the
  client secrets of the `saas` realm's `keycloak-redirect-uris` and
  `keycloak-realm-sync` service accounts.

The `ExternalSecret` resources use `refreshPolicy: CreatedOnce` and
`refreshInterval: 0s`, so each value is generated once and is not rotated by
the controller. Password generators are stateless, so any refresh would replace
every generated value: the bootstrap admin's password, which Keycloak applies
only when it first creates the master realm, would stop matching the admin, and
a realm that isn't re-imported on start would keep the old client and broker
secrets. `keycloak-secrets` uses `mergePolicy: Merge`, so
template keys and the generator-backed `dataFrom` keys coexist. To change its
template on a running cluster, delete Secret `keycloak-secrets` once so it's
generated again. Their deletion policy retains the generated Secrets if the
Keycloak app is removed. The Keycloak app may initially report missing resource
errors until the External Secrets CRDs are installed; its retry policy
refreshes and retries automatically.

The Keycloak admin username and non-secret client configuration are declared in
the `keycloak-secrets` ExternalSecret template. To retrieve a generated value
for operational use, read it from the corresponding Kubernetes Secret through
the cluster's approved secret-access process.

## Dynamic Public URL

The `keycloak` Route omits `spec.host`, so OpenShift assigns the public host
from the cluster's ingress domain. An ACM Policy uses a hub-template Route
lookup to render that assigned host into the `keycloak-public-url` ConfigMap on
the hub, the one cluster the dedicated `keycloak-public-url-clusters`
Placement selects (ACM's `local-cluster=true` label). The Deployment consumes the ConfigMap for
`KEYCLOAK_PUBLIC_URL` and `KC_HOSTNAME`, so no cluster-specific URL is stored
in Git.

The Placement selects the existing `global` ManagedClusterSet. The `maas-db`
Application already binds that cluster set in the shared `maas-db` namespace,
which this app depends on for its database.

Removing an explicit host from an existing Route can change the assigned public
URL. Plan the corresponding Keycloak realm and client update before relying on
the new issuer: the realms already exist in PostgreSQL. `saas` keeps its
identity providers' URLs until `keycloak-saas-realm-sync` next runs, on the
Application's next sync; the example tenant realms keep their client's redirect
URIs until they are imported again (see
[Example Tenant Identity Providers](#example-tenant-identity-providers)).

## Consumer Portal Redirects

The `keycloak-redirect-uris` CronJob keeps the `tenant-demo` client aligned
with active AI Grid ingress sites. Every five minutes it lists
`ManagedClusters` labelled `ai-grid/enabled=true` and
`ai-grid/role in (ingress,combined)`, derives each cluster's apps domain from
its `consoleurl.cluster.open-cluster-management.io` claim, and sets the client's
redirect URIs to:

- `https://maas.<cluster-apps-domain>/oauth2/callback` for each site.
- `http://localhost:8000/callback` for the browserless smoke test.

The job replaces the complete redirect list, so removing a cluster's ingress or
combined role removes its callback on the next run. Nothing else changes these
redirect URIs: a Keycloak restart doesn't re-import the existing `saas` realm,
and `keycloak-saas-realm-sync` keeps the client's live redirect URIs. Only a
new `saas` realm starts with the smoke-test redirect alone, until the first
CronJob run.

The updater authenticates with the realm-scoped `keycloak-redirect-uris`
service account, whose generated client secret is stored in the dedicated
`keycloak-redirect-uris-secret` Secret. It has only the `saas` realm's client
view and manage permissions.

## Stable Signing Keys

Each realm uses a dedicated cert-manager-managed RSA signing key. cert-manager
creates a JKS keystore for each realm and reuses the same private key across
certificate renewals. The realm import references the mounted JKS file and a
fixed `kid`, so Keycloak restarts do not invalidate previously issued tokens.

The signing keystores are generated in the `maas-db` namespace and are not
stored in Git. The JKS password is generated by External Secrets and is shared
by the three realm-specific keystores.

Realm imports replace `${KEYCLOAK_PUBLIC_URL}` with the value from the
public-URL ConfigMap and the broker/client/test-user keys with values from the
Keycloak Secrets (`base/manifests/scripts/render-realm.sh`). A placeholder a
file holds needs its value; one it doesn't hold needs none.

## Realm Imports and Git Edits

The `render-realm-import` init container renders the realm files of
`keycloak-realm-import`, and the Keycloak container imports them with
`kc.sh import --override false` before `kc.sh start`: each realm is created on
the first start only, and a restart, node drain or eviction leaves it as it is.
Every realm holds runtime data:

- `saas` (base, or the examples component's `saas-realm.json`): the console
  backend's user (`apps/console/create-secrets.sh`), the organizations the
  console creates with their identity providers, and brokered users.
- `grid-tenant-1-idp` and `grid-tenant-2-idp` (examples component only): the
  users, groups and roles their organization's admin manages. The `core`
  overlay has none.

A new pod imports nothing that exists, so the Deployment rolls without a gap.

An edit to `saas-realm.json` reaches an existing realm through two Argo CD
PostSync hooks, which run in sync-wave order after every sync of this
Application (a change under `apps/keycloak`, or a self-heal), once the
Keycloak Deployment is healthy:

1. `keycloak-realm-sync-bootstrap` checks that the `keycloak-realm-sync`
   client signs in and that its service account holds the roles the file gives
   it. If so it exits without signing in as anyone else. If not (a realm
   imported before the client was in the file, or a client secret generated
   again), it signs in to `master` as the bootstrap admin and creates or
   repairs that client and its roles, nothing else.
2. `keycloak-saas-realm-sync` renders the file with the same script, signs in
   as `keycloak-realm-sync`, and runs
   `base/manifests/scripts/sync-saas-realm.py sync`, which deletes and
   re-creates nothing:

| In `saas-realm.json` | What the sync does |
| --- | --- |
| Realm settings: the top-level values that aren't lists or objects (`accessTokenLifespan`, `ssoSessionIdleTimeout`, `loginWithEmailAllowed`, `organizationsEnabled`, `enabled`) | Applies them with a realm update that carries no sub-resources. |
| Clients, identity providers, identity provider mappers, users, groups and roles the realm lacks | Adds them with a partial import (`ifResourceExists: SKIP`). |
| Clients the realm has | Updates each in place, on top of the live client: same id, so its sessions stay. Its protocol mappers become the file's, so a mapper removed from the file is deleted; client scopes the file lists are added. The `tenant-demo` client's redirect URIs stay as the CronJob set them. |
| Identity providers and identity provider mappers the realm has | Updates each in place: same id, so organization links and brokered users' links stay. Config keys the file doesn't set stay. |
| Identity provider mappers | Deletes the mappers of the file's identity providers that the file doesn't have. Identity providers the file doesn't have, such as the console's organizations', keep all of theirs. |
| Service-account users | Grants the roles the file gives them. |

A partial import with `ifResourceExists: OVERWRITE` isn't used: it deletes and
re-creates each existing client and identity provider, which gives them new
ids, ends the clients' sessions and drops the identity providers' organization
links.

These are not reconciled; plan them as a change of their own:

- Removals, apart from client protocol mappers and the file's identity
  providers' mappers. A client, identity provider, user, group, role, client
  scope or role mapping removed from the file stays in the realm; delete it
  through the admin console or API as well. The sync can't tell an identity
  provider removed from the file from one the console created.
- Organizations, including the `grid-tenant-1` and `grid-tenant-2` examples, and
  their domains: they are created with the realm only.
- Components: the realm's signing key provider and its user profile. A realm
  created before the file had the `saas-signing` key provider keeps the keys
  Keycloak generated for it.
- Users, groups and roles that already exist, apart from the roles of service
  accounts.
- Realm settings that are lists or objects, such as `attributes`.

### Credentials

Each hook mounts no Kubernetes ServiceAccount token and gets its values as
single Secret keys, never a whole Secret:

- `keycloak-realm-sync-bootstrap` gets `KC_BOOTSTRAP_ADMIN_USERNAME` and
  `KC_BOOTSTRAP_ADMIN_PASSWORD` from `keycloak-secrets`, and
  `KEYCLOAK_REALM_SYNC_CLIENT_SECRET` to check the client. It reads only the
  `keycloak-realm-sync` client and its service account from the unrendered
  realm file.
- `keycloak-saas-realm-sync` gets the values of the `saas` realm file's
  placeholders (the `core` file's, plus the examples component's identity
  provider URLs and broker secrets) and `KEYCLOAK_REALM_SYNC_CLIENT_SECRET`,
  and no admin credential. It writes the rendered file to a memory-backed
  volume.

`keycloak-realm-sync`'s generated client secret is in the
`keycloak-realm-sync-secret` Secret. Its service account has the `saas`
realm's `manage-realm` (the realm update and the partial import),
`manage-clients`, `manage-identity-providers` and `manage-users` (service
accounts' role mappings) roles, and nothing outside `saas`. If a hook fails,
the sync fails and the Application's retry policy runs it again; the failed Job
stays for its logs until the next sync replaces it.

`overlays/direct` (`install.sh`, without Argo CD) leaves both hooks out:
`kubectl apply` would start them in no order and couldn't update them later.
A direct install imports `saas` on the first start; apply later edits to it
with a planned export/import or the admin API.

## Example Tenant Identity Providers

`grid-tenant-1-idp` and `grid-tenant-2-idp` stand in for organizations' own
identity providers, which AI Grid never manages: in production that is the
organization's Keycloak, Okta, Entra ID or similar. Each realm's `saas-broker`
client sends what any such provider must send in the ID token
(ODH-ADR-MS-0007), from what the realm's admin manages:

| Claim | From |
| --- | --- |
| `groups` | The user's groups (Group Membership mapper, group names without their path). |
| `roles` | The user's roles of the `saas-broker` client: `admins` or `users`. |

No claim value is a user attribute. `saas`'s identity provider mappers copy the
two claims on every sign-in (sync mode Force), so a change takes effect at the
user's next sign-in.

| Realm | User | Groups | Roles | Administers the realm |
| --- | --- | --- | --- | --- |
| `grid-tenant-1-idp` | `alice` | `ai-grid-admins`, `ai-grid-users` | `admins` | yes |
| `grid-tenant-2-idp` | `bob` | `ai-grid-users` | `users` | no |
| `grid-tenant-2-idp` | `carol` | | `admins` | yes |

Each organization's admin holds the realm's `realm-management` roles
`view-users`, `query-users`, `query-groups`, `query-clients` and
`manage-users`, and nothing more. In the realm's admin console,
`<KEYCLOAK_PUBLIC_URL>/admin/<realm>/console/`, they create and delete users,
manage group membership, and grant or remove the `saas-broker` roles. They can
also grant these same roles to another user, who then administers the realm
too; they can't change the realm, its clients or their secrets. A
subscription in the provider console is granted to group names, such as
`ai-grid-users`.

Every user in the files has a fixed `id`: it is the `sub` that `saas` links
the user's brokered account to.

Keycloak imports these realms once, so an edit to their files doesn't reach a
hub where they exist. To apply one on a test hub, delete the realm (realm
settings, Action, Delete) and restart Keycloak
(`kubectl rollout restart deployment/keycloak -n maas-db`): the realm is
imported again from Git, and the users in the files keep their ids, so their
links in `saas` stay. Anything the realm's admin created in it is lost.

On a hub whose tenant realms were imported before their users had fixed ids,
those users get new ids at that import, and each one's link in `saas` still
points at the old id: their next sign-in stops at "Account already exists".
For each of them, in realm `saas`: Users, the user, Identity provider links,
unlink `grid-tenant-*`, then link it again with the user id from the realm file
and the same username. Deleting the link alone isn't enough: the next sign-in
then finds the existing `saas` user by email and asks for a password a brokered
user doesn't have.

## Validation

```sh
kubectl get applications.argoproj.io -n openshift-gitops
kubectl get externalsecrets -n maas-db
kubectl get databaseroles,databases -n maas-db
kubectl rollout status deployment/keycloak -n maas-db
kubectl get route keycloak -n maas-db
kubectl get configmap keycloak-public-url -n maas-db
# The last sync, PostSync hooks included, and a hook's log while it runs or after it failed:
kubectl get applications.argoproj.io keycloak -n openshift-gitops -o jsonpath='{.status.operationState.phase}{"\n"}'
kubectl logs job/keycloak-realm-sync-bootstrap -n maas-db
kubectl logs job/keycloak-saas-realm-sync -n maas-db
```

Offline checks: `apps/keycloak/tests/realm-import-test.sh` and
`apps/keycloak/tests/redirect-uris-test.sh`.

The Keycloak database inherits the availability and storage characteristics of
the existing `maas-db` CloudNativePG cluster. Database backups remain the
responsibility of that shared database app.

The stable realm signing keys depend on the cluster-wide cert-manager
installation.
