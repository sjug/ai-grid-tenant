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

Run it for Bob's dedicated group policy:

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
follow-up chat completion to return HTTP `429`. Because token usage is reported
after a response, the probe retries up to `RATE_LIMIT_PROBE_ATTEMPTS` times.
The test is skipped when the dynamically sized prompt would exceed
`RATE_LIMIT_MAX_PROMPT_TOKENS`, avoiding an unsafe request payload.

The result lists every skipped stage. For alice and bob, inference is required:
a run that skips it fails instead of reporting a pass. Carol checks inventory
only. Set `REQUIRE_INFERENCE=0` or `1` to override that, and `EXPECT_MODEL` to
fail unless inference uses a given model.

## What the test verifies

The script records the broker issuer and subject. The isolation wrapper compares
subjects within that shared broker realm. It does not compare issuers.
The broker's local username is a storage handle and can differ from the
upstream `preferred_username`. The example tenant-2 policy grants Bob's
subscription through group `ai-grid-bob`, so Bob's access does not depend on
the literal username `bob`.

Set `BROKER_HINT` and `PASSWORD_SECRET_KEY` to select either example identity
provider while keeping the external username `alice`. Set `IDENTITY_ONLY=1` to
stop after the token exchange, `/v1/me`, `/v1/models`, and `/v1/subscriptions`. This mode
does not create API keys, call inference, or run the rate-limit probe. Set
`IDENTITY_RESULT_FILE` to write issuer, subject, organization, profile, and
subscription IDs, organization IDs, roles, and model names. The file is created with mode `0600` and never
contains tokens, passwords, client secrets, or API keys.

Use `scripts/identity-isolation-smoke.sh` to compare two companies that both
use the external username `alice`. Set `IDP_A`, `IDP_B`, `ORG_A`, `ORG_B`,
`PASSWORD_SECRET_KEY_A`, and `PASSWORD_SECRET_KEY_B`. The wrapper authenticates
A, B, A, and B. It requires distinct cross-company subjects and stable subjects
on repeat. For each company's first result, it requires `preferred_username=alice`
and nonempty organization and subscription lists restricted to the expected organization.
It does not test key ownership, cross-company key operations, profile renames,
or rejection of matching emails.

The wrapper currently reads the legacy `https://redhat.com/maas/orgs` array
from the token. This repository's realm emits flat `org_id`, `org_name`, and
`roles` claims. The wrapper's organization assertion fails for those tokens
until the script supports flat claims. The main script also prints organizations
from the legacy array, so that output omits flat organization claims.

For the reference providers, use `grid-tenant-1` and `grid-tenant-2` as the IdP aliases.
Their organization IDs are `42c3e46f-2477-44d7-a85b-d3b43f6b31fa` and
`53d4f57e-3588-55e8-b96c-4ec54a7c42fa`, respectively. Their password keys are
`GRID_TENANT_1_TEST_USER_PASSWORD` and `GRID_TENANT_2_TEST_USER_PASSWORD`.
This change requires freshly installed example realms, as described in the
[Keycloak README](../../apps/keycloak/README.md#deployment-scope).

Run the wrapper only in an authorized environment. Contributors run its input
checks and shell syntax checks; they do not run the live browserless login.

The script:

1. Discovers the Keycloak and MaaS Gateway endpoints from cluster resources.
2. Authenticates the selected user through the configured identity broker.
3. Exchanges the authorization code for an OIDC access token.
4. Calls `/v1/me` and `/v1/models` with the OIDC token.
5. Calls `/v1/subscriptions`.
6. Creates a one-hour ephemeral API key when the user has an owner-accessible
   subscription.
7. Calls `/v1/api-keys/search` and verifies that a newly created key is listed.
8. Calls `/v1/models` with the ephemeral API key when one was created.
9. Asks for approval, then sends an OpenAI-compatible chat completion request.
10. Asks for approval, then exhausts and verifies the selected subscription's
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

Identity-only runs also write the access-token file. The isolation wrapper
uses `alice` for both companies, so `/tmp/maas-alice-access-token` contains the
last login's token. Its temporary identity-result files are removed on exit.

## GitOps and secret safety

The script does not change Kubernetes desired state and does not commit
cluster endpoints, API URLs, kubeconfig contexts, client secrets, user
passwords, tokens, or API keys. It only reads Kubernetes resources and invokes
the MaaS APIs. The ephemeral API key is runtime application data, not GitOps
configuration.
