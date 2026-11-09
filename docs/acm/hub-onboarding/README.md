# Grid ACM hub install

How a cluster becomes a Grid site on v0.3.0-rc.3, under Local membership with ACM delivery. One site per cluster.

## Installing Argo CD

Argo CD runs on the hub and installs everything else from the tenant repo, ACM included. Argo syncs from git, so run it from your own fork. Point the fork's Argo sources at itself, once, and push:

```bash
git clone https://github.com/<you>/ai-grid-tenant.git
cd ai-grid-tenant
scripts/set-tenant-repo.sh https://github.com/<you>/ai-grid-tenant.git main
git commit -am "Point Argo at this fork" && git push
```

Then, as cluster-admin on the hub:

```bash
oc login --server=https://api.<hub-cluster-domain>:6443 -u <cluster-admin>
export RHOAI_QUAY_PULL_SECRET=<base64 of user:password for quay.io/rhoai>
export RHOAI_STAGE_PULL_SECRET=<base64 of user:password for registry.stage.redhat.io>   # needed for model images pulled through the rhaii mirrors
./bootstrap.sh
```

bootstrap.sh installs the openshift-gitops-operator Subscription, waits for the Argo CRDs, and applies a root ApplicationSet over apps/*/application.yaml. Argo then syncs every app from the fork.

The root ApplicationSet is the one object Argo does not sync from Git. After a change to bootstrap/applicationset.yaml, or to bootstrap/dedicated-hub/applicationset.yaml on a dedicated hub, apply it again from the revision the hub tracks:

```bash
oc apply -f bootstrap/applicationset.yaml                 # combined hub
oc apply -f bootstrap/dedicated-hub/applicationset.yaml   # dedicated hub
```

Every Application it generates syncs from Git on its own.

Both roots set `preserveResourcesOnDeletion: true`: deleting a root, or removing an app from its generator, removes the Application but leaves its deployed resources running, so clean those up separately. An explicit cascading delete from the Argo UI or API can still delete an Application's unprotected resources.

## Installing ACM

Delivered by the acm Argo app ([apps/acm/manifests](../../../apps/acm/manifests), ACM 2.17.3), in namespace open-cluster-management:

1. OperatorGroup targeting open-cluster-management.
2. Subscription advanced-cluster-management, channel release-2.17, source redhat-operators.
3. MultiClusterHub with an empty spec. The hub registers itself as local-cluster.
4. A ManagedClusterSetBinding for global, a Placement over global, and ClusterManagementAddOns governance-policy-framework, config-policy-controller, and governance-standalone-hub-templating installed through that Placement. Every cluster then runs policies and can resolve hub templates, the hub included.
5. The search-collector Policy ([apps/acm/manifests/search](../../../apps/acm/manifests/search)), placed on the hub only. It creates ACM Search's `search-collector` ManagedClusterAddOn in the namespace of every managed cluster but the hub, so Search indexes the spokes; the provider console reads their GPUs and MaaSSubscriptions through it. The hub runs its own collector. ACM's own ClusterManagementAddOn stays as the MultiClusterHub operator applies it (installStrategy Manual, which that operator restores on every reconcile), and a cluster with a KlusterletAddonConfig is left to it. Deleting the Policy removes the add-ons it created.
6. Import each spoke. It joins the global set. See [cluster onboarding](../cluster-onboarding/README.md):

```bash
docs/acm/cluster-onboarding/import-managed-cluster.sh --spoke-context <spoke> --cluster-name <name>
```

## Setting up a hub

The hub manages the grid: CA, grid ID, policies. It needs no Grid CRDs. Running Grid workloads on it is optional.

Needs ACM as above and cert-manager. On a hub that is also a site, the RHOAI app supplies four things grid-bootstrap depends on: cert-manager, the redhat-ai-grid namespace, ClusterSet global bound into that namespace, and, through rhoai-prerequisites, the quay.io/rhoai mirror and pull Secret its pre-release image needs. A hub that is not a site gets them from the [dedicated-hub profile](#dedicated-hub).

Install grid-enrollment on the hub with the grid-bootstrap app. Its values, [apps/grid-bootstrap/values.yaml](../../../apps/grid-bootstrap/values.yaml):

```yaml
mode: external
gridIdentity:
  enabled: true
grid:
  membership:
    source: Local
managedClusters:
  enabled: true
  networkName: grid
  clusterSet: global
  clusterLabel: ai-grid/enabled
  clusterLabelValue: 'true'
  createClusterSetBinding: false
  hubClusterName: local-cluster
external:
  delivery:
    namespace: redhat-ai-grid
  certManager:
    enabled: true
    issuer:
      create: true
      name: grid-ca
    ca:
      mode: Existing
      secretName: grid-ca-key
```

The lab keeps its CA with mode Existing. A new grid uses mode Generate.

Nothing else to run. The root ApplicationSet picks up [apps/grid-bootstrap/application.yaml](../../../apps/grid-bootstrap/application.yaml), which installs the chart on the hub with these values. Change them by committing to this file.

Onboard a cluster by labelling its ManagedCluster `ai-grid/enabled=true` and `ai-grid/role` (`ingress`, `inference` or `combined`). Together they install RHOAI in that role, and `ai-grid/enabled` joins the grid; without a role nothing is installed ([apps/ai-grid-spokes](../../../apps/ai-grid-spokes/README.md)). Unlabelling withdraws it from the grid and stops managing those workloads, but does not uninstall them, and keeps its GridNetwork; its MaaS database replica and the catalog's MaaS objects and subscriptions there are the exceptions, deleted because they hold or grant tenants' access.

The hub is a site only if labelled. Proposed: managedClusters.includeHub, default false, excludes the hub from membership whatever its labels.

Verify: membership policies Compliant, each member's GridNetwork Active with the grid ID.

## Dedicated hub

A dedicated hub runs ACM, cert-manager and grid-enrollment, and no Grid or RHOAI workloads. Bootstrap it with the dedicated-hub profile:

```bash
BOOTSTRAP_PROFILE=dedicated-hub ./bootstrap.sh
```

Its root ApplicationSet, [bootstrap/dedicated-hub/applicationset.yaml](../../../bootstrap/dedicated-hub/applicationset.yaml), syncs acm, acm-models, ai-grid-o11y, ai-grid-policies, ai-grid-spokes, argo-registration, cert-manager, console, external-secrets, gitops-config, grid-bootstrap, keycloak, limitador-redis, maas-db, external-services, metallb, odf, rhoai and rhoai-prerequisites. ACM syncs the full [apps/acm/manifests](../../../apps/acm/manifests) — core, observability, search and Submariner — with [apps/odf](../../../apps/odf) supplying the object storage observability needs. The default ApplicationSet skips [apps/cert-manager](../../../apps/cert-manager), because on a combined hub the RHOAI app installs cert-manager.

The root generates all Applications except ODF directly from Git, so ACM and argo-registration can start on a fresh hub without an existing Argo cluster registration. ODF is generated separately once the local-cluster registration carries the openshiftVersion-major-minor label; its operator channel then matches that version. Until registration and the version label are available, ODF is absent and ACM observability may wait for its object storage. Verify that acm and argo-registration exist immediately, then check registration and the version label if odf does not appear. An ApplicationSet success condition alone does not confirm that the expected Applications were generated.

ODF installs into openshift-storage, which OLM allows only one OperatorGroup. The ODF app creates that group and never prunes it. On a hub that already has one there, for example from an LVMS install, label the local-cluster ManagedCluster ai-grid/odf-operatorgroup=existing so ODF uses it instead.

[apps/argo-registration](../../../apps/argo-registration) registers every cluster in global with Argo CD, which on a combined hub acm-models does, so the default ApplicationSet skips it. The rhoai app installs RHOAI and the role's Grid gateways on each AI Grid site, as [apps/ai-grid-spokes](../../../apps/ai-grid-spokes) selects them by label and role.

acm-models brings the sample model and its MaaS objects, to AI Grid sites by role, and the provider console's catalog: its AppProjects and ApplicationSets, which deliver the models and subscriptions the console commits (see [Provider console](#provider-console)). Its GitOpsCluster would duplicate argo-registration, so it stays out.

The hub runs MaaS's shared state: the maas-db primary, Keycloak and Limitador's Redis. Sites reach them over Submariner, and ingress and combined sites get a maas-db read replica. To hold that state on one site instead, label it ai-grid/external-services=true, and [apps/external-services](../../../apps/external-services) installs them there. Do not use both. The default ApplicationSet skips external-services, because a combined hub runs them itself.

The profile sets two grid-bootstrap values for a new grid on its own hub: external.certManager.ca.mode Generate, and managedClusters.createClusterSetBinding true, since no RHOAI app binds ClusterSet global into redhat-ai-grid there. Keep Generate for the life of the hub: its CA is a cert-manager Certificate.

rhoai-prerequisites delivers the quay.io/rhoai mirror and pull Secret to every cluster in global, the hub included. The grid-enrollment image needs them, so set RHOAI_QUAY_PULL_SECRET before bootstrap.sh, as for any hub. Without it, grid-bootstrap's CA Job stays in ImagePullBackOff. Applying the mirror reboots each node once, so a single-node hub drops out for a few minutes. To avoid the mirror, pin the grid-enrollment image to the public ODH build in the grid-bootstrap values.

A hub with no load balancer labels local-cluster ai-grid/metallb-pool=<first>-<last> with a free range, so its Submariner gateways get an address.

Verify: an Application for each app in that list, plus dedicated-hub-root and the ones acm-models and the site ApplicationSets generate, Synced and Healthy (console only after [its Secrets](#provider-console) exist), the MultiClusterHub Running, and local-cluster joined and available. Do not label local-cluster with ai-grid/enabled; that label alone would make the hub a site.

## Provider console

The console app installs the cloud provider's admin console on the hub, on both hub profiles ([apps/console](../../../apps/console/README.md)). Argo CD creates its namespace, Route and Deployment, but the pod doesn't start until three Secrets exist, and nobody can sign in until its OAuthClient exists. None of them is in git. Create them once per hub:

1. Create the catalog token. Someone with write access to the catalog repository (`backend.git.url` in [apps/console/application.yaml](../../../apps/console/application.yaml), the same URL as in `apps/acm-models/hub/catalog-*`) creates a fine-grained GitHub personal access token: resource owner the repository's organization, repository access only that repository, and repository permission `Contents: Read and write`, nothing else. If the organization requires approval for fine-grained tokens, an organization owner approves it.
2. Save the token in a file outside any git checkout, readable only by you (`chmod 600`). The console commits to the catalog with it, so anyone holding it can change models and subscriptions on every cluster. Never give it access to this repository.
3. Wait until Argo CD has created the console's Route:

   ```bash
   oc -n ai-grid-provider-console get route ai-grid-provider-console
   ```

4. As a hub cluster-admin, from a checkout of this repository, run:

   ```bash
   AI_GRID_GIT_TOKEN_FILE=/path/to/token-file apps/console/create-secrets.sh
   ```

   If the hub's ingress certificate isn't signed by a public CA, also set `CURL_CA_BUNDLE` to a file holding the ingress CA, and `KEYCLOAK_BACKEND_URL=http://keycloak.maas-db.svc:8080` so the backend reaches Keycloak inside the cluster ([apps/console/README.md](../../../apps/console/README.md#before-the-first-sync-completes) says why). `HUB_CONTEXT` picks a kubeconfig context other than the current one. The script is safe to rerun and prints no secret value.

   The script reads Keycloak's Route and `maas-db/keycloak-secrets` through the same context as the console, so it expects Keycloak on the hub. With a site labelled `ai-grid/external-services=true`, Keycloak runs on that site, and the script doesn't support that layout yet.

   It creates the OAuthClient `ai-grid-provider-console` and its proxy Secret, the backend's Keycloak user in realm `saas` with Secret `ai-grid-backend-keycloak`, and `ai-grid-backend-git` from the token file. Then it restarts the console.
5. Open the Route's URL and sign in with an OpenShift login. Add to AI Grid and Remove need a login that may patch ManagedClusters.

Verify: the console pod is Ready (`oc -n ai-grid-provider-console get pods`), the Clusters page lists the ManagedClusters, and the Organizations page lists realm `saas`'s organizations.

Keycloak imports realm `saas` only when it doesn't exist, so a Keycloak restart keeps the backend's user and the organizations made in the console ([apps/keycloak/README.md](../../../apps/keycloak/README.md#realm-imports-and-git-edits)). Earlier versions rebuilt the realm on every start: on a hub where that already deleted them, rerun create-secrets.sh once to recreate the backend's user; organizations made in the console have to be made again.

## Grid ID

Source: the hub ConfigMap. Copy: each cluster's GridNetwork spec.gridId, immutable. Consumers read the local GridNetwork. Back up the ConfigMap with the CA. Under Local it only gates readiness.

## Local membership

* Peers: the GridSites delivered to the cluster.
* Remote providers: polled from each peer's catalog.
* Admission: a certificate naming a declared GridSite.

The operator restarts into the mode its GridNetwork declares.

## Simplification candidates

* Three possible creators of the local GridSite: operator, grid-operator chart, policy.
* Endpoints are copied twice: Routes to local GridSite to peer copies.
* Everything keys on the managed cluster name, so one site per cluster.

## Flow

```mermaid
flowchart TD
    BOOT["Hub bootstrap Job"] --> STATE["Hub ConfigMap grid-bootstrap-state<br/>gridId"]
    ENROLL["Identity policy"] --> NET
    STATE --> NET["GridNetwork per cluster<br/>gridId, Local, poll, SPIFFE"]
    CRDS["CRDs and operator"] --> NET
    ROUTES["Gateway and signals Routes"] --> SITE
    NET --> SITE["Local GridSite<br/>gateway and signals endpoints"]
    SITE --> OBS["Observer ManifestWork"]
    OBS --> PEERS["Peers policy<br/>copies other members' GridSites"]
    PEERS --> POLL["Operator polls peers over mTLS"]
    MODEL["Model controller"] --> IP["InferenceProvider"]
    IP --> CAND["Routing candidates"]
    POLL --> CAND
    CAND --> GW["grid-gateway"]
```

1. Bootstrap writes the grid ID once to grid-bootstrap-state on the hub.
2. A policy delivers each cluster's site identity and CA. The site name is the managed cluster name.
3. Once the CRDs are Established and the Secrets exist, a policy creates the GridNetwork: grid ID, Local, poll, SPIFFE.
4. A policy writes the local GridSite with endpoints from the admitted Routes.
5. The observer reads each GridSite back to the hub, and the peers policy copies it to the other members.
6. The operator polls each declared peer. Local and remote providers become the gateway's candidates. Remote picks go to the site's gateway, local picks to the provider endpoint.

## References

* Grid, v0.3.0-rc.2: https://github.com/praxis-proxy/grid/tree/v0.3.0-rc.2
* grid-enrollment chart: https://github.com/praxis-proxy/grid/tree/v0.3.0-rc.2/charts/grid-enrollment
* Vendored chart the lab installs: https://github.com/opendatahub-io/odh-gitops/tree/main/charts/rhai-on-openshift-chart/charts/grid-enrollment
* Lab tenant: https://github.com/ai-grid-cloud/ai-grid-cluster-gitops
* Argo bootstrap: https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/main/bootstrap.sh
* ACM manifests: https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/tree/main/apps/acm/manifests
* Hub values: https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/main/apps/grid-bootstrap/values.yaml

## Upgrading

- Before upgrading a hub that runs on managed OpenShift (OSD, ROSA) to a revision
  with the `ai-grid/platform-namespaces` label, label `local-cluster` with
  `ai-grid/platform-namespaces=true`: the rhoai chart otherwise starts creating
  `openshift-operators-redhat`, which the platform already owns there.
