# Provider console

The cloud provider's admin console,
[ai-grid-cloud/ai-grid-provider-console](https://github.com/ai-grid-cloud/ai-grid-provider-console),
on the hub, installed from its Helm chart: one pod with kube-auth-proxy
(OpenShift sign-in), the console, and its backend
([ai-grid-cloud/ai-grid-provider-backend](https://github.com/ai-grid-cloud/ai-grid-provider-backend)).

- **Clusters:** lists the ManagedClusters, each Provisioning or Provisioned
  from Policy `ai-grid-ready` (`apps/ai-grid-policies`), which
  `manifests/ai-grid-ready-reader.yaml` lets the backend read. Add to AI Grid
  and Remove set the `ai-grid/*` and `location` labels; the chart's
  ValidatingAdmissionPolicy stops the backend from changing anything else on a
  ManagedCluster. In this repository nothing reads those labels yet, so Add and
  Remove install and uninstall nothing.
- **Organizations:** Keycloak Organizations in realm `saas`, through a
  Keycloak user of its own with only the realm-management roles that needs
  (`view-users`, `query-users`, `view-realm`, `manage-realm`).
- **GPUs:** each spoke's GPUs from ACM Search. `manifests/search-rbac.yaml`
  binds the backend to ACM's `global-search-user`, which lets it read every
  managed cluster's indexed resources: more than the GPU nodes it asks for, so
  the backend stays behind the console's sign-in (the file says why).
- **Models and subscriptions:** commits to the catalog repository,
  [ai-grid-cloud/ai-grid-1-catalog](https://github.com/ai-grid-cloud/ai-grid-1-catalog),
  which `apps/acm-models` delivers and `apps/ai-grid-policies` reports on.
  That URL is the one value another environment changes, here
  (`backend.git.url`) and in `apps/acm-models/hub/catalog-*`.

## Before the first sync completes

The pod doesn't start until three Secrets exist in namespace `ai-grid-provider-console`, and
nobody can sign in without an OAuthClient. None of them is in git. After Argo
CD has created the console's Route, a hub cluster-admin runs:

```sh
AI_GRID_GIT_TOKEN_FILE=/path/to/token-file apps/console/create-secrets.sh
```

`AI_GRID_GIT_TOKEN_FILE` is a file holding a fine-grained GitHub token with
`contents: write` on the catalog repository and nothing else. The script
creates or updates, keeping existing values:

- `ai-grid-provider-console-oauth` and OAuthClient `ai-grid-provider-console`:
  OpenShift sign-in, redirecting to the Route's `/oauth2/callback`.
- `ai-grid-backend-keycloak`: the backend's Keycloak URL, realm, user,
  password and the user's id. The script creates that user in realm `saas`,
  signing in to Keycloak's master realm with the admin login in
  `maas-db/keycloak-secrets`. On a rerun it trusts only the user whose id this
  Secret records and that has no brokered identity, so a tenant who signs in
  first under the same username doesn't get its roles. A user made by an older
  version of the script has no recorded id: the script stops and prints the
  id, and you rerun it with `ADOPT_KEYCLOAK_USER_ID=<that id>` once you've
  checked it's the console's.
- The user has a random email, `ai-grid-console-backend+<32 hex>@console.invalid`,
  verified, with no required actions, because a realm can require an email
  before it issues tokens. It's random because a tenant's IdP can claim any
  email, and a first-login flow may link a brokered login to an existing
  account by email. Nobody outside the hub knows this one. A service-account
  client would remove brokered login from the picture entirely; the backend
  signs in with a username and password today.
- `ai-grid-backend-git`: the catalog token, mounted into the backend as a file.

On a cluster whose ingress certificate is not publicly trusted (a self-managed
bare metal cluster, unlike the lab's OSD), run the script with `CURL_CA_BUNDLE`
pointing at the cluster's ingress CA, and set `KEYCLOAK_BACKEND_URL` to
Keycloak's in-cluster Service, `http://keycloak.maas-db.svc:8080`, so the
backend's admin API calls need no TLS trust. Keycloak's issued URLs stay public
because its hostname is fixed by `KC_HOSTNAME`.

Then it restarts the console. Sign in with an OpenShift login that may patch
ManagedClusters.

## Who can change what

Anyone who holds the catalog token can change the models and subscriptions
on every cluster, within the limits `apps/acm-models` sets. Never give that
token access to this repository: Argo CD applies this repository with
cluster-admin rights.

## Known limitation: Keycloak recreates realm saas on every start

`apps/keycloak` runs `kc.sh import --override true` on each start, so realm
`saas` is rebuilt from its import file. The backend's Keycloak user and any
organization made in the console are lost whenever Keycloak restarts. Rerun
`create-secrets.sh` after a restart to recreate the backend's user (it keeps
its other Secrets). Organizations made in the console have to be made again.
