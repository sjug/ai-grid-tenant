# MaaS OIDC smoke test

This directory contains a browserless smoke test for the MaaS external-OIDC
flow through the single-broker `saas` realm.

## Prerequisites

- Access to the cluster through `kubectl`.
- `kubectl`, `curl`, `jq`, `sed`, and `awk` installed locally.
- A MaaS subscription that is synchronized and healthy.
- A test user provisioned by the Keycloak setup (`alice`, `bob`, or `carol`).
- Access to the Keycloak Secret containing the redirect URI registered for the
  `tenant-demo` OIDC client.

## Run

The script reads the registered OIDC redirect URI from the Keycloak Secret.
Override it only when using a different registered URI:

```sh
REDIRECT_URI='<registered-redirect-uri>' \
  docs/maas-oidc-smoke/scripts/maas-oidc-smoke.sh alice
```

Run the smoke test for a tenant administrator:

```sh
docs/maas-oidc-smoke/scripts/maas-oidc-smoke.sh carol
```

Discover the MaaS Gateway through another Kubernetes context by setting
`GATEWAY_KUBE_CONTEXT`. Keycloak values are still read from the current
context:

```sh
GATEWAY_KUBE_CONTEXT='<context-name>' \
  docs/maas-oidc-smoke/scripts/maas-oidc-smoke.sh alice
```

Run it for the user-subject authorization policy:

```sh
docs/maas-oidc-smoke/scripts/maas-oidc-smoke.sh bob
```

By default, the script discovers the Keycloak issuer from the
`keycloak-public-url` ConfigMap. It selects the MaaS Gateway HTTP Host from the
listener hostname matching `GATEWAY_PROTOCOL`, falling back to the Gateway
status address. It connects to the Gateway status address, falling back to the
selected host. Set `GATEWAY_HOST` to override the HTTP Host, and
`GATEWAY_CONNECT_ADDRESS` to override the connection target; the latter may
include a port. Both values must be hosts, not complete URLs.

The inference prompt, token limit, and other cluster resource names and
namespaces can be overridden with the
environment variables listed by the script's usage output:

```sh
docs/maas-oidc-smoke/scripts/maas-oidc-smoke.sh --help
```

The rate-limit test uses the selected subscription's smallest finite token
rate limit. It sizes a generated prompt from the tokens already reported by
the successful inference request, exhausts the remaining quota, and expects a
follow-up completion to return HTTP `429`. Because token usage is reported
after a response, the probe retries up to `RATE_LIMIT_PROBE_ATTEMPTS` times.
The test is skipped when the dynamically sized prompt would exceed
`RATE_LIMIT_MAX_PROMPT_TOKENS`, avoiding an unsafe request payload.

The result lists every skipped stage. For alice and bob, inference is required:
a run that skips it fails instead of reporting a pass. Carol checks inventory
only. Set `REQUIRE_INFERENCE=0` or `1` to override that, and `EXPECT_MODEL` to
fail unless inference uses a given model.

## What the test verifies

The script:

1. Discovers the Keycloak and MaaS Gateway endpoints from cluster resources.
2. Authenticates the selected user through the configured identity broker.
3. Exchanges the authorization code for an OIDC access token.
4. Calls `/v1/me` and `/v1/subscriptions`.
5. Creates a one-hour ephemeral API key when the user has an owner-accessible
   subscription.
6. Calls `/v1/api-keys/search` and verifies that a newly created key is listed.
7. Asks for approval, then sends an OpenAI-compatible completion request.
8. Asks for approval, then exhausts and verifies the selected subscription's
   finite token rate limit when it is small enough to test safely.

For `alice` and `bob`, the test expects one owner-accessible subscription,
creates an ephemeral API key, verifies that the key appears in the search
result, and uses that key for one inference request. For `carol`, the test
expects one organization-admin inventory subscription, skips API-key creation,
and skips inference because organization-admin visibility does not grant an
inference credential.

## Inference approval

Before sending the inference and rate-limit requests, the script stops and
describes each action: the endpoint, model, prompt or configured quota, and use
of the newly created ephemeral API key. Each request is sent only after an
interactive `y` or `yes` response.

For an unattended run where an explicit approval has already been given outside
the script, set:

```sh
export ASSUME_YES=1
```

## Runtime files

Successful runs write private runtime credentials under `/tmp`:

- `/tmp/maas-alice-access-token`
- `/tmp/maas-bob-access-token`
- `/tmp/maas-carol-access-token`
- `/tmp/maas-alice-api-key`
- `/tmp/maas-bob-api-key`
- `/tmp/maas-carol-api-key`

Remove these files when they are no longer needed. API keys created by the
script expire after one hour.

## GitOps and secret safety

The script does not change Kubernetes desired state and does not commit
cluster endpoints, API URLs, kubeconfig contexts, client secrets, user
passwords, tokens, or API keys. It only reads Kubernetes resources and invokes
the MaaS APIs. The ephemeral API key is runtime application data, not GitOps
configuration.
