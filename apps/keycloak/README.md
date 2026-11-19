# Keycloak

This app installs Keycloak through a dedicated Argo CD Application. The
bootstrap ApplicationSet discovers `apps/keycloak/application.yaml` automatically.

## Deployment scope

This identity change requires a fresh installation. The code is not yet deployed.
Start with new `saas` and example tenant realms before onboarding organizations
or users. Upgrades of populated realms and migration procedures are outside
the scope of this change. Realm sync initializes the broker settings and
maintains Git-owned configuration after installation.

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

Use `--render` to print the initial manifests without applying them. This output
excludes the realm sync Jobs in `overlays/direct/jobs`. The script uses
the default profile and installs in the `maas-db` namespace. It reads the Route
host assigned by OpenShift and creates the `keycloak-public-url` ConfigMap. It
does not install or use Argo CD or ACM. It still requires the CloudNativePG
cluster, External Secrets, and cert-manager to be installed.
The direct installer creates namespace `maas-db` when it does not exist.
After Keycloak is ready, it runs the realm sync Jobs in order. A Job is a
Kubernetes task that runs to completion.

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

The Argo CD profiles do not create the `maas-db` namespace or a second
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
with AI Grid portal callbacks. In the Argo CD profiles, every five minutes it lists
`ManagedClusters` labelled `ai-grid/enabled=true` and
`ai-grid/role in (ingress,combined)`, derives each cluster's apps domain from
its `consoleurl.cluster.open-cluster-management.io` claim, and sets the client's
redirect URIs to:

- `https://maas.<cluster-apps-domain>/oauth2/callback` for each site.
- `http://localhost:8000/callback` for the browserless smoke test.

The direct profile reads the local Keycloak Route instead of listing
ManagedClusters. It registers `https://maas.apps.<cluster-apps-domain>/oauth2/callback`
and `http://localhost:8000/callback`. Here, `<cluster-apps-domain>` already starts
with `apps.`. The direct profile therefore registers an extra `apps.` prefix
compared with the standard MaaS portal hostname. It does not discover remote
ingress sites.

Both profiles replace the complete redirect list. In the Argo CD profiles,
removing a cluster's ingress or combined role removes its callback on the next run.
Nothing else changes these
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
| Built-in broker flow, profile mapper, and user-profile settings | Sets the unique-user step to `REQUIRED`, keeps the organization membership step, and applies the mapper and profile settings through the Admin API. |

Realm sync replaces the complete user-profile configuration with the file's
definition. Both broker imports retain the standard `email`, `firstName`, and
`lastName` fields from [Keycloak 26.8.0's default profile](https://github.com/keycloak/keycloak/blob/26.8.0/services/src/main/resources/org/keycloak/userprofile/config/keycloak-default-user-profile.json).
These fields retain their user permissions, required rules, and validators.
Only `username` receives admin-only permissions and an explicit required rule.
The configuration also allows administrators to manage custom user attributes
through `unmanagedAttributePolicy: ADMIN_EDIT`. This matches the standard profile
used by the backend's identity isolation tests.

If you need additional profile definitions, add them to both broker imports
before reconciliation. Realm sync removes definitions omitted from Git.

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
- Components other than the declarative user profile, such as the signing key provider. A realm
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

`overlays/direct` leaves both hooks out of its first apply because `kubectl`
does not order them with the Keycloak rollout. `install.sh` runs the same Jobs
after Keycloak is ready. For later Git edits to `saas`, rerun `apps/keycloak/install.sh`.
Each run replaces both Jobs and waits for them in order. The reconciliation
rules and exclusions above also apply to direct installs.

## Example Tenant Identity Providers

`grid-tenant-1-idp` and `grid-tenant-2-idp` stand in for organizations' own
identity providers, which AI Grid never manages: in production that is the
organization's Keycloak, Okta, Entra ID or similar
([docs/organization-identity-providers](../../docs/organization-identity-providers/README.md)). Each realm's `saas-broker`
client sends what any such provider must send in the ID token
(ODH-ADR-MS-0007), from what the realm's admin manages:

| Claim | From |
| --- | --- |
| `groups` | The user's groups (Group Membership mapper, group names without their path). |
| `roles` | The user's roles of the `saas-broker` client: `admins` or `users`. |

No claim value is a user attribute. `saas`'s identity provider mappers copy the
two claims on every sign-in (sync mode Force), so a change takes effect at the
user's next sign-in.

Each example tenant's `saas-broker` client links the standard `profile` and
`email` client scopes. The broker's upstream authorization request therefore
accepts `openid profile email`.

The `saas` broker gives each new imported user a generated local username.
The username mapper uses `${UUID}`, target `LOCAL`, and sync mode `IMPORT`.
Existing accounts keep their local usernames and broker links on later sign-ins.
That local username is only a storage handle. A subject is an account identifier
within its issuer. The broker's `iss` and `sub` pair identifies the platform user.
The upstream `preferred_username` is copied into
`maas_preferred_username`. The built-in `profile` scope username mapper reads
that attribute and emits `preferred_username`. Users without that attribute,
including service accounts, do not get this claim. The built-in first broker
login flow creates a unique local account and adds the user to the linked
organization. Realm sync sets its `idp-create-user-if-unique` step to
`REQUIRED`, so Keycloak stops sign-in when a local account already matches the
upstream email or username. The user can link the accounts later through
Keycloak Account management.

The display label is optional. The generated username and broker
`sub` are separate values. The legacy `x-maas-username` header carries `sub`.

`grid-tenant-2-idp` contains `alice`, `bob`, and `carol`. Alice in
`grid-tenant-1-idp` and Alice in `grid-tenant-2-idp` use the same external
username but remain two different broker subjects. Bob is the only member of
group `ai-grid-bob`; the tenant-2 MaaS subscription and auth policy select that
qualified group. Bob's access therefore survives the use of a generated local
username. See [organization identity providers](../../docs/organization-identity-providers/README.md)
for the coordinated backend behavior and realm sync prerequisites.

| Realm | User | Groups | Roles | Administers the realm |
| --- | --- | --- | --- | --- |
| `grid-tenant-1-idp` | `alice` | `ai-grid-admins`, `ai-grid-users` | `admins` | yes |
| `grid-tenant-2-idp` | `alice` | `ai-grid-users` | `users` | no |
| `grid-tenant-2-idp` | `bob` | `ai-grid-users`, `ai-grid-bob` | `users` | no |
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

Keycloak imports these example realms only when they do not exist. A fresh
installation includes tenant-2 Alice, Bob's `ai-grid-bob` membership, and the
`profile` and `email` client scopes. A later file edit does not update an
existing example realm. This change provides no upgrade procedure for older
example realms.

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
`apps/keycloak/tests/redirect-uris-test.sh`. Also run these offline tests:

```sh
apps/keycloak/tests/direct-install-test.sh
uv run --with pyyaml python apps/keycloak/tests/identity-contract-test.py
uv run python apps/keycloak/tests/identity-smoke-inputs-test.py
```

The Keycloak database inherits the availability and storage characteristics of
the existing `maas-db` CloudNativePG cluster. Database backups remain the
responsibility of that shared database app.

The stable realm signing keys depend on the cluster-wide cert-manager
installation.
