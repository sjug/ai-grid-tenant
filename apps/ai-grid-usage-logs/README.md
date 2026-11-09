# ai-grid-usage-logs

The delivery half of AI Grid MaaS usage logs. Each site's RHOAI collector
forwards usage records off-cluster; this app tells it where to send them and
gives it the credential to do so.

It renders no store, and keeps no copy of the store's settings.
`apps/ai-grid-o11y` owns all of it:

| Owned by `apps/ai-grid-o11y` | Where |
|---|---|
| the LokiStack — name, size, storage class, schemas, 30-day retention, the seven promoted stream labels | `manifests/lokistack.yaml` |
| the bucket | `manifests/obc-usage-logs-bucket.yaml` |
| the S3 Secret it is translated into | `manifests/job-provision-loki-key.yaml` + `manifests/rbac-provision-loki-key.yaml` |
| the writer identity | `manifests/sa-usage-logs-writer.yaml`, `clusterrole-…`, `clusterrolebinding-…` |
| the reader identity — `get` on the same tenant, for spoke-side consumers that query the store | `manifests/sa-usage-logs-reader.yaml`, `clusterrole-…`, `clusterrolebinding-…` |
| the Perses datasource and dashboard | `manifests/datasource-usage-logs-all.yaml`, `manifests/usage-logs-admin-dashboard.yaml` |

`values.yaml` here deliberately does **not** restate any of those. The chart can
render a store, so the toggles it would need are turned off explicitly —
`lokiStack.enabled`, `ingest.writer.create`, `ingest.reader.create` — while
`objectStorage` is left out altogether, since the chart already defaults
`obc.create` to false. Every other store key is absent too: a second copy would
diverge from that app silently while having no effect on what this app renders.

What this app adds is what that one lacks:

| | |
|---|---|
| `manifests/00-loki-operator.yaml` | The Loki operator. `apps/ai-grid-o11y` renders a LokiStack but ships no Subscription, and on a dedicated hub nothing else installs one — it otherwise arrives with the RHOAI chart's `dependencies.loki`, which a hub running no RHOAI never pulls in. |
| the chart's spoke Policy | Ships the writer token, patches each site's `DSCInitialization` with the exporter configuration, and delivers the read credential — query endpoint plus read-only token — to `redhat-ai-gateway-infra` on every selected site. |
| `manifests/20-hub-template-rbac.yaml` | Lets ACM resolve the Policy's hub templates: the ingest Route in `redhat-ods-monitoring`, and both credentials in `ai-grid-policies`. |
| `manifests/30-rbac-provision-usage-logs-tokens.yaml` | The identity both token-provisioning Jobs run as: minting tokens for the two `apps/ai-grid-o11y` ServiceAccounts, reading the store Route, and writing the credentials in `ai-grid-policies`. |
| `manifests/31-job-provision-usage-logs-writer-token.yaml` | Mints the writer token. |
| `manifests/32-job-provision-usage-logs-reader-token.yaml` | Mints the reader token and records the query endpoint. |

The ingest endpoint is an ACM hub template rather than a literal, because it is
the hub's own Route host and differs per fleet. `helm lookup` cannot supply it:
the Argo CD repo-server renders without cluster access.

## Token minting

The chart does not create the tokens, because a ServiceAccount token is not a
declarative object. Two PostSync Jobs mint them instead —
`manifests/31-job-provision-usage-logs-writer-token.yaml` and
`manifests/32-job-provision-usage-logs-reader-token.yaml` — running as the
ServiceAccount from `manifests/30-rbac-provision-usage-logs-tokens.yaml`.
ACM reads the Secrets with `fromSecret` and ships `$ocm_encrypted` ciphertext,
so the tokens never appear in a managed cluster's manifest.

Both Jobs are idempotent: they decode the stored token's JWT expiry and do
nothing while more than a week remains and (for the reader) the recorded
endpoint still matches the store Route. PostSync hooks run on every sync, so
repeated syncs do not rotate a healthy credential — while expiry, deletion of
the Secret, or a Route host change triggers a re-mint on the next sync. The
Policy re-resolves the Secret and each site picks up the new values, so
rotation is the same operation as creation. The lifetime is one year; the
cluster's `--service-account-max-token-expiration` may cap what is actually
issued.

The reader Job also records the query endpoint, derived from the store Route's
host because it differs per fleet and the Argo CD repo-server renders without
cluster access. It waits up to ten minutes for the Loki operator to publish
the Route's host rather than failing. The grant is `get` on the infrastructure
tenant only — no `create` — so a leaked reader token exposes usage records but
cannot corrupt them.

## Verify

Metadata-only, so the credential is not displayed:

```sh
# the hub credential exists and is non-empty
kubectl get secret usage-logs-hub-credential -n ai-grid-policies \
  -o go-template='{{.metadata.name}} {{.type}} {{len .data.token}} bytes (encoded){{"\n"}}'

# how long the issued token is good for
kubectl get secret usage-logs-hub-credential -n ai-grid-policies \
  -o jsonpath='{.data.token}' | base64 -d | cut -d. -f2 | base64 -d 2>/dev/null | \
  python3 -c 'import json,sys,datetime; print(datetime.datetime.fromtimestamp(json.load(sys.stdin)["exp"], datetime.UTC))'

# the Policy is delivering it
kubectl get policy ai-grid-maas-remote-usage-logs -n ai-grid-policies \
  -o jsonpath='{.status.compliant}{"\n"}'

# a site received it, and knows where to write
kubectl --context <site> get secret hub-usage-logs-auth -n redhat-ods-monitoring \
  -o jsonpath='{.metadata.name}{"\n"}'
kubectl --context <site> get dsci default-dsci \
  -o jsonpath='{.spec.monitoring.usageLogs.exporters.otlphttp/hub.endpoint}{"\n"}'

# a site's read consumer received the read credential
kubectl --context <site> get secret usage-logs-loki -n redhat-ai-gateway-infra \
  -o go-template='{{.metadata.name}} {{.type}}{{"\n"}}'

# and it can query the hub store with it
ENDPOINT=$(kubectl --context <site> get secret usage-logs-loki -n redhat-ai-gateway-infra \
  -o jsonpath='{.data.LOKI_READ_ENDPOINT}' | base64 -d)
TOKEN=$(kubectl --context <site> get secret usage-logs-loki -n redhat-ai-gateway-infra \
  -o jsonpath='{.data.LOKI_READ_TOKEN}' | base64 -d)
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  "${ENDPOINT}/loki/api/v1/labels"
```

`200` from the labels query means the read path works end to end; `403` means
the token is valid Kubernetes-wise but the reader identity's grant is missing.

A record pushed at a site collector's receiver should arrive in the hub store
with `cluster_name`, `model` and `service_name` promoted as stream labels.
