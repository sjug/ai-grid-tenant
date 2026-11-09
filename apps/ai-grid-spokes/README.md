# AI Grid spokes

A cluster is an AI Grid site when its ManagedCluster carries
`ai-grid/enabled=true` and an `ai-grid/role` of `ingress`, `inference` or
`combined`. Set both: without a role, nothing is installed.

| Role | Runs | Standard dashboard | MaaS portal |
|---|---|---|---|
| `ingress` | OpenShift AI with MaaS, the grid consumer gateway, the tenant Policy, a `maas-db` read replica, the models' MaaS side | Managed | Managed |
| `inference` | OpenShift AI without MaaS (`apps/rhoai/roles/inference.yaml`), the grid operator and provider gateway, the models | Removed | Removed |
| `combined` | Both. | Managed | Managed |

With `ai-grid/enabled=true` and no role, or any other value, the cluster matches
none of these Placements, so none of the AI Grid platform is installed: no
OpenShift AI, no provider gateway, no `maas-db` replica and no catalog. The apps
that go to every managed cluster still do (listed at the end of this page). `grid-bootstrap` (#89) reads
`ai-grid/enabled` alone, so it still makes such a cluster a grid member, but its
membership policies wait for grid CRDs that never arrive.

```sh
oc label managedcluster site-a ai-grid/enabled=true ai-grid/role=ingress   # Add, as an ingress site
oc label managedcluster site-a ai-grid/enabled-                            # Remove
```

The provider console's **Add to AI Grid** sets both labels, and **Remove**
drops `ai-grid/enabled`. A role can be changed at any time. Removing the role
stops managing the site's platform as a Remove does, but the cluster stays a grid
member until `ai-grid/enabled` goes too.

## The hub

The hub runs ACM and Argo CD, and enrolls every site through grid-bootstrap
(apps/grid-bootstrap): the label makes a cluster a member, and ACM policies
deliver its identity, CA and GridNetwork. No enrollment service runs. A dedicated hub
(`BOOTSTRAP_PROFILE=dedicated-hub`) isn't labelled, so it generates `rhoai`
Applications for its sites only, none for itself.

The `maas-db` primary on the hub doesn't depend on the hub's labels: it's
generated for the hub whatever they are, and every object in
`apps/maas-db/primary` (the CloudNativePG operator and the `Cluster`)
carries `Delete=false`, so a Remove or a role change on the hub never deletes
tenants' keys or subscriptions.

## What a new site still needs

The labels are enough for the site itself. The grid operator derives the
gateways' routing from the models the site publishes, and policies deliver
peers, so no file per site. See
[cluster onboarding](../../docs/acm/cluster-onboarding/README.md).

## Changing a site to ingress or combined

The MaaS it gains validates users against the home's Keycloak over the home's
Route, so the site's cluster trust must carry the home's ingress CA first
(`proxy/cluster` `spec.trustedCA`, as the hub's bootstrap does for itself);
the role profile's Authorino trust (`apps/rhoai/roles/<role>.yaml`) then
mounts that bundle and the service CA into the site's Authorino. The site also gets a `maas-db` read replica, whose read
endpoint is `maas-read-r` (see `apps/maas-db/README.md`), and the MaaS side of
every catalog model.

## What a Remove does

Removing `ai-grid/enabled`, or the role, takes the cluster out of these Placements, so its
Applications go at the next poll: about a minute for every ApplicationSet that
reads them (`requeueAfterSeconds: 60`). A cluster that
can't be reached holds its Applications' deletion longer. The ApplicationSets
read the Placements, not the label on Argo CD's cluster Secret, which ACM
never removes.

What goes and what stays:

- Withdrawn: grid membership. `grid-bootstrap` reads the same label and
  withdraws the site's peer records.
- Stays, unmanaged: OpenShift AI and everything the `rhoai` Application
  installed, and the provider gateway (both ApplicationSets set
  `preserveResourcesOnDeletion`), and the catalog's models.
- Deleted: the site's `maas-db` replica (a full copy of every tenant's API
  keys), and the catalog's MaaS objects and subscriptions on that site.
- Stays, and needs cleanup: the Secrets that Policies delivered
  (`maas-db-config`, `maas-db-app`, `maas-db-replication`) and the tenant
  objects. Copies may exist, so rotate the shared credentials after removing a
  site.

A role change reaches the Placements at once, and the `rhoai` template a few
seconds later (through Argo CD's cluster Secret), so the Application can render
the old role's values for up to about a minute before it converges.

## What this app holds

- Placements `ai-grid-spokes`, `ai-grid-ingress` and `ai-grid-inference` in
  `openshift-gitops`. The ApplicationSets read their decisions live through
  ACM's `acm-placement` ConfigMap (`clusterDecisionResource`), joined with Argo
  CD's cluster Secret for the server address and labels. They never select on
  the Secret's labels alone: when a cluster leaves the Placement, the
  GitOpsCluster neither deletes its Secret nor removes the labels.
- Placements `ai-grid-spokes`, `ai-grid-ingress` and `ai-grid-inference` in
  `ai-grid-policies`, for the Policies there: `ai-grid-ready` and the
  catalog's status Policies (`apps/ai-grid-policies`, which also owns the
  namespace and its ClusterSet binding).

Policies in other apps select the same sites: the tenant Policy
(`apps/rhoai/hub/03-ingress-clusters-placement.yaml`: the AITenant, the MaaS tenant
config and the grid `ExternalProvider`) and `maas-db`'s credentials go to
sites with role ingress or combined.
`rhoai-prerequisites` (with the model namespace and its NetworkPolicies, the
image mirror and the pull secret, and its `rhoai-limitador-redis` Policy on
every cluster but the hub), Submariner, the sample models and Argo CD's cluster
registration still go to every managed cluster, site or not, and ACM Search's
collector to every one but the hub (`apps/acm/manifests/search`).

## Changing a site to ingress or combined

The MaaS it gains validates users against the MaaS home's Keycloak Route. On a
combined hub, the `rhoai-ingress-clusters` Policy publishes the hub's public
ingress CA as `kuadrant-system/home-keycloak-ca`, and the ingress and combined
role values and Authorino CR mount it directly in Authorino. On a dedicated
external-services home, the Policy creates an empty `home-keycloak-ca`
placeholder; if the home's
certificate is not publicly trusted, follow the cluster trust procedure in
`docs/acm/cluster-onboarding/README.md` ("Trusting the MaaS home's ingress
CA"). A site that needs more CA ConfigMaps lists the complete set in
`apps/rhoai/values-<cluster>.yaml` under
`dependencies.rhcl.config.authorinoTrustedCA.configMaps`.
