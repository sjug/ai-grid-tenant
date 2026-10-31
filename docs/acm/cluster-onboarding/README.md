# ACM managed-cluster onboarding

This directory documents the recommended way to import an existing OpenShift
cluster into ACM without putting cluster-specific data in this repository.

## Recommendation

Use a one-time, parameterized `clusteradm` import for the initial cluster
registration. After ACM accepts the cluster, the existing GitOps resources
discover it dynamically:

1. `../../../apps/acm-models/hub/gitops-cluster.yaml` selects every cluster in
   the reserved `global` cluster set and registers it with Argo CD.
2. The repository's ApplicationSets generate applications for each registered
   cluster. RHOAI, the provider gateway and the MaaS database replica wait for
   the `ai-grid/enabled=true` label:

   ```bash
   oc label managedcluster <name> ai-grid/enabled=true
   ```

   Give it a role too: `ingress` (MaaS, no models), `inference` (models, no
   MaaS) or `combined`. Without a role nothing is installed. See
   `apps/ai-grid-spokes/README.md`.

   ```bash
   oc label managedcluster <name> ai-grid/role=inference
   ```

   Then add AI projects and models: see [AI project onboarding](../ai-project-onboarding/README.md).

No `ManagedCluster`, join token, kubeconfig, API URL, or cluster name needs to
be committed to this repository. No values file per site either. The grid
operator derives the gateways' routing from the models each site publishes, so
one values file serves every site. A file named values-<cluster>.yaml is read
as an override when present.

## What the site must provide

- A default StorageClass. RHOAI monitoring claims 20Gi for metrics and 10Gi for
  traces on every site. An ingress or combined site claims 20Gi for its MaaS
  database replica. The sample models pull weights at start and claim nothing.
- Submariner gateway nodes. Every managed cluster gets the add-on with two
  gateways and Globalnet. Over it the site reaches the hub's enrollment service
  and the MaaS database primary.
- A default router the other sites can reach. Peers dial the provider gateway
  through it on 443 with TLS passthrough.
- DNS that returns valid AAAA records for the router's wildcard names, or
  NOERROR with an empty answer (NODATA) when the name has no IPv6 address, never
  NXDOMAIN for AAAA while A exists. The grid operator is a static musl binary;
  musl's resolver fails the whole lookup when either parallel query returns
  NXDOMAIN, while glibc clients (curl in the same pod) still connect, so a lab
  DNS that templates only A records leaves every GridSite Connecting. Check with
  `dig AAAA router-default.apps.<cluster>.<domain>`.
- For an ingress or combined site: the cluster trust (`proxy/cluster`
  `spec.trustedCA`) must include the MaaS home's ingress CA before the role is
  set, so the site's Authorino can reach the home's Keycloak Route.
- Capacity for the sample models: three replicas of 1 CPU and 10Gi memory. A
  GPU model needs GPU nodes and the NVIDIA operator, which this repository does
  not install.
- No registry setup. Policies deliver the pull Secrets and the image mirror.

Still per site, on the hub:

- The provider gateway NetworkPolicy CIDRs in apps/rhoai/provider-gateway.yaml,
  which must include the site's node network.

Peers discover this site on their own: the local-endpoints policy publishes
the site's GridSite from its admitted gateway and signals Routes, the
enrollment chart's observers distribute it to the other members, and the grid
operator reads models from the peer's provider catalog. A declared peer file
under apps/rhoai/local-cluster is a legacy fallback, not a step.

## Prerequisites

- Access to an ACM hub cluster and the target managed cluster in one
  kubeconfig.
- `kubectl`, `clusteradm`, and `jq` installed locally.
- A short, stable cluster name that follows DNS-1123 label rules. Avoid using
  a kubeconfig context or infrastructure hostname as the ACM cluster name.
- Enough capacity on the target cluster for the applications that the
  ApplicationSets deploy there.

## Import a cluster

Set the runtime inputs in your shell. For example:

```sh
export HUB_CONTEXT='<existing-hub-kubeconfig-context>'
export SPOKE_CONTEXT='<target-cluster-kubeconfig-context>'
export CLUSTER_NAME='<stable-acm-cluster-name>'
```

Preview and run the import:

```sh
docs/acm/cluster-onboarding/import-managed-cluster.sh \
  --hub-context "$HUB_CONTEXT" \
  --spoke-context "$SPOKE_CONTEXT" \
  --cluster-name "$CLUSTER_NAME"
```

After reviewing the summary, rerun the command with `--yes`. The script:

1. Validates that both kubeconfig contexts exist and the cluster name is
   DNS-1123 compliant.
2. Detects an existing `ManagedCluster` and resumes its registration instead
   of reinstalling the klusterlet.
3. Gets a hub join token only for a new import.
4. Installs the klusterlet on the target cluster.
5. Waits for the `ManagedCluster` to be created.
6. Accepts the cluster on the hub when `spec.hubAcceptsClient` is false.
7. Approves the cluster CSR when needed, including Red Hat ACM's
   `multicluster-engine` registration service account.
8. Waits for the `ManagedClusterJoined` condition.
9. Enables the `application-manager` add-on required by this repository's
   legacy `GitOpsCluster` integration.
10. Waits for Argo CD's cluster secret to be created.

The script is safe to rerun after a partial import. If the cluster is already
accepted and joined, it performs no registration changes and returns after
verifying the joined condition.

The script automatically requests a short-lived token from
`agent-registration-bootstrap` in either the upstream OCM namespace
(`open-cluster-management`) or the Red Hat ACM namespace
(`multicluster-engine`). Use `--registration-sa-namespace` only if your hub
stores that service account in another namespace.

For a hub behind a load balancer or NAT where the public `cluster-info`
endpoint is not usable, add `--force-internal-endpoint-lookup`.

## Verify GitOps discovery

After the script succeeds, check the hub:

```sh
kubectl --context "$HUB_CONTEXT" get managedclusters
kubectl --context "$HUB_CONTEXT" -n openshift-gitops get placementdecisions
kubectl --context "$HUB_CONTEXT" -n openshift-gitops get applications
```

The new cluster appears in the acm-models-gitops-cluster placement decision.
The role placements then generate its applications: rhoai for every role,
grid-provider-gateway and the sample model for inference and combined, maas-db
for ingress and combined. Application names carry the cluster name.

On the site, once the applications are Synced and Healthy:

```sh
oc get inferenceproviders
oc -n redhat-ai-grid get configmap grid-serving-grid-grid-gateway -o jsonpath='{.data.dial\.json}'
```

Each model's InferenceProvider is Available. The dial file lists each local
model with the serving gateway address on 443, a base path and a credential.

## Security and repeatability

- Do not commit kubeconfig contexts, cluster names, API URLs, or join tokens.
- Treat the join token as a short-lived secret.
- The script does not write the token to disk, but `clusteradm join` accepts
  the token as a command-line argument, so it can be visible in the local
  process list while that command runs.
- Prefer a separate kubeconfig for onboarding if that reduces credential
  exposure.

## Why the initial import is outside Git

Before a cluster is registered, the hub has no ACM agent or credentials for
that cluster. The initial trust exchange therefore requires unique runtime
material. Git can own the generic onboarding process and all post-registration
desired state, but it should not own the initial cluster-specific trust
secret.

For fleet-scale onboarding, alternatives include a parameterized pipeline that
calls this script, ACM Discovery with cloud credentials, or full
Hive/SiteConfig provisioning when ACM creates the cluster. Those alternatives
still require a careful decision about where credentials and cluster inventory
live; none of them is needed for a one-time import of an existing cluster.
