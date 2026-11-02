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

## Installing ACM

Delivered by the acm Argo app ([apps/acm/manifests](../../../apps/acm/manifests), ACM 2.17.3), in namespace open-cluster-management:

1. OperatorGroup targeting open-cluster-management.
2. Subscription advanced-cluster-management, channel release-2.17, source redhat-operators.
3. MultiClusterHub with an empty spec. The hub registers itself as local-cluster.
4. A ManagedClusterSetBinding for global, a Placement over global, and ClusterManagementAddOns governance-policy-framework and config-policy-controller installed through that Placement. Every cluster then runs policies, the hub included.
5. Import each spoke. It joins the global set. See [cluster onboarding](../cluster-onboarding/README.md):

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

Its root ApplicationSet, [bootstrap/dedicated-hub/applicationset.yaml](../../../bootstrap/dedicated-hub/applicationset.yaml), syncs acm, acm-models, ai-grid-policies, ai-grid-spokes, argo-registration, cert-manager, gitops-config, grid-bootstrap, maas-home, rhoai and rhoai-prerequisites. ACM gets [core](../../../apps/acm/manifests/core) only, since observability needs object storage and Submariner needs a site. The default ApplicationSet skips [apps/cert-manager](../../../apps/cert-manager), because on a combined hub the RHOAI app installs cert-manager.

[apps/argo-registration](../../../apps/argo-registration) registers every cluster in global with Argo CD, which on a combined hub acm-models does, so the default ApplicationSet skips it. The rhoai app installs RHOAI, and a provider gateway where apps/rhoai/provider-gateway-<cluster>.yaml exists, on each AI Grid site, as [apps/ai-grid-spokes](../../../apps/ai-grid-spokes) selects them by label and role.

acm-models brings only the sample model and its MaaS objects, to AI Grid sites by role. Its GitOpsCluster would duplicate argo-registration, and the console catalog belongs to a combined hub.

MaaS keeps its shared state on a site, not the hub: label one cluster ai-grid/maas-home=true, and [apps/maas-home](../../../apps/maas-home) installs the maas-db primary, Keycloak and Limitador's Redis there. The default ApplicationSet skips maas-home, because a combined hub runs them itself.

The profile sets two grid-bootstrap values for a new grid on its own hub: external.certManager.ca.mode Generate, and managedClusters.createClusterSetBinding true, since no RHOAI app binds ClusterSet global into redhat-ai-grid there. Keep Generate for the life of the hub: its CA is a cert-manager Certificate.

rhoai-prerequisites delivers the quay.io/rhoai mirror and pull Secret to every cluster in global, the hub included. The grid-enrollment image needs them, so set RHOAI_QUAY_PULL_SECRET before bootstrap.sh, as for any hub. Without it, grid-bootstrap's CA Job stays in ImagePullBackOff. Applying the mirror reboots each node once, so a single-node hub drops out for a few minutes. To avoid the mirror, pin the grid-enrollment image to the public ODH build in the grid-bootstrap values.

Verify: the eleven Applications Synced and Healthy, the MultiClusterHub Running, and local-cluster joined and available. Do not label local-cluster with ai-grid/enabled; that label alone would make the hub a site.

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
* Vendored chart the lab installs: https://github.com/opendatahub-io/odh-gitops/tree/feature-ai-grid/charts/rhai-on-openshift-chart/charts/grid-enrollment
* Lab tenant: https://github.com/ai-grid-cloud/ai-grid-cluster-gitops
* Argo bootstrap: https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/main/bootstrap.sh
* ACM manifests: https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/tree/main/apps/acm/manifests
* Hub values: https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/main/apps/grid-bootstrap/values.yaml
