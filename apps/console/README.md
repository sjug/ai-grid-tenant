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
  ManagedCluster. `apps/ai-grid-spokes` selects sites by `ai-grid/enabled` and
  `ai-grid/role`, so Add with a role installs OpenShift AI in that role (MaaS
  on ingress and combined sites, models and the provider gateway on inference
  and combined sites) and joins the grid. Remove takes the cluster out of
  those Placements: its workloads stay installed, but the catalog's MaaS
  objects and subscriptions on it are deleted, because they grant tenants
  access.
- **Organizations:** Keycloak Organizations in realm `saas`, through a
  Keycloak user of its own with only the realm-management roles that needs
  (`view-users`, `query-users`, `view-realm`, `manage-realm`,
  `view-identity-providers`, `manage-identity-providers`; the last two link a
  tenant's own IdP to its organization). `manage-identity-providers` is
  realm-wide: the backend can edit any IdP in realm `saas`, not only those
  linked to its organizations. Existing hubs: rerun
  `apps/console/create-secrets.sh`; no restart needed.
- **GPUs:** each spoke's GPUs from ACM Search. `manifests/search-rbac.yaml`
  binds the backend to ACM's `global-search-user`, which lets it read every
  managed cluster's indexed resources: more than the GPU nodes it asks for, so
  the backend stays behind the console's sign-in (the file says why).
- **Models and subscriptions:** commits to the catalog repository,
  [sjug/ai-grid-catalog](https://github.com/sjug/ai-grid-catalog),
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

The backend reaches Keycloak at the URL the script stores in
`ai-grid-backend-keycloak`: by default Keycloak's public HTTPS Route, which
works as is when the cluster's ingress certificate chains to a CA the backend's
image trusts. On a cluster whose ingress CA is private (most self-managed
clusters), two things need the CA:

- The script's own calls go through the Route: run it with `CURL_CA_BUNDLE`
  pointing at a file holding the ingress CA.
- The backend's calls go to the stored URL, and the backend's image trusts the
  system roots only: the console chart at the pinned revision has no setting
  that adds a CA to the backend. Either serve the ingress with a certificate
  the backend trusts, or set `KEYCLOAK_BACKEND_URL` to Keycloak's in-cluster
  Service, `http://keycloak.maas-db.svc:8080`, so that the backend's admin API
  calls stay inside the cluster network and need no TLS trust. Keycloak's
  issued URLs stay public either way because its hostname is fixed by
  `KC_HOSTNAME`. Changing the URL means rerunning the script, which restarts
  the console.

Then it restarts the console. Sign in with an OpenShift login that may patch
ManagedClusters.

## Who can change what

Anyone who holds the catalog token can change the models and subscriptions
on every cluster, within the limits `apps/acm-models` sets. Never give that
token access to this repository: Argo CD applies this repository with
cluster-admin rights.

## Keycloak restart behavior

`apps/keycloak` imports realm `saas` only when it does not exist. The
backend's Keycloak user and organizations made in the console survive a
Keycloak restart; Git edits to the realm file reach it through PostSync hooks
([apps/keycloak/README.md](../keycloak/README.md#realm-imports-and-git-edits)).
