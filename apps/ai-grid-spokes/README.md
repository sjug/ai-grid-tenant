# AI Grid spokes

A cluster is an AI Grid site when its ManagedCluster carries
`ai-grid/enabled=true` and an `ai-grid/role` of `ingress`, `inference` or
`combined`. Set both: without a role, nothing is installed.

| Role | Runs |
|---|---|
| `ingress` | OpenShift AI with MaaS and the portal, the grid consumer gateway, the tenant Policy, a `maas-db` read replica, the models' MaaS side |
| `inference` | OpenShift AI without MaaS (`apps/rhoai/roles/inference.yaml`), the grid operator and provider gateway, the models |
| `combined` | Both. |

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

The hub runs ACM and Argo CD. On a combined hub, the grid enrollment service runs
in the hub's own OpenShift AI release (`grid-enrollment.enabled` on
`local-cluster`), so the hub must be a site too, normally `combined`. Don't remove a combined hub from the grid or give it another role:
its release, enrollment included, would stop being managed. A dedicated hub
(`BOOTSTRAP_PROFILE=dedicated-hub`) isn't labelled, so it generates `rhoai`
Applications for its sites only, none for itself.

The `maas-db` primary on the hub doesn't depend on the hub's labels: it's
generated for `local-cluster` whatever they are, and every object in
`apps/maas-db/local-cluster` (the CloudNativePG operator and the `Cluster`)
carries `Delete=false`, so a Remove or a role change on the hub never deletes
tenants' keys or subscriptions.

## What a new site still needs

The labels are enough for the site itself. The grid operator derives the
gateways' routing from the models the site publishes, so no file per site. Two
things stay on the hub: a declared peer file for the site, until members report
their gateway address, and the provider gateway NetworkPolicy CIDR for a site
outside the lab VPC. See
[cluster onboarding](../../docs/acm/cluster-onboarding/README.md).

## What a Remove does

Removing `ai-grid/enabled`, or the role, takes the cluster out of these Placements, so its
Applications go at the next poll: about a minute for `rhoai`,
`grid-provider-gateway` and `maas-db` (`requeueAfterSeconds: 60`), up to 3
minutes for the catalog ApplicationSets (Argo CD's default). A cluster that
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
- The hub still declares it as a peer in
  `apps/rhoai/local-cluster/40-declared-peer-<cluster>.yaml` until that file
  goes.

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
(`apps/rhoai/hub/03-tenant-placement.yaml`: the AITenant, the MaaS tenant
config and the grid `ExternalProvider`) and `maas-db`'s credentials go to
sites with role ingress or combined.
`rhoai-prerequisites` (with the model namespace and its NetworkPolicies, the
image mirror and the pull secret, and its `rhoai-limitador-redis` Policy on
every cluster but the hub), Submariner, the sample models and Argo CD's cluster
registration still go to every managed cluster, site or not.

## Changing a site to ingress or combined

The MaaS it gains validates users against the home's Keycloak over the home's
Route. If that Route's certificate is not publicly trusted, the site's cluster
trust must carry the home's ingress CA before the role is set; the procedure
is in `docs/acm/cluster-onboarding/README.md` ("Trusting the MaaS home's
ingress CA"). `apps/rhoai/maas-sites` then mounts the cluster trust bundle and
the service CA into the site's Authorino; a site that already mounts volumes
into Authorino lists them in `apps/rhoai/maas-sites/values-<cluster>.yaml`
under `authorino.extraVolumeItems`.
