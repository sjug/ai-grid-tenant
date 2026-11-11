#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: docs/maas-oidc-smoke/scripts/maas-oidc-smoke.sh USER

USER must be "alice", "bob", or "carol".

Environment overrides:
  GATEWAY_KUBE_CONTEXT   Kubernetes context used only to discover the MaaS
                         Gateway. Defaults to the current context.
  REDIRECT_URI           Redirect URI registered for the OIDC client. Defaults to
                         KEYCLOAK_REDIRECT_URI from the Keycloak secret.
  ASSUME_YES             Set to 1 to proceed without the inference and
                         rate-limit approval prompts.
  GATEWAY_HOST          MaaS Gateway hostname used for the HTTP Host header.
                         Defaults to the listener hostname for GATEWAY_PROTOCOL,
                         then the Gateway status address.
  GATEWAY_CONNECT_ADDRESS
                         Address curl connects to. Defaults to the Gateway
                         status address, then GATEWAY_HOST. May include a port.
  GATEWAY_PROTOCOL      Gateway protocol. Defaults to http.
  KEYCLOAK_NAMESPACE    Namespace containing the Keycloak secret. Defaults to maas-db.
  KEYCLOAK_SECRET_NAME  Secret containing Keycloak runtime values. Defaults to keycloak-secrets.
  KEYCLOAK_CONFIG_MAP_NAME
                         ConfigMap containing the Keycloak public URL. Defaults
                         to keycloak-public-url.
  GATEWAY_NAMESPACE     Namespace containing the MaaS Gateway. Defaults to openshift-ingress.
  GATEWAY_NAME          MaaS Gateway resource name. Defaults to maas-default-gateway.
  OIDC_CLIENT_ID        OIDC client ID. Defaults to tenant-demo.
  INFERENCE_PROMPT      Inference prompt. Defaults to a short deterministic smoke-test prompt.
  INFERENCE_MAX_TOKENS  Maximum tokens for the inference request. Defaults to 32.
  RATE_LIMIT_MAX_PROMPT_TOKENS
                         Maximum generated prompt-token target for the rate-limit
                         test. Defaults to 2048.
  RATE_LIMIT_DELAY_SECONDS
                         Delay between quota exhaustion and the 429 probe.
                         Defaults to 1.
  RATE_LIMIT_PROBE_ATTEMPTS
                         Maximum number of 429 probe requests. Defaults to 3.
  REQUIRE_INFERENCE     Set to 1 to fail when inference is skipped, 0 to allow it.
                         Defaults to 1 for alice and bob, 0 for carol.
  EXPECT_MODEL          Fail unless inference uses this model name.

Every skipped stage is listed in the result, and a run that skipped a required
stage fails.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

print_section() {
  printf '\n== %s ==\n' "$1"
}

skipped_stages=()

# Report a skipped stage and remember it for the result.
skip_stage() {
  printf '  skipped: %s\n' "$2"
  skipped_stages+=("$1")
}

confirm_action() {
  local action=$1
  local reply

  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi

  printf '\nApproval required\n%s\n' "$action" >&2
  printf 'Proceed? [y/N] ' >&2
  IFS= read -r reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

redirect_location() {
  awk 'tolower($1)=="location:" {
    sub(/^[Ll]ocation: */, "")
    sub(/\r$/, "")
    print
    exit
  }' "$1"
}

form_action() {
  sed -n 's/.*action="\([^"]*\)".*/\1/p' "$1" | head -1 | sed 's/&amp;/\&/g'
}

user="${1:-}"
[[ -n "$user" ]] || { usage >&2; exit 2; }
if [[ "$user" == "--help" || "$user" == "-h" ]]; then
  usage
  exit 0
fi

case "$user" in
  alice)
    broker_hint=grid-tenant-1
    password_key=GRID_TENANT_1_TEST_USER_PASSWORD
    ;;
  bob)
    broker_hint=grid-tenant-2
    password_key=GRID_TENANT_2_TEST_USER_PASSWORD
    ;;
  carol)
    broker_hint=grid-tenant-2
    password_key=GRID_TENANT_2_TEST_USER_PASSWORD
    # Carol checks inventory only.
    default_require_inference=0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

