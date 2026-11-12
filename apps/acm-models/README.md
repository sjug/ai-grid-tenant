# Internal model deployments

This app owns the internal `LLMInferenceService` deployment and its
model-facing MaaS resources. Supporting namespaces, NetworkPolicies, and the
Grid `ExternalProvider` are owned by the RHOAI apps.

The sample model goes to AI Grid sites where models run (Placement
`ai-grid-inference`), and its MaaS objects to sites that run MaaS
(`ai-grid-ingress`); both Placements are `apps/ai-grid-spokes`'. An unlabelled
hub gets neither.

## Scheduler metrics

The Gateway's serving configuration enables `publishMetrics: true`, so the
model controller publishes each provider's metrics endpoint from the scheduler
Service and its metrics port. The RHOAI prerequisites policy admits
`redhat-ai-grid` to that port.

The model definitions enable the HTTPS listener with
`--metrics-cert-dir=/var/run/kserve/tls`, using the scheduler's existing serving
certificate. The controller image pinned in `apps/rhoai/values.yaml` declares
`appProtocol: https` from this setting and creates per-model ServiceMonitors
that verify the serving certificate. This image pin is temporary until the
platform payload includes that behavior.

The model controller then publishes HTTPS metrics with service-account token
authentication and the `openshift-service-ca.crt` trust bundle in the Grid
namespace. Plaintext token transport remains disabled. New model definitions
also need the metrics TLS argument until the platform's scheduler preset
provides it.

After reconciliation, verify the scheduler metrics Service declares HTTPS,
the provider's `metricsConfig.endpoint` uses HTTPS, and `MetricsAvailable=True`
reports `ScrapeSucceeded`. Prometheus target health alone does not prove the
Grid operator is successfully scraping provider metrics.

## The provider console's catalog

The provider console
([ai-grid-cloud/ai-grid-provider-console](https://github.com/ai-grid-cloud/ai-grid-provider-console))
saves models and subscriptions as commits to a catalog repository,
[sjug/ai-grid-catalog](https://github.com/sjug/ai-grid-catalog). That URL is the only
value another environment changes: it appears in the two AppProjects and the three ApplicationSets in
`hub/catalog-*`, and in the console's `apps/console/application.yaml`.

The `catalog-*` files in `hub/` deliver it to AI Grid spokes by role (Placements in `apps/ai-grid-spokes`):

| Catalog path | ApplicationSet | Namespace | Clusters |
|---|---|---|---|
| `catalog/clusters/<cluster>/` | `acm-models-catalog-models` | `ai-grid-internal-models` | Each `inference` or `combined` spoke that has a folder: the folder names are where models run |
| `catalog/ingress/` | `acm-models-catalog-ingress` | `models-as-a-service` | Each `ingress` or `combined` spoke, once the folder exists |
| `catalog/subscriptions/` | `acm-models-catalog-subscriptions` | `models-as-a-service` | Each `ingress` or `combined` spoke, once the folder exists |

An empty catalog repository generates no Applications, so it shows no errors before the console's first write.

The console's token can push to the catalog, so the catalog's Applications run in two AppProjects that admit only
that repository, no cluster-scoped kinds, and only the kinds the console writes:

- `acm-models-catalog-models`: LLMInferenceService and NetworkPolicy.
- `acm-models-catalog-maas`: ExternalModel, MaaSModelRef, MaaSSubscription and MaaSAuthPolicy.

A catalog file that collides with an object another Application manages, such as a sample model, stops that
cluster's catalog sync until it's fixed (`FailOnSharedResource`). The provider backend refuses to create a model
whose LLMInferenceService, NetworkPolicy, ExternalModel or MaaSModelRef another Application already deploys, and
names that Application.

### Moving a sample model into the catalog

One Application owns each object. To hand a sample model to the catalog:

1. Remove the model from this repository: its files under `apps/acm-models/<model>/` and `maas/externalmodels/`,
   and its Placement and ApplicationSet under `hub/`.
2. Wait for Argo CD to prune them. `acm-models-maas-<cluster>` deletes the ExternalModel and MaaSModelRef on each
   ingress spoke, and deleting the model's ApplicationSet deletes its Applications and their LLMInferenceService.
   Check that no LLMInferenceService of that name is left in `ai-grid-internal-models` on the inference spokes, and
   delete any by hand.
3. Create the model in the provider console. If the console created it before the sample was removed, its
   `acm-models-catalog-ingress-<cluster>` Application has stopped retrying: sync it once.
4. Check that the catalog's Applications are Synced, the console reports the model published, and a tenant's
   authenticated request reaches it.

MaaS has no entry for the model between steps 2 and 3, and a subscription that names it reports the
reference unavailable until the catalog's copy exists. smollm2-135m-instruct moved this way; the tenant
subscriptions in `maas/policies/` no longer name it.

Deletion differs by design. Deleting the models ApplicationSet, or a cluster's folder, leaves its models running
(`preserveResourcesOnDeletion`). Deleting an ingress or subscriptions Application deletes its MaaS objects with
it (the resources finalizer), so no access outlives its Application. A teardown can therefore leave a model running
with no MaaS entry: delete its LLMInferenceService by hand.

`apps/ai-grid-policies` reports the catalog's state back to the hub, where the console reads it:

- `ai-grid-models-status`: each LLMInferenceService is Ready.
- `ai-grid-catalog-status`: each MaaSModelRef and ExternalModel is Ready, and each MaaSSubscription and
  MaaSAuthPolicy is Active.

The model controller publishes InferenceProviders automatically. The gateway
backend entries in the RHOAI values files still need to match the providers
that each gateway serves. A catalog model can therefore report Ready before
its gateway backend is configured; model readiness alone does not prove that
requests through MaaS and the Grid gateway can reach it.

Keep anything privileged out of the catalog repository: whoever holds the console's token can write it.
