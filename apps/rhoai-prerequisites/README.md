# RHOAI prerequisites

This app distributes the RHOAI installation prerequisites to every cluster
in the reserved `global` ACM cluster set:

- the protected `redhat-ai-grid` and `redhat-ods-operator` Namespaces;
- the same `ImageDigestMirrorSet` used by the hub;
- the `openshift-marketplace/rhoai-catalog-pull-secret` required to pull the
  RHOAI catalog image;
- merged `openshift-config/pull-secret` entries for `quay.io/rhoai`, required
  for mirrored operator-bundle pulls, and for every other registry the hub
  Secret holds, such as `registry.stage.redhat.io` for the
  `registry.redhat.io/rhaii*` mirrors that model images pull through.
- the remote-only Limitador Redis configuration that shares MaaS rate-limit
  counters through the Submariner service import.
- the hub-only `rhai-metrics` addon registration and, on enabled grid sites,
  the NetworkPolicy admitting the local ACM agents to each RHOAI
  collector's HTTPS exporter on port 8889. The policy retries until RHOAI creates
  its monitoring namespace. It replaces the hub-only policy in `ai-grid-o11y`;
  allow for a brief prune/reconcile handoff during the first sync. Do not also
  deploy an ApplicationSet managing the same NetworkPolicy. Removing the
  registration policy does not remove the addon's tuple: withdrawal requires a
  separate migration that preserves the other addon configs.
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
ApplicationSet then discovers this app, ACM applies the prerequisites to every
cluster in the `global` cluster set, and the RHOAI ApplicationSet deploys after
them. No per-cluster `rosa`, `ocm`, or pull-secret command is required when a
managed cluster joins.

The global pull-secret policy is idempotent. It reads the current
`openshift-config/pull-secret`, preserves every existing credential, and
adds the hub-side entries it lacks: `quay.io/rhoai` from the Quay credential,
and any other registry the hub Secret holds. A bare `quay.io` entry in the hub
Secret is applied only as `quay.io/rhoai`, so the cluster's own `quay.io` login
stays. Updating that Secret triggers the normal Machine Config
Operator rollout to each node.

## Shared Limitador Redis

`apps/limitador-redis` owns the Redis instance and its local Limitador storage
configuration on `local-cluster`. On every other managed cluster, the
`rhoai-limitador-redis` Policy creates the `limitador-redis` namespace needed
for the Submariner `ServiceImport`, the `kuadrant-system/limitador-redis`
Secret, and the `Limitador/limitador` Redis storage reference. Remote
Limitadors therefore use:

```text
redis://limitador-redis-master.limitador-redis.svc.clusterset.local:6379
```

The local Redis NetworkPolicy permits Submariner GlobalNet traffic
(`242.0.0.0/8`). The policy intentionally excludes `local-cluster` so the
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

## Application metrics

Enabled grid sites collect grid, Authorino, database and Redis metrics through
RHOAI's collector. Chart-owned monitors carry the scrape label; a policy adds
only that label to named existing operator monitors without owning their specs.
Removing the policy leaves those labels in place, so withdrawal must explicitly
remove the labels as well. Namespace-wide opt-in is not required.

A supplemental gateway monitor excludes the serving gateway's Istio request
families already collected by RHOAI. Kuadrant's full gateway and Limitador
monitors remain unlabelled to avoid duplicate collection. Existing gateway
policies admit the collector; grid metrics and Redis receive explicit access.
COO supplies RHOAI's MonitoringStack. Hub delivery uses `rhai-metrics` in
`ai-grid-o11y`.
