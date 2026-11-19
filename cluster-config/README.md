# Cluster config

Cluster-level configuration managed separately from the workload apps under
`apps/`. The `apps` ApplicationSet discovers `cluster-config/application.yaml`,
which deploys the fleet-wide `cluster-config` ApplicationSet.

## Cluster admins

Two owners, two groups:

- The `cluster-admins` Group is managed by OCM on the hub. Git no longer
  declares it, so Argo CD self-healing never overwrites OCM's member list.
  Its members hold Argo CD admin through the OpenShift GitOps operator's
  default RBAC policy.
- The `ai-grid-admins` Group is Git-owned. Its members are the
  `cluster_admins` list (per deployment: [`values.yaml`](values.yaml) leaves
  it empty, a deployment lists its users in
  [`cluster-admins.yaml`](cluster-admins.yaml)), it receives cluster-admin
  through the Git-owned `cluster-admin-ai-grid-admins` ClusterRoleBinding,
  and Argo CD admin through `spec.rbac.policy.csv` in the ArgoCD CR
  (`apps/gitops-config/manifests/argocd.yaml`).

Both the Group and its binding are rendered only when `hubResources.enabled`
  is true, matching the Submariner gateway pattern: Argo CD and the OCM-owned
  group are hub concerns; spokes need no admin group. The hub uses Argo CD's
  in-cluster destination so the controller's ServiceAccount, rather than the
  ACM addon ServiceAccount, applies its RBAC.

Editing `cluster_admins` edits Group membership only; the binding is
  unaffected. The former per-user `cluster-admin-<user>` bindings are gone;
  they prune on the first automated sync after this change. Argo creates the
  Group and group binding before pruning the per-user bindings, so admin
  access never gaps. The removed `gitops-config` Group manifest orphans the
  live `cluster-admins` Group (that Application runs with `prune: false`);
  because it is no longer Git-owned, a future removal of `ai-grid-admins`
  would require manual deletion of the Group and its binding.

## Submariner gateway nodes

The `submariner-gateway-nodes` policy is distributed to every cluster in the
global cluster set. On each cluster, it discovers Nodes whose only role is
`worker` and enforces the `submariner.io/gateway` label. New and replacement
worker Nodes are therefore labeled without cluster-specific Node names in Git.
The policy lives in its own namespace so its `ManagedClusterSetBinding` can be
named `global`, as required by ACM, without colliding with the existing binding
in `openshift-gitops`.
Submariner is configured for two gateways because cross-cluster connectivity
is required by the shared database and model-serving topology. Each managed
cluster therefore needs at least two pure worker Nodes.
The `acm-submariner` ApplicationSet deploys the add-on and configuration on
every managed cluster. On ROSA, the gateways use a load-balancer Service
instead of node ports.

### Adding or removing an admin

Edit `cluster-admins.yaml` and commit. The hub's generated Application syncs
automatically (prune and self-heal are enabled):

- Adding a username to `cluster_admins` adds it to the `ai-grid-admins` Group
  on the hub, granting cluster-admin and Argo CD admin, on the next sync.
- Removing a username removes it from the Group, revoking both. OCM
  administrators on `cluster-admins` are unaffected either way.

The chart is stored in this repository at [`chart/`](chart/); the Application
uses the same multi-source pattern as the OSAC apps (chart path plus a
`values` ref for the value file).

### Migration and pruning

The bootstrap `apps` ApplicationSet discovers `application.yaml` by file path.
When its generated Application is renamed from `cluster-admins` to
`cluster-config`, `cluster-admins` no longer matches any generator output.
The ApplicationSet uses `applicationsSync: sync` and
`preserveResourcesOnDeletion: false`, so its controller prunes the stale
Application. The fleet-wide `cluster-config` ApplicationSet uses the same
pruning policy for Applications that no longer match an ACM managed cluster.

Generated Application names include the cluster name and a short hash. Each
selected cluster therefore receives exactly one generated Application, with
no duplicate names.

The chart's Submariner gateway policy is hub-only ACM state. The
`hubResources.enabled` parameter is true only for the hub, so managed
clusters render only the fleet-wide RBAC and do not receive duplicate Policy,
Placement, or PlacementBinding resources.

### Constraints

- `cluster_admins` entries are Kubernetes usernames. Group members are not
  constrained to DNS-1123 resource names, so IdP-qualified usernames such as
  `user@domain` are valid.
- The Group is granted access via a `kind: Group` subject. A member that has
  never authenticated is inert until its first login; the Group and binding
  are created regardless.
- The Group and binding are hub-only (`hubResources.enabled`); all their
  resources are cluster-scoped, so `spec.destination.namespace` is only
  present to satisfy the ApplicationSet template; no namespace is created.

### Validation

Local:

```sh
helm lint cluster-config/chart -f cluster-config/values.yaml -f cluster-config/cluster-admins.yaml
helm template cluster-config/chart -f cluster-config/values.yaml -f cluster-config/cluster-admins.yaml
helm template cluster-config/chart -f cluster-config/values.yaml \
  --set hubResources.enabled=true
```

Live: after pushing, the `apps` ApplicationSet updates the `cluster-config`
Application, and the fleet ApplicationSet creates one Application for each
ACM managed cluster. Confirm the generated Applications and bindings:

```sh
kubectl -n openshift-gitops get applications \
  -l argocd.argoproj.io/application-set-name=cluster-config
oc -n openshift-gitops get application cluster-admins
oc get group ai-grid-admins
oc get clusterrolebinding cluster-admin-ai-grid-admins
```

The `cluster-admins` query should return `NotFound` after migration.