require_inference="${REQUIRE_INFERENCE:-${default_require_inference:-1}}"
[[ "$require_inference" == 0 || "$require_inference" == 1 ]] || fail "REQUIRE_INFERENCE must be 0 or 1"
expect_model="${EXPECT_MODEL:-}"

for cmd in kubectl curl jq sed awk; do
  require_cmd "$cmd"
done

keycloak_namespace="${KEYCLOAK_NAMESPACE:-maas-db}"
keycloak_secret_name="${KEYCLOAK_SECRET_NAME:-keycloak-secrets}"
keycloak_config_map_name="${KEYCLOAK_CONFIG_MAP_NAME:-keycloak-public-url}"
gateway_namespace="${GATEWAY_NAMESPACE:-openshift-ingress}"
gateway_name="${GATEWAY_NAME:-maas-default-gateway}"
gateway_kube_context="${GATEWAY_KUBE_CONTEXT:-}"
client_id="${OIDC_CLIENT_ID:-tenant-demo}"
gateway_protocol="${GATEWAY_PROTOCOL:-http}"
gateway_port=80
case "$gateway_protocol" in
  http) gateway_port=80 ;;
  https) gateway_port=443 ;;
esac
redirect_uri="${REDIRECT_URI:-}"
inference_prompt="${INFERENCE_PROMPT:-Reply with: MaaS OIDC inference succeeded.}"
inference_max_tokens="${INFERENCE_MAX_TOKENS:-32}"
rate_limit_max_prompt_tokens="${RATE_LIMIT_MAX_PROMPT_TOKENS:-2048}"
rate_limit_delay_seconds="${RATE_LIMIT_DELAY_SECONDS:-1}"
rate_limit_probe_attempts="${RATE_LIMIT_PROBE_ATTEMPTS:-3}"

case "$gateway_protocol" in
  http|https) ;;
  *) fail "GATEWAY_PROTOCOL must be http or https" ;;
esac
[[ "$inference_max_tokens" =~ ^[1-9][0-9]*$ ]] || fail "INFERENCE_MAX_TOKENS must be a positive integer"
[[ "$rate_limit_max_prompt_tokens" =~ ^[1-9][0-9]*$ ]] || fail "RATE_LIMIT_MAX_PROMPT_TOKENS must be a positive integer"
[[ "$rate_limit_delay_seconds" =~ ^[0-9]+$ ]] || fail "RATE_LIMIT_DELAY_SECONDS must be a non-negative integer"
[[ "$rate_limit_probe_attempts" =~ ^[1-9][0-9]*$ ]] || fail "RATE_LIMIT_PROBE_ATTEMPTS must be a positive integer"

keycloak_url=$(
  kubectl get configmap "$keycloak_config_map_name" -n "$keycloak_namespace" \
    -o jsonpath='{.data.KEYCLOAK_PUBLIC_URL}'
)
client_secret=$(
  kubectl get secret "$keycloak_secret_name" -n "$keycloak_namespace" \
    -o jsonpath='{.data.KEYCLOAK_CLIENT_SECRET}' | base64 -d
)
if [[ -z "$redirect_uri" ]]; then
  redirect_uri=$(
    kubectl get secret "$keycloak_secret_name" -n "$keycloak_namespace" \
      -o jsonpath='{.data.KEYCLOAK_REDIRECT_URI}' | base64 -d
  )
fi
password=$(
  kubectl get secret "$keycloak_secret_name" -n "$keycloak_namespace" \
    -o jsonpath="{.data.$password_key}" | base64 -d
)

[[ -n "$keycloak_url" ]] || fail "KEYCLOAK_PUBLIC_URL is empty in $keycloak_config_map_name"
[[ -n "$client_secret" ]] || fail "KEYCLOAK_CLIENT_SECRET is empty in $keycloak_secret_name"
[[ -n "$redirect_uri" ]] || fail "REDIRECT_URI is unset and KEYCLOAK_REDIRECT_URI is empty in $keycloak_secret_name"
[[ -n "$password" ]] || fail "$password_key is empty in $keycloak_secret_name"
keycloak_url="${keycloak_url%/}"

gateway_kubectl_args=()
if [[ -n "$gateway_kube_context" ]]; then
  gateway_kubectl_args=(--context "$gateway_kube_context")
fi

umask 077
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

