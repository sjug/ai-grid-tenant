# Bare metal

The [getting started](../README.md) steps apply unchanged: a hub, then
clusters, then models. This page lists what a site without a cloud provider
must bring, which inputs it declares, and what has been qualified. Every
command and file here exists in this repository; nothing is specific to one
lab.

## Qualified configuration

Tested end to end on three OpenShift 4.22 clusters (one combined hub, one
inference site, one second ingress site) with ACM 2.17, a RHOAI 3.6 nightly
build, the default OVN-Kubernetes network, a host-network default ingress
controller, LVM Storage for block volumes and OpenShift Data Foundation's
NooBaa for object storage. That deployment ran the fixes this guide relies on
in their original form; the procedure as written here (the chart-based usage
logs and the per-site inputs) has not been exercised end to end yet.
Not qualified: IPv6 or dual-stack, other network plugins, single-node
OpenShift, a hub on managed OpenShift mixed with bare-metal sites, GPU models.

## What a site must bring

Beyond the [dependencies](../README.md#dependencies):

- **DNS.** Every site's router names must answer `A` queries, and `AAAA`
  queries must return either an address or `NOERROR` with an empty answer; an
  `AAAA` answered with `NXDOMAIN` makes the grid operator's lookups fail (see
  [cluster onboarding](../cluster-onboarding/README.md)).
- **A load balancer for the gateways the site's role needs** (the MaaS
  gateway on an ingress or combined site, the serving gateway where models
  run): an existing one is fine; a site without one declares an L2 range and
  gets MetalLB (below). Submariner's gateways default to a LoadBalancer Service
  (`loadBalancerEnable: true` in `apps/acm/submariner/values.yaml`); a
  deployment without one sets it to `false` in that file, in its fork, before
  the hub's first sync, and the gateway nodes must then be reachable from the
  other sites on their own addresses and Submariner's tunnel ports.
- **Block storage** with a default StorageClass (LVM Storage or equivalent)
  for RHOAI monitoring, the MaaS database replica, Prometheus and the usage
  logs; **object storage** with an ObjectBucketClaim class (NooBaa) on the
  hub: the hub's Thanos requires a claim (its bridge Job writes the Secret from
  it); the usage logs take a claim or, alternatively, an existing S3 Secret.
- **Registry credentials** for the RHOAI and model images, given to the
  bootstrap script; the hub's pull-secret policy merges them into every site's
  global pull secret with the hub's values winning.
- **An ingress certificate** on the external-services cluster (the MaaS home) that its sites can trust, or the
  trust step below.

## Site inputs

All inputs are ManagedCluster labels or small files next to the app that
reads them; nothing identifies a site in a shared file.

| Input | Where | When |
|---|---|---|
| `ai-grid/enabled`, `ai-grid/role` | ManagedCluster labels | Every site ([cluster onboarding](../cluster-onboarding/README.md)). |
| `ai-grid/metallb-pool=<first>-<last>` | ManagedCluster label | A site without a load balancer; more pools or an existing operator in `apps/metallb/values-<cluster>.yaml`, committed before the label ([MetalLB](../../../apps/metallb/README.md)). |
| `ai-grid/platform-namespaces=true` | ManagedCluster label | Only managed OpenShift, whose platform owns the Loki operator namespace; not on bare metal. |
| `ai-grid/machine-network=<cidr with _>` | ManagedCluster label | Only where the provider gateway sees peers as node machine addresses. On the qualified path (OVN-Kubernetes, host-network router) peers arrive from the router node's management address, which the ingress policy group admits; [cluster onboarding](../cluster-onboarding/README.md) says how to observe the path. |
| `lokistack.storageClassName` and the object-storage mode | `apps/ai-grid-o11y/values-site.yaml` | The hub, before the usage-logs chart syncs ([usage logs](../../../apps/ai-grid-o11y/chart/README.md)). |
| MaaS home ingress CA | Combined hub: automatic through `rhoai-ingress-clusters`; dedicated home: `docs/acm/cluster-onboarding/trust-external-services-ca.sh` | Every MaaS site whose home's ingress certificate is privately signed. |
| Console backend's Keycloak URL | `KEYCLOAK_BACKEND_URL` to `apps/console/create-secrets.sh` | When the backend cannot trust the ingress CA ([console](../../../apps/console/README.md)). |

## Deployment order

1. Hub: [hub onboarding](../hub-onboarding/README.md). On a fresh cluster the
   bootstrap script waits for the default Argo CD instance before applying
   anything (`ARGOCD_READY_TIMEOUT_SECONDS`), and the catalog refresh Job's
   deadline is derived from its waits. Commit `apps/ai-grid-o11y/values-site.yaml`
   with the hub's block class before the first sync.
2. Sites: import, then label `ai-grid/enabled`; add the MetalLB label (with
   its values file first, if any). On a combined hub, label the ingress or
   combined role and let ACM create `home-keycloak-ca` while RHOAI mounts it in
   Authorino. On a fresh site whose dedicated external-services home serves a
   privately signed ingress, label the role, then run the trust script as soon
   as the trust ConfigMaps exist and wait for it to report the merged bundle
   mounted and the discovery check passed; MaaS calls fail until then, so
   onboard tenants after it. A site that already runs Authorino and changes its
   role (for example inference to combined) runs the trust script before the
   role change, as the cluster-onboarding guide says.
3. Models: [AI project onboarding](../ai-project-onboarding/README.md).

## Verification

The [getting started](../README.md#verification) checks, plus:

- `apps/maas-db/check-read-alias.sh <hub kubeconfig> <MaaS site kubeconfig>...`
  reports every MaaS site's read endpoint ready with an authenticated read.
- The gateways the role needs hold an address: the MaaS gateway on an ingress
  or combined site, the serving gateway where models run, from the site's pool
  or its own load balancer (`oc -n openshift-ingress get svc`).
- The hub's Thanos holds the site's grid series once the collection
  ScrapeConfigs are registered (`apps/acm/manifests/observability/README.md`):
  `grid_collection_up{cluster="<site>"}` in the hub's Grafana explore view.

## Upgrading and rolling back

- The read-endpoint switch (`maas-read-r`) deploys after the alias has
  reconciled everywhere; the gate above is the check
  ([maas-db](../../../apps/maas-db/README.md)).
- A managed-OpenShift hub carries `ai-grid/platform-namespaces=true` before
  taking a revision with that label; bare-metal clusters need nothing.
- Withdrawing collection: registration policy out of Git first, then the
  addon entries, then the ScrapeConfigs (`apps/acm/manifests/observability/README.md`).
- MetalLB handover: the operator objects are never pruned; pools are, while
  the label is set ([MetalLB](../../../apps/metallb/README.md)).
- Rolling back a chart revision keeps object identities (the usage-logs chart
  renders the names its manifests had); a LokiStack volume class cannot be
  changed in place.
