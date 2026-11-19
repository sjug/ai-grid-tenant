# RHOAI prerequisites

This app distributes the RHOAI installation prerequisites to the AI Grid members,
the clusters labelled `ai-grid/enabled=true`, and to the hub, which pulls the
grid-bootstrap image from the same registry. Other managed clusters get nothing:

- the protected `redhat-ai-grid` and `redhat-ods-operator` Namespaces;
- image-mirror enforcement on conventional clusters and validation of service-managed
  mirror mappings on hosted control planes;
- the `openshift-marketplace/rhoai-catalog-pull-secret` required to pull the
  RHOAI catalog image;
- merged worker credentials (`openshift-config/pull-secret` on conventional
  clusters, `kube-system/additional-pull-secret` on hosted control planes)
  for `quay.io/rhoai` mirrored operator-bundle pulls, and for every other registry the hub
  Secret holds, such as `registry.stage.redhat.io` for the
  `registry.redhat.io/rhaii*` mirrors that model images pull through.
- the Limitador Redis configuration, on remote ingress and combined sites only, that shares MaaS rate-limit
  counters through the Submariner service import.
- the hub-only addon registration of `rhai-metrics` and of `ai-grid-dashboard-platform-metrics`
  (the GPU metric the AI Grid dashboards need beyond ACM's default list) and, on enabled grid sites,
  the NetworkPolicy admitting the local ACM agents to each RHOAI collector's
  HTTPS exporter on port 8889. It retries until RHOAI creates its monitoring
  namespace and replaces the hub-only policy in `ai-grid-o11y`; the initial
  prune/reconcile handoff can briefly interrupt these scrapes. Do not also
  deploy an ApplicationSet managing that NetworkPolicy. Only the addon's copied
  scrape pool keeps targets, preventing duplicate collection on the hub.
  Removing the registration policy does not withdraw its addon tuple; that
  requires a separate migration preserving the other configs.
- temporary cert-manager permissions for the OpenTelemetry operator on enabled Grid sites
  with role `ingress`, `inference` or `combined`, including an enabled hub.
- the catalog ServiceAccount's `imagePullSecrets` wiring is managed by
  `apps/rhoai/catalog`; OLM does not update an already-created catalog
  ServiceAccount when `CatalogSource.spec.secrets` changes.

The Quay credentials are never stored in Git. The pull-secret policy uses an
ACM hub template to check for `rhoai-prerequisites/rhoai-quay-pull-secret`
before rendering the remote Secret. Until that hub Secret exists and contains
a non-empty `.dockerconfigjson` key, the pull-secret policy has no remote
object templates and makes no changes on managed clusters. The image mirror is
still distributed because it does not contain credentials.

## Clean-cluster flow

`bootstrap.sh` seeds only the hub-side credential Secret. The root
ApplicationSet then discovers this app, ACM applies the prerequisites to the hub and
to each cluster as it gains the `ai-grid/enabled` label, and the RHOAI ApplicationSet
deploys after them. Worker credentials are distributed by policy; HCP additionally
requires the supported worker sync mechanism described below. Conventional clusters
receive mirror configuration directly. Hosted control planes require service-managed
mirror configuration before installation; see
[hosted control plane image mirrors](#hosted-control-plane-image-mirrors).

The global pull-secret policy is idempotent. It reads the current target
Secret, preserves unrelated credentials and Docker config fields, and
updates hub-managed registry entries: `quay.io/rhoai` from the Quay credential
and any other registry the hub Secret holds. A bare `quay.io` entry in the hub
Secret is applied only as `quay.io/rhoai`, so the cluster's own `quay.io` login
stays. On conventional control planes, updating the global Secret triggers
the normal Machine Config Operator rollout. Hosted control planes use the
worker syncer described below.

## Worker credentials on hosted control planes

For `Infrastructure/cluster.status.controlPlaneTopology: External`, the global
pull-secret policy creates or updates `kube-system/additional-pull-secret`.
Updating only the guest's `openshift-config/pull-secret` does not supply the
credentials through the HCP worker syncer. The policy preserves existing
additional credentials and Docker config fields, scopes a bare Quay entry to
`quay.io/rhoai`, and lets hub-supplied entries replace older entries for the
same registry. Missing or empty catalog credential input makes no changes.

HCCO merges the additional Secret with the original HostedCluster pull secret.
At this second merge, **original HostedCluster entries win exact registry-key
conflicts**. A scoped `quay.io/rhoai` entry can coexist with an original broad
`quay.io` entry. The policy does not manage `original-pull-secret`, the generated
`global-pull-secret`, or the HostedCluster secret. It does not prune previously
managed Secrets on topology changes or policy removal.

This path requires the global pull-secret feature and eligible workers. The
[HyperShift 4.22 procedure](https://github.com/openshift/hypershift/blob/release-4.22/docs/content/how-to/common/global-pull-secret.md)
describes the requirements: AWS/Azure Replace NodePools use
`hypershift.openshift.io/nodepool-globalps-enabled=true`; Karpenter nodes use
`karpenter.sh/nodepool`. InPlace and other workers may have no sync pods.
A DaemonSet object alone does not establish worker coverage. Verify the
supported mechanism for your platform and version before installation; do not
manually label ineligible nodes to force the syncer onto them.

Credential changes cause the syncer to update eligible workers' kubelet
configuration and restart kubelet. Plan for this rollout. Mirror mappings
remain a separate prerequisite ([RHAI-18761](https://redhat.atlassian.net/browse/RHAI-18761)).
Use credentials for the actual mirror registry, rather than adding Quay or
stage credentials under `registry.redhat.io` aliases. Direct pulls of protected
`registry.redhat.io` images still require that registry's valid credentials;
existing entries are preserved.

Verify metadata and worker coverage without displaying credential payloads:

```sh
kubectl --context "$SPOKE_CONTEXT" -n kube-system get secrets \
  additional-pull-secret global-pull-secret \
  -o custom-columns='NAME:.metadata.name,TYPE:.type'
kubectl --context "$SPOKE_CONTEXT" -n kube-system get daemonset global-pull-secret-syncer
kubectl --context "$SPOKE_CONTEXT" -n kube-system get pods \
  -l name=global-pull-secret-syncer -o wide
kubectl --context "$SPOKE_CONTEXT" get nodes \
  -L hypershift.openshift.io/nodepool-globalps-enabled,karpenter.sh/nodepool
kubectl --context "$SPOKE_CONTEXT" -n rhoai-prerequisites \
  get configurationpolicy rhoai-global-pull-secret
```

Confirm every intended worker is covered and Ready. Then validate a fresh
mirrored image pull and the RHOAI operator's installed CSV. Secret presence,
policy compliance and direct registry access alone do not establish that
worker pulls succeed. If OLM has a terminal extraction failure from before
credential delivery, identify that failed Job/cache and follow scoped recovery
after delivery is verified; do not broadly remove Subscriptions or CSVs.

Deleting `additional-pull-secret` makes HCCO remove its generated merged Secret
and return eligible workers to original credentials. This policy recreates the
additional Secret while enabled, so withdrawal requires an explicit GitOps
ownership change. Do not delete shared additional credentials as a rollback.

Run the local fixture rendering checks with Helm and PyYAML:

```sh
python3 apps/rhoai-prerequisites/tests/pull-secret-test.py
```

## Hosted control plane image mirrors

On clusters whose `Infrastructure/cluster.status.controlPlaneTopology` is
`External`, image mirrors are owned by the hosting service. ROSA HCP admission
rejects guest-cluster creation, update or deletion of ImageDigestMirrorSets.
Configure digest mirrors through the supported service API before RHOAI
installation; additional guest RBAC does not bypass that restriction.

For ROSA HCP, authenticate `rosa` against the cluster's OCM environment and
select the target HCP cluster. These commands were checked with ROSA CLI 1.2.67:

```sh
export ROSA_CLUSTER='<hcp-cluster-name-or-id>'
rosa list image-mirrors --cluster "$ROSA_CLUSTER" -o json
```

Inspect existing records first. For each missing source, create its mapping:

```sh
rosa create image-mirror --cluster "$ROSA_CLUSTER" \
  --source registry.redhat.io/rhoai --mirrors quay.io/rhoai
rosa create image-mirror --cluster "$ROSA_CLUSTER" \
  --source registry.redhat.io/rhaii --mirrors registry.stage.redhat.io/rhaii
rosa create image-mirror --cluster "$ROSA_CLUSTER" \
  --source registry.redhat.io/rhaii-early-access --mirrors registry.stage.redhat.io/rhaii-early-access
rosa create image-mirror --cluster "$ROSA_CLUSTER" \
  --source registry.redhat.io/rhaii-fast --mirrors registry.stage.redhat.io/rhaii-fast
```

If a source already exists, retain its record and use
`rosa edit image-mirror --cluster "$ROSA_CLUSTER" --id '<mirror-id>' --mirrors '<complete-mirror-list>'`
when an update is needed. Editing replaces the mirror list; preserve any
existing mirrors that are still required rather than creating duplicate sources.

The `rhoai-image-mirror` ConfigurationPolicy renders an unnamed object template
on External control planes. ACM evaluates unnamed templates in inform mode,
even though this shared policy otherwise enforces prerequisites. It checks for
one ImageDigestMirrorSet containing all four mappings, without creating or
changing the service-owned resource or requiring its name to be `quay-registry`.
Missing mappings remain NonCompliant. Mappings split across multiple IDMS
objects are not covered by this check. Inspect the service's resulting objects:

```sh
kubectl --context "$SPOKE_CONTEXT" get imagedigestmirrorsets -o yaml
kubectl --context "$SPOKE_CONTEXT" -n rhoai-prerequisites \
  get configurationpolicy rhoai-image-mirror
```

Conventional control planes retain named `quay-registry` enforcement with
`NeverContactSource`. The ROSA CLI does not expose an equivalent fallback-policy
setting, so the HCP check does not require `mirrorSourcePolicy` or claim the
same source-fallback behavior. The policy retains `pruneObjectBehavior: DeleteAll`
to preserve existing conventional-cluster cleanup behavior. Live pruning of matched
unnamed HCP resources and named-to-unnamed transitions remains to be verified.

Worker credentials come from the
[HCP pull-secret path above](#worker-credentials-on-hosted-control-planes),
implemented in PR #230 for [RHAI-18763](https://redhat.atlassian.net/browse/RHAI-18763).
A Compliant mirror policy alone does not establish that mirrored image pulls succeed.

Run the local rendering checks with Helm and PyYAML:

```sh
python3 apps/rhoai-prerequisites/tests/image-mirror-test.py
```

## OpenTelemetry cert-manager compatibility

The compatibility grant uses `openshift-opentelemetry-operator`, explicitly set in
`apps/rhoai/values.yaml`. A custom operator namespace requires updating the policy's
ServiceAccount subject as well. The grant mirrors [RHOAI's supplemental RBAC](https://github.com/opendatahub-io/odh-observability/blob/f7050b59693a1a12da127cbb757d75fa4d125ef5/charts/odh-observability/templates/opentelemetry-cert-manager-rbac.yaml).

OTel caches cert-manager discovery and authorization at startup; Argo sync waves
do not guarantee these prerequisites are ready first. If OTel started too early,
confirm policy compliance, cert-manager API availability and operator permissions.
Replace webhook pods one at a time, maintaining a Ready serving replica and
waiting for each replacement to be Ready; verify webhook
endpoints, then replace controller pods one at a time and wait for readiness.
OLM can revert `rollout restart`.
Allow RHOAI to retry, then verify collector/allocator readiness, Certificates,
Monitoring Ready at its current generation, and collector scrape targets.

Retire the workaround only after equivalent product-owned access is verified.
The policy retains its RBAC on deletion or deselection; explicitly remove the
compatibility ClusterRoleBinding and ClusterRole through GitOps during retirement.

## Shared Limitador Redis

`apps/limitador-redis` owns the Redis instance and its local Limitador storage
configuration on the hub. On every other managed cluster, the
`rhoai-limitador-redis` Policy creates the `limitador-redis` namespace needed
for the Submariner `ServiceImport`, the `kuadrant-system/limitador-redis`
Secret, and the `Limitador/limitador` Redis storage reference. Remote
Limitadors therefore use:

```text
redis://limitador-redis-master.limitador-redis.svc.clusterset.local:6379
```

The local Redis NetworkPolicy permits Submariner GlobalNet traffic
(`242.0.0.0/8`). The policy intentionally excludes the hub so the
existing local Argo Application remains the sole owner of the Redis and local
Limitador storage resources.

## Create the hub Secret

Set `RHOAI_QUAY_PULL_SECRET` to the base64-encoded `username:password` value
that can pull both the RHOAI catalog and operator-bundle repositories, then
run:

```sh
export HUB_CONTEXT='<hub-kubeconfig-context>'
read -s RHOAI_QUAY_PULL_SECRET
export RHOAI_QUAY_PULL_SECRET

apps/rhoai-prerequisites/create-hub-secret.sh
```

ACM watches the hub Secret and reconciles the policy after it is created or
updated. Removing the hub Secret does not delete an already-created pull Secret
on a managed cluster; this avoids accidentally removing credentials because of
a temporary hub-side Secret outage.

## Verify

Use metadata-only commands so the credential is not displayed:

```sh
kubectl --context "$HUB_CONTEXT" -n rhoai-prerequisites get secret rhoai-quay-pull-secret \
  -o custom-columns='NAME:.metadata.name,TYPE:.type'
kubectl --context "$HUB_CONTEXT" -n rhoai-prerequisites get placementdecisions
kubectl --context "$HUB_CONTEXT" get policies -n rhoai-prerequisites
kubectl --context "$SPOKE_CONTEXT" -n openshift-config get secret pull-secret \
  -o custom-columns='NAME:.metadata.name,TYPE:.type'
kubectl --context "$SPOKE_CONTEXT" -n rhoai-prerequisites get configurationpolicy \
  rhoai-global-pull-secret
kubectl --context "$SPOKE_CONTEXT" -n limitador-redis get serviceimport \
  limitador-redis-master
kubectl --context "$SPOKE_CONTEXT" -n kuadrant-system get limitador limitador \
  -o jsonpath='{.spec.storage.redis.configSecretRef.name}{"\n"}'
```