gateway_json=""
gateway_error="$tmpdir/gateway-error.txt"
if [[ -z "${GATEWAY_HOST:-}" || -z "${GATEWAY_CONNECT_ADDRESS:-}" ]]; then
  if ! gateway_json=$(
    kubectl "${gateway_kubectl_args[@]}" get gateway "$gateway_name" -n "$gateway_namespace" -o json 2>"$gateway_error"
  ); then
    if [[ -n "${GATEWAY_HOST:-}" && -z "${GATEWAY_CONNECT_ADDRESS:-}" ]]; then
      gateway_json=""
    else
      gateway_error_message=$(tr '\n' ' ' < "$gateway_error")
      if [[ -n "$gateway_error_message" ]]; then
        fail "could not read MaaS Gateway ${gateway_namespace}/${gateway_name}: $gateway_error_message"
      else
        fail "could not read MaaS Gateway ${gateway_namespace}/${gateway_name}"
      fi
    fi
  fi
fi

if [[ -n "${GATEWAY_HOST:-}" ]]; then
  gateway_host="$GATEWAY_HOST"
else
  gateway_host=$(
    jq -r --arg protocol "$gateway_protocol" '
      [
        .spec.listeners[]?
        | select(((.protocol // .name // "") | ascii_downcase) == $protocol)
        | .hostname // empty
        | select(. != "")
      ][0] // empty
    ' <<<"$gateway_json"
  )
  if [[ -z "$gateway_host" ]]; then
    gateway_host=$(
      jq -r '[.status.addresses[]?.value // empty | select(. != "")][0] // empty' <<<"$gateway_json"
    )
  fi
fi

if [[ -n "${GATEWAY_CONNECT_ADDRESS:-}" ]]; then
  gateway_connect_address="$GATEWAY_CONNECT_ADDRESS"
else
  gateway_connect_address=$(
    jq -r '[.status.addresses[]?.value // empty | select(. != "")][0] // empty' <<<"$gateway_json"
  )
  if [[ -z "$gateway_connect_address" ]]; then
    gateway_connect_address="$gateway_host"
  fi
fi

[[ -n "$gateway_host" ]] || fail "could not determine the MaaS Gateway hostname"
[[ -n "$gateway_connect_address" ]] || fail "could not determine the MaaS Gateway connect address"
[[ "$gateway_host" != *"://"* && "$gateway_host" != *"/"* ]] ||
  fail "GATEWAY_HOST must be a hostname, not a URL"
[[ "$gateway_connect_address" != *"://"* && "$gateway_connect_address" != *"/"* ]] ||
  fail "GATEWAY_CONNECT_ADDRESS must be a host or host:port, not a URL"

base_url="${gateway_protocol}://${gateway_host}"

gateway_curl() {
  curl --connect-to "${gateway_host}:${gateway_port}:${gateway_connect_address}" "$@"
}

cookie_jar="$tmpdir/cookies.txt"
headers="$tmpdir/headers"
body="$tmpdir/body"

print_section "Runtime configuration"
printf '  user: %s\n' "$user"
printf '  Keycloak issuer: %s\n' "$keycloak_url/realms/saas"
printf '  Gateway host: %s\n' "$gateway_host"
printf '  Gateway connect address: %s\n' "$gateway_connect_address"
printf '  Gateway context: %s\n' "${gateway_kube_context:-current}"
printf '  Gateway: %s\n' "$base_url"
printf '  OIDC client: %s\n' "$client_id"
printf '  Redirect URI: %s\n' "$redirect_uri"

redirect_uri_encoded=$(jq -rn --arg value "$redirect_uri" '$value | @uri')
auth_url="$keycloak_url/realms/saas/protocol/openid-connect/auth?client_id=$client_id&redirect_uri=$redirect_uri_encoded&response_type=code&scope=openid%20profile%20email&kc_idp_hint=$broker_hint"

request_url="$auth_url"
while :; do
  curl -sS -k --max-time 20 \
    -b "$cookie_jar" -c "$cookie_jar" \
    -D "$headers" -o "$body" "$request_url"

  if grep -q '<form' "$body"; then
    break
  fi

  location=$(redirect_location "$headers")
  [[ -n "$location" ]] || fail "expected a login form or redirect from $request_url"
  request_url="$location"
done

action=$(form_action "$body")
[[ -n "$action" ]] || fail "could not extract the Keycloak login form action"

login_status=$(
  curl -sS -k --max-time 20 -X POST \
    -b "$cookie_jar" -c "$cookie_jar" \
    --data-urlencode "username=$user" \
    --data-urlencode "password=$password" \
    --data-urlencode 'credentialId=' \
    --data-urlencode 'login=Sign In' \
    -D "$headers" -o /dev/null -w '%{http_code}' "$action"
)
[[ "$login_status" == 2* || "$login_status" == 3* ]] || fail "Keycloak login returned HTTP $login_status"

location=$(redirect_location "$headers")
[[ -n "$location" ]] || fail "login did not return a redirect"

while [[ "$location" != "$redirect_uri"* ]]; do
  curl -sS -k --max-time 20 \
    -b "$cookie_jar" -c "$cookie_jar" \
    -D "$headers" -o /dev/null "$location"
  location=$(redirect_location "$headers")
  [[ -n "$location" ]] || fail "broker login stopped before the registered redirect URI"
done

code=$(printf '%s' "$location" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
[[ -n "$code" ]] || fail "the callback did not contain an authorization code"

token_response="$tmpdir/token-response.json"
token_status=$(
  curl -sS -k --max-time 20 -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data 'grant_type=authorization_code' \
    --data "client_id=$client_id" \
    --data-urlencode "client_secret=$client_secret" \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$redirect_uri" \
    -o "$token_response" -w '%{http_code}' \
    "$keycloak_url/realms/saas/protocol/openid-connect/token"
)

print_section "OIDC token exchange"
printf '  HTTP status: %s\n' "$token_status"
if [[ "$token_status" != 2* ]] || ! jq -e 'has("access_token") and (.token_type == "Bearer")' "$token_response" >/dev/null; then
  jq . "$token_response" >&2
  fail "token exchange failed"
fi

token_file="/tmp/maas-${user}-access-token"
jq -r '.access_token' "$token_response" > "$token_file"
claims="$tmpdir/claims.json"
jq -R 'split(".") | .[1] | @base64d | fromjson' "$token_file" > "$claims"

printf '  token file: %s\n' "$token_file"
printf '  subject: %s\n' "$(jq -r '.sub' "$claims")"
printf '  preferred username: %s\n' "$(jq -r '.preferred_username' "$claims")"
printf '  audience: %s\n' "$(jq -r '.aud | if type == "array" then join(", ") else . end' "$claims")"
printf '  authorized party: %s\n' "$(jq -r '.azp' "$claims")"

while IFS=$'\t' read -r organization roles; do
  printf '  organization: %s (roles: %s)\n' "$organization" "$roles"
done < <(jq -r '."https://redhat.com/maas/orgs"[]? | [.organization_id, (.roles // [] | join(", "))] | @tsv' "$claims")

mapfile -t groups < <(jq -r '.groups[]?' "$claims")
if (( ${#groups[@]} > 0 )); then
  printf '  groups:\n'
  for group in "${groups[@]}"; do
    printf '    - %s\n' "$group"
  done
fi

me_response="$tmpdir/me-response.json"
me_status=$(
  gateway_curl -sS --max-time 20 \
    -H "Authorization: Bearer $(cat "$token_file")" \
    -o "$me_response" -w '%{http_code}' \
    "$base_url/v1/me"
)

print_section "GET /v1/me"
printf '  HTTP status: %s\n' "$me_status"
if [[ "$me_status" != 2* ]]; then
  jq . "$me_response" >&2
  fail "/v1/me returned HTTP $me_status"
fi

printf '  user: %s (%s)\n' "$(jq -r '.name' "$me_response")" "$(jq -r '.preferred_username' "$me_response")"
printf '  email: %s\n' "$(jq -r '.email' "$me_response")"
while IFS=$'\t' read -r organization roles; do
  printf '  organization: %s (roles: %s)\n' "$organization" "$roles"
done < <(jq -r '."https://redhat.com/maas/orgs"[]? | [.organization_id, (.roles // [] | join(", "))] | @tsv' "$me_response")

oidc_models_response="$tmpdir/oidc-models-response.json"
oidc_models_status=$(
  gateway_curl -sS --max-time 20 \
    -H "Authorization: Bearer $(cat "$token_file")" \
    -o "$oidc_models_response" -w '%{http_code}' \
    "$base_url/v1/models"
)

print_section "GET /v1/models (OIDC)"
printf '  HTTP status: %s\n' "$oidc_models_status"
if [[ "$oidc_models_status" != 2* ]] || ! jq -e 'type == "object" and (.data | type == "array")' "$oidc_models_response" >/dev/null; then
  jq . "$oidc_models_response" >&2
  fail "OIDC model listing failed"
fi

oidc_models_count=$(jq '.data | length' "$oidc_models_response")
printf '  model count: %s\n' "$oidc_models_count"
if (( oidc_models_count == 0 )); then
  printf '  models: none\n'
else
  printf '  models:\n'
  while IFS=$'\t' read -r id owned_by; do
    printf '    - %s\n' "$id"
    printf '        owned by: %s\n' "$owned_by"
  done < <(jq -r '.data[] | [.id, (.owned_by // "")] | @tsv' "$oidc_models_response")
fi

subscriptions_response="$tmpdir/subscriptions-response.json"
subscriptions_status=$(
  gateway_curl -sS --max-time 20 \
    -H "Authorization: Bearer $(cat "$token_file")" \
    -o "$subscriptions_response" -w '%{http_code}' \
    "$base_url/v1/subscriptions"
)

print_section "GET /v1/subscriptions"
printf '  HTTP status: %s\n' "$subscriptions_status"
if [[ "$subscriptions_status" != 2* ]]; then
  jq . "$subscriptions_response" >&2
  fail "/v1/subscriptions returned HTTP $subscriptions_status"
fi

subscription_count=$(jq 'length' "$subscriptions_response")
owner_subscription_count=$(
  jq '[.[] | select(((.roles // []) | length == 0) or ((.roles // []) | index("owner") != null))] | length' \
    "$subscriptions_response"
)
printf '  subscription count: %s\n' "$subscription_count"
printf '  owner-accessible subscription count: %s\n' "$owner_subscription_count"
if (( subscription_count == 0 )); then
  printf '  subscriptions: none\n'
else
  while IFS=$'\t' read -r subscription roles organization models; do
    printf '  %s\n' "$subscription"
    printf '    organization: %s\n' "$organization"
    printf '    roles: %s\n' "$roles"
    printf '    models: %s\n' "$models"
  done < <(jq -r '.[] | [.subscription_id_header, (.roles // [] | join(", ")), (.organization_id // ""), (.model_refs // [] | map(.name) | join(", "))] | @tsv' "$subscriptions_response")
fi

api_key_id=""
if (( owner_subscription_count > 0 )); then
  key_name="smoke-${user}-$(date +%s)"
  api_key_request=$(jq -n \
    --arg name "$key_name" \
    --arg user "$user" \
    '{
      name: $name,
      description: "Generated by the MaaS OIDC smoke test",
      expiresIn: "1h",
      ephemeral: true,
      labels: {
        smoke: "true",
        user: $user
      }
    }')

  api_key_response="$tmpdir/api-key-response.json"
  api_key_status=$(
    gateway_curl -sS --max-time 20 \
      -H "Authorization: Bearer $(cat "$token_file")" \
      -H 'Content-Type: application/json' \
      -d "$api_key_request" \
      -o "$api_key_response" -w '%{http_code}' \
      "$base_url/v1/api-keys"
  )

  print_section "POST /v1/api-keys"
  printf '  HTTP status: %s\n' "$api_key_status"
  if [[ "$api_key_status" != 2* ]] || ! jq -e 'has("key") and has("id") and has("keyPrefix") and has("expiresAt")' "$api_key_response" >/dev/null; then
    jq . "$api_key_response" >&2
    fail "API key creation failed"
  fi

  api_key_id=$(jq -r '.id' "$api_key_response")
  api_key_file="/tmp/maas-${user}-api-key"
  jq -r '.key' "$api_key_response" > "$api_key_file"
  api_key_subscription=$(jq -r '.subscription' "$api_key_response")
  [[ -n "$api_key_subscription" && "$api_key_subscription" != "null" ]] ||
    fail "API key creation did not return a subscription"
  printf '  id: %s\n' "$api_key_id"
  printf '  name: %s\n' "$key_name"
  printf '  prefix: %s\n' "$(jq -r '.keyPrefix' "$api_key_response")"
  printf '  subscription: %s\n' "$api_key_subscription"
  printf '  expires at: %s\n' "$(jq -r '.expiresAt' "$api_key_response")"
  printf '  key file: %s\n' "$api_key_file"
else
  print_section "POST /v1/api-keys"
  skip_stage api-key 'no owner-accessible subscription'
fi

api_key_list_request=$(jq -n '{
  filters: {
    includeEphemeral: true
  },
  pagination: {
    limit: 10,
    offset: 0
  }
}')

api_key_list_response="$tmpdir/api-key-list-response.json"
api_key_list_status=$(
  gateway_curl -sS --max-time 20 \
    -H "Authorization: Bearer $(cat "$token_file")" \
    -H 'Content-Type: application/json' \
    -d "$api_key_list_request" \
    -o "$api_key_list_response" -w '%{http_code}' \
    "$base_url/v1/api-keys/search"
)

print_section "POST /v1/api-keys/search"
printf '  HTTP status: %s\n' "$api_key_list_status"
if [[ "$api_key_list_status" != 2* ]] || ! jq -e 'type == "object" and ((.data == null) or (.data | type == "array"))' "$api_key_list_response" >/dev/null; then
  jq . "$api_key_list_response" >&2
  fail "API key listing failed"
fi

api_key_count=$(jq '.data // [] | length' "$api_key_list_response")
printf '  key count: %s\n' "$api_key_count"
printf '  has more: %s\n' "$(jq -r '.has_more' "$api_key_list_response")"
if (( api_key_count == 0 )); then
  printf '  keys: none\n'
else
  printf '  keys:\n'
  while IFS=$'\t' read -r name id status expires ephemeral; do
    printf '    - %s\n' "$name"
    printf '        id: %s\n' "$id"
    printf '        status: %s\n' "$status"
    printf '        expires: %s\n' "$expires"
    printf '        ephemeral: %s\n' "$ephemeral"
  done < <(jq -r '(.data // [])[] | [.name, (.id // ""), (.status // ""), (.expirationDate // ""), ((.ephemeral // false) | tostring)] | @tsv' "$api_key_list_response")
fi

if [[ -n "$api_key_id" ]]; then
  jq -e --arg id "$api_key_id" 'any(.data[]?; .id == $id)' "$api_key_list_response" >/dev/null ||
    fail "the newly created API key was not returned by listing"
  printf '  newly created key: found\n'
fi

if [[ -z "$api_key_id" ]]; then
  print_section "GET /v1/models (API key)"
  skip_stage models 'no owner-accessible API key was provisioned'
else
  api_key_models_response="$tmpdir/api-key-models-response.json"
  api_key_models_status=$(
    gateway_curl -sS --max-time 20 \
      -H "Authorization: Bearer $(cat "$api_key_file")" \
      -o "$api_key_models_response" -w '%{http_code}' \
      "$base_url/v1/models"
  )

  print_section "GET /v1/models (API key)"
  printf '  HTTP status: %s\n' "$api_key_models_status"
  if [[ "$api_key_models_status" != 2* ]] || ! jq -e 'type == "object" and (.data | type == "array")' "$api_key_models_response" >/dev/null; then
    jq . "$api_key_models_response" >&2
    fail "model listing failed"
  fi

  api_key_models_count=$(jq '.data | length' "$api_key_models_response")
  printf '  model count: %s\n' "$api_key_models_count"
  if (( api_key_models_count == 0 )); then
    printf '  models: none\n'
  else
    printf '  models:\n'
    while IFS=$'\t' read -r id owned_by; do
      printf '    - %s\n' "$id"
      printf '        owned by: %s\n' "$owned_by"
    done < <(jq -r '.data[] | [.id, (.owned_by // "")] | @tsv' "$api_key_models_response")
  fi
fi

inference_failed=0
inference_succeeded=0

if [[ -z "$api_key_id" ]]; then
  print_section "POST /v1/completions"
  skip_stage inference 'no owner-accessible API key was provisioned'
else
  inference_model_ref=$(
    jq -c --arg subscription "$api_key_subscription" \
      '[.[] | select(.subscription_id_header == $subscription)][0].model_refs[0] // empty' \
      "$subscriptions_response"
  )
  inference_model=$(jq -r '.name // empty' <<<"$inference_model_ref")
  if [[ -n "$expect_model" && -n "$inference_model" && "$inference_model" != "$expect_model" ]]; then
    fail "inference would use model $inference_model, not EXPECT_MODEL $expect_model"
  fi
  if [[ -z "$inference_model" ]]; then
    print_section "POST /v1/completions"
    skip_stage inference 'no model is available through the subscription'
  else
    confirm_action "Send one completion request to the MaaS Gateway using the newly created ephemeral API key.
Endpoint: /v1/completions
Model: $inference_model
Prompt: $inference_prompt" || fail "inference request was not approved"

    completions_request=$(jq -n \
      --arg model "$inference_model" \
      --arg prompt "$inference_prompt" \
      --argjson max_tokens "$inference_max_tokens" \
      '{
        model: $model,
        prompt: $prompt,
        max_tokens: $max_tokens
      }')

    completions_response="$tmpdir/completions-response.json"
    completions_status=$(
      gateway_curl -sS --max-time 60 \
        -H "Authorization: Bearer $(cat "$api_key_file")" \
        -H 'Content-Type: application/json' \
        -d "$completions_request" \
        -o "$completions_response" -w '%{http_code}' \
        "$base_url/v1/completions" || true
    )

    print_section "POST /v1/completions"
    printf '  HTTP status: %s\n' "$completions_status"
    if [[ "$completions_status" != 2* ]] || ! jq -e 'has("choices") and (.choices | length > 0)' "$completions_response" >/dev/null; then
      jq . "$completions_response" >&2 || true
      inference_failed=1
    else
      printf '  model: %s\n' "$(jq -r '.model' "$completions_response")"
      printf '  response: %s\n' "$(jq -r '.choices[0].text' "$completions_response")"
      printf '  finish reason: %s\n' "$(jq -r '.choices[0].finish_reason' "$completions_response")"
      printf '  prompt tokens: %s\n' "$(jq -r '.usage.prompt_tokens' "$completions_response")"
      printf '  completion tokens: %s\n' "$(jq -r '.usage.completion_tokens' "$completions_response")"
      inference_succeeded=1
    fi
  fi
fi

if [ "$inference_failed" -ne 0 ]; then
  fail "completion request failed"
fi

if [[ "$inference_succeeded" -ne 1 ]]; then
  print_section "Token rate limit"
  skip_stage rate-limit 'inference was not completed'
else
  rate_limit=$(
    jq -c '.token_rate_limits // [] | min_by(.limit) // empty' <<<"$inference_model_ref"
  )

  if [[ -z "$rate_limit" ]]; then
    print_section "Token rate limit"
    skip_stage rate-limit 'the selected model has no finite token rate limit'
  else
    rate_limit_limit=$(jq -r '.limit' <<<"$rate_limit")
    rate_limit_window=$(jq -r '.window // "unknown"' <<<"$rate_limit")
    [[ "$rate_limit_limit" =~ ^[1-9][0-9]*$ ]] || fail "the selected model has an invalid token rate limit"

    used_tokens=$(jq -r '.usage.total_tokens // empty' "$completions_response")
    [[ "$used_tokens" =~ ^[0-9]+$ ]] || fail "the selected model did not return usage.total_tokens"
    if (( used_tokens >= rate_limit_limit )); then
      remaining_tokens=0
    else
      remaining_tokens=$((rate_limit_limit - used_tokens))
    fi
    rate_limit_prompt_tokens=$((remaining_tokens + 8))

    if (( rate_limit_prompt_tokens > rate_limit_max_prompt_tokens )); then
      print_section "Token rate limit"
      skip_stage rate-limit "the ${rate_limit_prompt_tokens}-token exhaustion prompt exceeds RATE_LIMIT_MAX_PROMPT_TOKENS (${rate_limit_max_prompt_tokens})"
    else
      confirm_action "Send additional completion requests to exhaust and verify the subscription token rate limit.
Endpoint: /v1/completions
Model: $inference_model
Configured limit: $rate_limit_limit tokens per $rate_limit_window
The first request uses a dynamically sized prompt; up to $rate_limit_probe_attempts
subsequent probes expect HTTP 429." ||
        fail "rate-limit test was not approved"

      printf -v rate_limit_prompt '%*s' "$rate_limit_prompt_tokens" ''
      rate_limit_prompt="${rate_limit_prompt// /token }"
      rate_limit_exhaust_request=$(jq -n \
        --arg model "$inference_model" \
        --arg prompt "$rate_limit_prompt" \
        '{
          model: $model,
          prompt: $prompt,
          max_tokens: 1
        }')

      rate_limit_exhaust_response="$tmpdir/rate-limit-exhaust-response.json"
      rate_limit_exhaust_status=$(
        gateway_curl -sS --max-time 60 \
          -H "Authorization: Bearer $(cat "$api_key_file")" \
          -H 'Content-Type: application/json' \
          -d "$rate_limit_exhaust_request" \
          -o "$rate_limit_exhaust_response" -w '%{http_code}' \
          "$base_url/v1/completions" || true
      )

      print_section "Token rate limit"
      printf '  configured limit: %s tokens per %s\n' "$rate_limit_limit" "$rate_limit_window"
      printf '  tokens used by inference: %s\n' "$used_tokens"
      printf '  generated prompt target: %s tokens\n' "$rate_limit_prompt_tokens"
      printf '  exhaustion HTTP status: %s\n' "$rate_limit_exhaust_status"

      if [[ "$rate_limit_exhaust_status" == "429" ]]; then
        printf '  result: enforced\n'
      else
        if [[ "$rate_limit_exhaust_status" != 2* ]] ||
          ! jq -e 'has("choices") and (.choices | length > 0)' "$rate_limit_exhaust_response" >/dev/null; then
          jq . "$rate_limit_exhaust_response" >&2 || true
          fail "rate-limit exhaustion request failed"
        fi

        printf '  exhaustion total tokens: %s\n' \
          "$(jq -r '.usage.total_tokens // "unavailable"' "$rate_limit_exhaust_response")"
        rate_limit_enforced=0
        for (( probe_attempt = 1; probe_attempt <= rate_limit_probe_attempts; probe_attempt++ )); do
          sleep "$rate_limit_delay_seconds"

          rate_limit_probe_request=$(jq -n \
            --arg model "$inference_model" \
            --arg prompt "Reply with: rate-limit probe." \
            '{
              model: $model,
              prompt: $prompt,
              max_tokens: 1
            }')

          rate_limit_probe_response="$tmpdir/rate-limit-probe-response.json"
          rate_limit_probe_status=$(
            gateway_curl -sS --max-time 60 \
              -H "Authorization: Bearer $(cat "$api_key_file")" \
              -H 'Content-Type: application/json' \
              -d "$rate_limit_probe_request" \
              -o "$rate_limit_probe_response" -w '%{http_code}' \
              "$base_url/v1/completions" || true
          )

          printf '  probe %s HTTP status: %s\n' "$probe_attempt" "$rate_limit_probe_status"
          if [[ "$rate_limit_probe_status" == "429" ]]; then
            rate_limit_enforced=1
            break
          fi
          if [[ "$rate_limit_probe_status" != 2* ]] ||
            ! jq -e 'has("choices") and (.choices | length > 0)' "$rate_limit_probe_response" >/dev/null; then
            jq . "$rate_limit_probe_response" >&2 || true
            fail "rate-limit probe request failed"
          fi
          printf '  probe %s total tokens: %s\n' \
            "$probe_attempt" "$(jq -r '.usage.total_tokens // "unavailable"' "$rate_limit_probe_response")"
        done

        if [[ "$rate_limit_enforced" -ne 1 ]]; then
          fail "token rate limit was not enforced after $rate_limit_probe_attempts probes"
        fi
        printf '  result: enforced\n'
      fi
    fi
  fi
fi

print_section "Smoke result"
if [[ "$require_inference" == 1 && "$inference_succeeded" -ne 1 ]]; then
  fail "inference is required for $user but did not run"
fi
if (( ${#skipped_stages[@]} > 0 )); then
  printf '  skipped: %s\n' "${skipped_stages[@]}"
  printf '  result: passed with skips\n'
else
  printf '  result: passed\n'
fi
