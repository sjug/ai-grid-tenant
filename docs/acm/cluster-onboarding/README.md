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

   Peers reach the provider gateway through the site's router, which the
   gateway's NetworkPolicy admits whether the router runs on the cluster network
   or on the host network (OVN-Kubernetes expands the ingress policy group to
   the nodes' management addresses). Only a site whose gateway sees peers as node
   machine addresses declares that network (IPv4 CIDR, `_` for `/`, prefix 1
   to 32), before the role label on a new site and before upgrading an existing
   one. To see what the gateway receives, dump the OVN conntrack entries for
   its pod address on the node that runs it (`ovs-appctl dpctl/dump-conntrack`
   in that node's ovnkube-node pod).

   ```bash
   oc label managedcluster <name> ai-grid/machine-network=192.0.2.0_24

   A site without a load-balancer provider also declares an L2 range for
   MetalLB (see `apps/metallb/README.md`); sites that have one skip this:

   ```bash
   oc label managedcluster <name> ai-grid/metallb-pool=192.0.2.10-192.0.2.50
   ```

   Then add AI projects and models: see [AI project onboarding](../ai-project-onboarding/README.md).

No `ManagedCluster`, join token, kubeconfig, API URL, or cluster name needs to
be committed to this repository. No values file per site either, beyond the
optional overrides a few apps accept (`apps/rhoai`, `apps/metallb`). The grid
operator derives the gateways' routing from the models each site publishes, so
one values file serves every site. A file named values-<cluster>.yaml is read
as an override when present.

## What the site must provide

- For an ingress or combined site whose external-services cluster serves Keycloak behind a
  privately signed ingress certificate: the cluster trust must include the
  external-services cluster's ingress CA before tenants use MaaS ("Trusting the
  external-services cluster's ingress CA" below): on a site that already runs
  Authorino, before the role changes; on a fresh site, right after the role
  label, since the ConfigMaps the trust step needs appear with the role's
  operators. With a publicly trusted certificate nothing is needed.

- If the platform ships and owns `openshift-operators-redhat`, the Loki operator's
  namespace (managed OpenShift such as OSD or ROSA), label the ManagedCluster
  `ai-grid/platform-namespaces=true` before the role is set, and label existing
  managed-OpenShift clusters before upgrading to this revision; the rhoai chart
  then leaves that namespace alone. A self-managed cluster, hub or spoke, keeps
  the default and the chart creates it. `redhat-ods-operator` is owned by the
  prerequisites policy on every site and is not affected by this label.

- On managed OpenShift (OSD, ROSA), hub or spoke: the namespaces
  `redhat-ai-grid` and `redhat-ods-operator`, created by a cluster
  administrator before you set the role. The platform's admission webhook
  `namespace-validation.managed.openshift.io` refuses `redhat-*` namespaces
  from the ACM policy, so until they exist the `rhoai-prerequisites` policy
  reports `rhoai-namespaces` NonCompliant. As that administrator:

  ```bash
  oc create namespace redhat-ai-grid
  oc create namespace redhat-ods-operator
  ```

  The policy then reports Compliant and manages them from there.

- A default StorageClass. RHOAI monitoring claims 20Gi for metrics and 10Gi for
  traces on every site. An ingress or combined site claims 20Gi for its MaaS
  database replica. The sample models pull weights at start and claim nothing.
- Submariner gateway nodes. Every managed cluster gets the add-on with two
  gateways and Globalnet. Label two workers `submariner.io/gateway=true` on each
  cluster, the hub included, because the add-on has no cloud credentials to do it. Over it the site reaches the hub's enrollment service
  and the MaaS database primary.
- A default router the other sites can reach. Peers dial the provider gateway
  through it on 443 with TLS passthrough.
- DNS that returns valid AAAA records for the router's wildcard names, or
  NOERROR with an empty answer (NODATA) when the name has no IPv6 address, never
  NXDOMAIN for AAAA while A exists. The grid operator is a static musl binary;
  musl's resolver fails the whole lookup when either parallel query returns
  NXDOMAIN, while glibc clients (curl in the same pod) still connect, so an
  A-only DNS configuration that incorrectly answers AAAA with NXDOMAIN (A-only
  itself is fine: answer NODATA) leaves every GridSite Connecting. Check with
  `dig AAAA router-default.apps.<cluster>.<domain>`.
- Capacity for the sample models: three replicas of 1 CPU and 10Gi memory. A
  GPU model needs GPU nodes and the NVIDIA operator, which this repository does
  not install.
- No registry setup. Policies deliver the pull Secrets and the image mirror.

## Trusting the MaaS home's ingress CA

Authorino on a MaaS site performs OpenID discovery against the MaaS home's
Keycloak Route and validates API keys against maas-api over the OpenShift
service CA. The RHOAI chart's `ai-grid-ingress` and `ai-grid-combined` profiles
mount three ConfigMaps for that: `odh-trusted-ca-bundle`,
`openshift-service-ca.crt`, and `home-keycloak-ca`.

When the hub is also the MaaS home, `rhoai-ingress-clusters` reads the hub's
default ingress certificate (`openshift-config-managed/default-ingress-cert`)
and creates `home-keycloak-ca` in `kuadrant-system` on every ingress or
combined site, under the key `home-keycloak-ca.crt`. The role values project
that ConfigMap directly into Authorino, and the Policy adds it to the Authorino
CR's volume contract so the operator and Argo CD agree. No site-wide
`proxy/cluster.spec.trustedCA` mutation is needed. The key is separate from
`odh-trusted-ca-bundle`'s `ca-bundle.crt` because both ConfigMaps project into
the same directory: a shared key would replace the system bundle, and a
Keycloak Route with a publicly signed certificate would then fail OIDC
discovery. With its own key, Authorino trusts both bundles.

When MaaS's shared state is on a dedicated cluster labelled
`ai-grid/external-services=true`, the hub cannot read that cluster's
`router-ca` Secret directly. The Policy therefore creates an empty
`home-keycloak-ca` placeholder so the Authorino volume contract remains valid,
and the real home CA must be added to the site's cluster trust. Use
`trust-external-services-ca.sh` with `KUBECONFIG` pointing at the site:

```
HOME_KUBECONFIG=<external-services cluster kubeconfig> KEYCLOAK_HOST=<Keycloak Route host> REALM=<MaaS realm> \
  docs/acm/cluster-onboarding/trust-external-services-ca.sh
```

An external-services cluster that replaced its default ingress certificate passes
`HOME_CA_FILE=<PEM bundle of the replacement's issuer>` instead of
`HOME_KUBECONFIG`. The script stops at the first failure and writes nothing
before every read has succeeded: it checks the two ConfigMaps, obtains and
validates the issuing CA, reads the bundle `proxy/cluster` names and any
existing `custom-ca` on their own (only NotFound counts as absent; a bundle
named by the proxy next to a separate `custom-ca` is refused rather than
hidden), validates every existing bundle, appends the CA, parses and
fingerprints the merged bundle, writes `custom-ca` and points `proxy/cluster`
at it, waits (bounded, default 15 minutes, every request and sleep capped to
the remaining budget) until every certificate of the merged bundle appears by
SHA-256 fingerprint in the mounted `odh-trusted-ca-bundle`, and finally
verifies a TLS connection to the external-services cluster's OpenID discovery document with
exactly that bundle. On a site that already runs Authorino, run it before
changing the role; on a fresh site the ConfigMaps appear with the role's
operators, so run it right after the role label and before onboarding
tenants.
`tests/trust-external-services-ca-test.sh` exercises it against stub `oc` and `curl`
binaries with real certificates.

The placeholder carries no certificate and does not extend trust. A site that
needs more CA ConfigMaps lists the complete set in
`apps/rhoai/values-<cluster>.yaml` under
`dependencies.rhcl.config.authorinoTrustedCA.configMaps`. The chart patches only
its named Authorino volume and leaves other Deployment volumes intact.

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

The script creates no `KlusterletAddonConfig`, so ACM installs no Search
collector by itself. The hub's `search-collector` policy
(`apps/acm/manifests/search`) adds it to every managed cluster but the hub
within a minute of the import, so ACM Search indexes the new cluster. A cluster
imported with a `KlusterletAddonConfig` keeps whatever that config says.

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
kubectl --context "$HUB_CONTEXT" -n "$CLUSTER_NAME" get managedclusteraddon search-collector
```

The new cluster appears in the acm-models-gitops-cluster placement decision.
Its `search-collector` add-on reports Available.
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
