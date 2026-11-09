# MaaS shared PostgreSQL database

This app defines the shared PostgreSQL database for `maas-api`. CloudNativePG
runs a three-instance writable cluster on the hub, and an ACM-generated
Argo CD Application defines a one-instance read-only replica for every other
registered managed cluster.

Generated Applications sync automatically and self-heal configuration drift,
but do not prune resources that are removed from Git. This keeps the initial
database rollout GitOps-managed without exposing existing database resources to
automated deletion.

## Topology

- The writable primary is `maas-db` in the `maas-db` namespace on
  the hub.
- The `maas-db-rw` Service is exported through Submariner as
  `maas-db-rw.maas-db.svc.clusterset.local`.
- The primary server certificate includes the Submariner service name so remote
  replicas can use `sslmode=verify-full`.
- Every managed cluster gets the Submariner add-on through the
  `acm-submariner` ApplicationSet, so new clusters are onboarded automatically.
- Each remote cluster runs `maas-read`, a CloudNativePG replica cluster using
  `pg_basebackup` and continuous TLS streaming replication.
- The hub exposes `maas-read-ro` and `maas-read-r` as ExternalNames to
  its local CloudNativePG read-only Service. Every cluster therefore has the
  same read endpoint; `maas-read-r` is the name a remote site's one-instance
  replica cluster can actually serve (its only instance carries `role=primary`,
  so CloudNativePG's `-ro` Service there has no endpoint while `-r` does).
  `maas-db-config` names the second:

```text
maas-read-r.maas-db.svc.cluster.local:5432
```

- `maas-api` reads `maas-db-config` from its own namespace. The Secret has
  `DB_CONNECTION_URL` for the writable service and
  `DB_READ_CONNECTION_URL` for the local read-only service.
- CloudNativePG generates the replication client certificate, CA, and
  application credentials on the hub. ACM policies copy them to remote
  clusters without storing plaintext secrets in Git.
- New managed clusters are selected automatically through the `global` cluster
  set. Argo CD creates a replica Application for each ACM-registered cluster.

## Switching the read endpoint

`maas-db-config` names `maas-read-r`. A deployment that still names
`maas-read-ro` switches in two steps, because a maas-api that restarts after
the Secret changes resolves the new name at once:

1. Deploy the alias (`primary/31-read-service-r.yaml`) and let it
   reconcile on every site. Then run the gate against the hub and every ingress
   or combined site; it checks that `maas-read-r` exists, has ready endpoints
   (the hub's through its ExternalName target) and answers an authenticated
   read from inside a database pod:

   ```sh
   apps/maas-db/check-read-alias.sh <hub kubeconfig> <site kubeconfig>...
   ```

2. Only when every site reports `ready`, deploy the policies that name
   `maas-read-r` (the maas-db policy and the external-services policy).

On a fresh install both arrive together: the credentials policy (wave 3) may
write the Secret before the database Application (wave 5) has created the
Service, and reads fail until it exists, exactly as they did with the old name.
A site whose single replica instance is down has no read endpoint under either
name. Observed on a remote ingress site with its replica hibernated: API-key
reads through the MaaS entry kept answering and recovered without
intervention once the replica returned; which backend served them while the
replica was down could not be verified on that maas-api build.

## Rollout

The app depends on the existing ACM GitOps integration that creates Argo CD
cluster Secrets with the `apps.open-cluster-management.io/acm-cluster: "true"`
label. After pushing the app, Argo CD syncs `maas-db` automatically. The
ApplicationSet creates:

- `maas-db-<hub>` for the writable primary, on the hub whatever its
  labels. Every object it delivers (the CloudNativePG operator's Namespace,
  OperatorGroup and Subscription, the `Cluster`, its ServiceExport and read
  Service) carries `argocd.argoproj.io/sync-options: Delete=false`, so deleting
  the Application never deletes the database or its operator.
- One `maas-db-<cluster-name>` Application for each other site that runs
  `maas-api`: role ingress or combined (`apps/ai-grid-spokes`).

The replication-secret policy selects those sites; on the hub,
CloudNativePG owns the generated secrets directly. The API-credential policy
runs on every such site, the hub included, and creates or updates the
`maas-db-config` Secret expected by `maas-api`.

Unlike `rhoai`, the ApplicationSet doesn't preserve resources on deletion: a
replica is a full copy of every tenant's API keys and subscriptions, so a site
that leaves the grid, or the ingress role, loses it with its Application. The
primary is the exception above: removing the hub from the grid never touches
it.

Keep the API-credential policy enabled only after the writable primary and
local read endpoint have passed validation. If an older PostgreSQL instance is
already in use, export and restore its data into the new primary before
syncing this policy.

## Validation

After the generated Applications sync, verify their status:

```sh
kubectl get applications.argoproj.io -n openshift-gitops
kubectl get clusters.postgresql.cnpg.io -n maas-db
kubectl get policies.policy.open-cluster-management.io -n maas-db
```

On a remote cluster, confirm streaming replication:

```sh
kubectl get cluster maas-read -n maas-db -o jsonpath='{.status.phase}{"\n"}'
```

The phase should be `Cluster in healthy state`. Backups and point-in-time
recovery are not configured by this app and should be added before using the
database for production data.

After the writable primary and every read replica are healthy, validate
connectivity from the database namespace. The `maas-db-api-credentials` Policy
and PlacementBinding can then remain enabled to create or update
`maas-db-config` through GitOps.
