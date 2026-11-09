# Cluster config

Cluster-level configuration managed separately from the workload apps under
`apps/`. The `apps` ApplicationSet discovers `cluster-config/application.yaml`,
which deploys the fleet-wide `cluster-config` ApplicationSet.

## Cluster admins

Grants `cluster-admin` to a Git-managed list of users through per-user
`ClusterRoleBinding` objects (`cluster-admin-<user>`). The list is per
deployment: [`values.yaml`](values.yaml) leaves it empty, and a deployment
lists its users in [`cluster-admins.yaml`](cluster-admins.yaml). Without that
file, the chart creates no binding. The `cluster-config`
ApplicationSet generates one automated Application for every cluster secret
created by the shared GitOpsCluster integration, including the hub.
The hub uses Argo CD's in-cluster destination so the controller's
ServiceAccount, rather than the ACM addon ServiceAccount, applies its RBAC.

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

Edit `cluster-admins.yaml` and commit. Every generated Application syncs
automatically (prune and self-heal are enabled):

- Adding a username to `cluster_admins` creates its `ClusterRoleBinding` on
  every ACM managed cluster on the next sync.
- Removing a username prunes its `ClusterRoleBinding`, revoking cluster-admin on
  every ACM managed cluster.

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

Generated Application names include the cluster name and a short hash, while
the chart renders deterministic `cluster-admin-<user>` binding names. Each
selected cluster therefore receives exactly one generated Application and one
binding per user, with no duplicate names.

The chart's Submariner gateway policy is hub-only ACM state. The
`hubResources.enabled` parameter is true only for the hub, so managed
clusters render only the fleet-wide RBAC and do not receive duplicate Policy,
Placement, or PlacementBinding resources.

### Constraints

- `cluster_admins` entries must be Kubernetes usernames that are also valid
  in a DNS-1123 resource name, because the username is embedded in the
  binding name. IdP-qualified usernames such as `user@domain` require a
  sanitized binding-name scheme before they can be listed.
- Bindings reference `kind: User` subjects. A subject that has never
  authenticated is inert until its first login; the binding itself is created
  regardless.
- All resources are cluster-scoped, so `spec.destination.namespace` is only
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
oc get clusterrolebindings \
  cluster-admin-khowell cluster-admin-aballant
```

The `cluster-admins` query should return `NotFound` after migration.
