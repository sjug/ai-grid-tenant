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
  with role `ingress`, `inference` or `combined`, including an enabled hub, and a one-time
  OTel restart once cert-manager and those permissions are usable.
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
do not guarantee these prerequisites are ready first. If OTel starts too early,
its webhook denies RHOAI's mTLS collector until OTel restarts
([RHAI-49185](https://redhat.atlassian.net/browse/RHAI-49185)). The same Policy
restarts it once. The marker fires only once, so the `rhoai-otel-cert-manager-restart`
ConfigurationPolicy waits for established cert-manager CRDs, an available webhook, and the
expected OTel RBAC configuration. It checks those objects, not effective authorization:
- the `issuers`, `certificaterequests` and `certificates` cert-manager CRDs are `Established`;
- `cert-manager/cert-manager-webhook` has an available replica;
- the compatibility ClusterRole has a rule covering those resources and the grant's verbs;
- the ClusterRoleBinding references that ClusterRole and has OTel's ServiceAccount as a subject.

It then adds `AI_GRID_CERT_MANAGER_READY=true` to `spec.config.env` of the
`opentelemetry-product` Subscription. OLM rolls the operator's Deployments under their
rolling-update strategy; whether a webhook replica keeps serving depends on the site's replica
count. Every site gets this one rollout, including sites where OTel started on time. Leave `dependencies.opentelemetry.olm.config`
unset in `apps/rhoai/values.yaml`, so Argo does not replace that env list.

If a site still denies the collector after that rollout, recover by hand. First confirm
policy compliance, cert-manager API availability and operator permissions.
Replace webhook pods one at a time, maintaining a Ready serving replica and
waiting for each replacement to be Ready; verify webhook
endpoints, then replace controller pods one at a time and wait for readiness.
OLM can revert `rollout restart`.
Allow RHOAI to retry, then verify collector/allocator readiness, Certificates,
Monitoring Ready at its current generation, and collector scrape targets.

Retire the workaround only after equivalent product-owned access is verified.
The policy retains its RBAC and the Subscription's env var on deletion or deselection.
During retirement, remove the compatibility ClusterRoleBinding and ClusterRole through
GitOps. The leftover env var has no effect.

## Monitoring memory headroom

RHOAI's metrics collector and Prometheus are killed at their shipped memory limits on Grid sites
([RHOAIENG-104114](https://redhat.atlassian.net/browse/RHOAIENG-104114) for the collector). The collector's
`memory_limiter` is set to 4000 MiB while its container is limited to 256Mi, so the kernel kills it before the
limiter refuses data. Prometheus replicas recorded OOMKilled exits on all three sites at the 512Mi limit; the
2Gi limit leaves headroom for work such as WAL replay and compaction. Neither `DSCInitialization` nor
`Monitoring` has a field for these resources.

`set-monitoring-memory.sh` sets, on the two custom resources RHOAI's `Monitoring` controls:

| Object | Memory request | Memory limit | Shipped |
| --- | --- | --- | --- |
| `OpenTelemetryCollector/data-science-collector` | 2Gi | 6Gi | 256Mi / 256Mi |
| `MonitoringStack/data-science-monitoringstack` | 1Gi | 2Gi | 256Mi / 512Mi |

The collector limit is above the limiter's hard limit, so the shipped limiter can act. CPU values, pipelines,
replicas, retention and volumes are not touched. This adds 5 GiB of scheduled memory requests per site.

RHOAI's observability module reconciles both objects to its own configuration, so the same patch adds
`opendatahub.io/managed: "false"`: the module skips such an object when it deploys and when it garbage
collects. The consequence is that the module no longer updates these two objects. Compare both with the
product's render at every RHOAI payload change and at every change of `Monitoring` or of
`DSCInitialization.spec.monitoring` (collector replicas, retention, storage, exporters), and carry over what
changed.

The write is a script and not an enforcing policy because ACM creates a named `musthave` object that is
missing and retries a conflicting update on whatever object then has the name; an object created that way
would be opted out of the module for good. The script only patches an existing object, with one JSON Patch
that first tests the object's UID and resourceVersion, so the API server changes nothing unless that object
is still as it was read. Those preconditions cover the object, not its `Monitoring`: the script reads the
`Monitoring` before the patch and again afterwards, and reports success only if it is still the same one,
still controls the object, and neither is terminating. It stops at the first object it cannot bring to the
wanted state and read back, and when the object, or the namespace the `Monitoring` names, is no longer the
one the run started with, or a write that the API server acknowledged is not in place afterwards. It sends a
patch again only after the API server definitely rejected the previous one and the same object is at another
resourceVersion; a patch without an answer is never repeated. It appends
to `RECORD_FILE` what each object was before every write, ahead of the write, and then the outcome.

The `rhoai-monitoring-memory` Policy only informs. NonCompliant for a site is not by itself a reason to
patch: read the compliance message, then run `check` there. A template error also reports NonCompliant, and
a site where the object is absent, foreign or terminating renders nothing and reports Compliant.

Run it per site. `MONITORING_UID` binds the run to the site that is meant: read it there first, and every
action refuses a cluster whose `Monitoring` has another UID.

```sh
export KUBECONFIG=<site kubeconfig>
export MONITORING_UID="$(kubectl get monitorings.services.platform.opendatahub.io default-monitoring -o jsonpath='{.metadata.uid}')"
apps/rhoai-prerequisites/set-monitoring-memory.sh check
READY_FILE=<site>.ready apps/rhoai-prerequisites/set-monitoring-memory.sh watch 2400 > <site>.watch.log 2>&1 &
# wait for <site>.ready: both streams have delivered the objects' current state
RECORD_FILE=<site>.record.jsonl apps/rhoai-prerequisites/set-monitoring-memory.sh apply
```

`watch` lists each object and follows it from that list's resourceVersion; its `READY` line gives both UIDs
and baseline versions. It prints every event with UID, resourceVersion and values, and fails at once on a
change away from the wanted values after they were reached (`REVERTED`), a deleted or replaced object, a
watch error or a stream that ends early; at the end of its window it fails if either object never showed the
wanted values. Keep it running through the whole observation below and check its exit status. The
resourceVersion at which the API server acknowledged each patch, which `apply` prints and records, appears
in its log as the event that brings the wanted values.

Go on to the next site only when, on this one:

- `apply` exited 0 and the watch log shows the patch for each object that was changed;
- both objects carry the annotation and the values, and keep their CPU values and owner reference;
- the collector and Prometheus StatefulSets rolled, their pods are Ready with the new values, Prometheus kept
  its volumes, and no container has a new `OOMKilled` exit;
- `Monitoring` is Ready and the watch has run for five more minutes without ending.

A failed `apply`, a watch that ended, or a revert on a site that was already done stops the remaining sites.
Accept the change only when every watch ended with status 0 after its window and a target that only the
collector delivers has successful samples that keep arriving, checked 10 and 30 minutes after the last site
where the site's metrics are queried (on a Grid with ACM observability: the hub's query endpoint, by site
label). Ready pods and memory readings alone also pass while samples are dropped.

Run the local checks with Helm and PyYAML:

```sh
python3 apps/rhoai-prerequisites/tests/monitoring-memory-policy-test.py
apps/rhoai-prerequisites/tests/monitoring-memory-script-test.sh
```

To roll back a site, use its record. It has a `before` line for every write that was attempted, written ahead
of the write, and an `outcome` line once the object was settled. Only the outcome `patched by this run` says
that the API server acknowledged this run's write. An attempt whose outcome is `unresolved`, `as wanted after
a patch without an answer` (the state was verified, the writer was not established) or `as wanted, written by
another writer` needs a look at the live object and at who else writes it before anything is undone. For each
object the run changed, check that the live object still
has the recorded UID, then put back what the `before` line holds: the recorded memory request and limit, and
the annotation exactly as it was, removed if it was not present, otherwise with its recorded value. Without
the annotation the module restores its own values; confirm that and that the StatefulSet rolls and recovers.
Leave an object alone that the run did not change. The Policy then reports the site NonCompliant until
`16-monitoring-memory-policy.yaml` is removed through GitOps. Retire once the product sizes these workloads
or exposes their resources; restoring the shipped limits before then restarts the kills.

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
