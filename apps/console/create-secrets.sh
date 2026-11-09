#!/usr/bin/env bash
# Create or update what the provider console needs that isn't in git: its
# OpenShift OAuthClient and proxy Secret, the backend's Keycloak user and
# Secret, and the backend's token for the catalog repository. Run it after
# Argo CD has created the console's Route. Safe to rerun: it keeps existing
# secret values. It prints no secret value.

set -Eeuo pipefail
# Run a pipeline's last command in this shell, so apply's changed=yes survives.
shopt -s lastpipe

namespace="${NAMESPACE:-ai-grid-provider-console}"
context="${HUB_CONTEXT:-}"
realm="${KEYCLOAK_REALM:-saas}"
keycloak_namespace="${KEYCLOAK_NAMESPACE:-maas-db}"
backend_user="${KEYCLOAK_BACKEND_USER:-ai-grid-console-backend}"
adopt_user_id="${ADOPT_KEYCLOAK_USER_ID:-}"
name=ai-grid-provider-console

usage() {
  cat <<'EOF'
Create or update the provider console's Secrets and OAuthClient on the hub.

Required environment:
  AI_GRID_GIT_TOKEN_FILE  Path to a file holding a fine-grained GitHub token
                          with contents: write on the catalog repository
                          (sjug/ai-grid-catalog) and nothing else.

Optional environment:
  HUB_CONTEXT             Hub kubeconfig context.
  NAMESPACE               The console's namespace; defaults to ai-grid-provider-console.
  KEYCLOAK_REALM          The realm whose organizations the console manages;
                          defaults to saas.
  KEYCLOAK_NAMESPACE      Keycloak's namespace; defaults to maas-db.
  KEYCLOAK_BACKEND_USER   The backend's Keycloak user; defaults to
                          ai-grid-console-backend.
  ADOPT_KEYCLOAK_USER_ID  The id of an existing backend user to adopt, when no
                          Secret records one yet (a user an older version of
                          this script created). The error that asks for it
                          prints the id.
  KEYCLOAK_BACKEND_URL    The Keycloak URL stored for the backend; defaults to
                          the public Route. See apps/console/README.md for a
                          private ingress CA (also CURL_CA_BUNDLE for this script).
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ -n "${AI_GRID_GIT_TOKEN_FILE:-}" ] || {
  usage >&2
  die "AI_GRID_GIT_TOKEN_FILE must be set"
}
[ -s "$AI_GRID_GIT_TOKEN_FILE" ] || die "AI_GRID_GIT_TOKEN_FILE is not a non-empty file"

for required_command in kubectl jq curl openssl base64; do
  command -v "$required_command" >/dev/null 2>&1 || die "required command not found: $required_command"
done

kubectl_args=()
if [ -n "$context" ]; then
  kubectl_args+=(--context "$context")
fi
k() { kubectl "${kubectl_args[@]}" "$@"; }
# Apply from stdin, and remember whether anything changed, so the console
# restarts only when it has new Secrets to read.
changed=no
apply() {
  local out
  out=$(k apply -f -)
  case $out in *" unchanged") ;; *) changed=yes ;; esac
}

# A Secret key's value, decoded, or nothing.
secret_value() {
  k get secret "$2" -n "$1" -o "go-template={{ with index .data \"$3\" }}{{ . }}{{ end }}" 2>/dev/null |
    base64 -d 2>/dev/null || true
}

host=""
for _ in $(seq 1 60); do
  host="$(k get route "$name" -n "$namespace" -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || true)"
  [ -n "$host" ] && break
  sleep 10
done
[ -n "$host" ] || die "route $namespace/$name not found: has Argo CD synced Application console?"

keycloak_host="$(k get route keycloak -n "$keycloak_namespace" -o jsonpath='{.status.ingress[0].host}')"
[ -n "$keycloak_host" ] || die "route $keycloak_namespace/keycloak has no host"
backend_keycloak_url="${KEYCLOAK_BACKEND_URL:-https://$keycloak_host}"

# Keycloak: a backend user that may manage organizations and their identity
# providers in one realm (Tenants/Create links a tenant's own IdP), not the
# master realm's admin.
admin_user="$(secret_value "$keycloak_namespace" keycloak-secrets KC_BOOTSTRAP_ADMIN_USERNAME)"
[ -n "$admin_user" ] || die "secret $keycloak_namespace/keycloak-secrets has no KC_BOOTSTRAP_ADMIN_USERNAME"
token="$(secret_value "$keycloak_namespace" keycloak-secrets KC_BOOTSTRAP_ADMIN_PASSWORD |
  curl -fsS -d grant_type=password -d client_id=admin-cli --data-urlencode "username=$admin_user" \
    --data-urlencode password@- "https://$keycloak_host/realms/master/protocol/openid-connect/token" |
  jq -r .access_token)" || true
[ -n "$token" ] && [ "$token" != null ] ||
  die "Keycloak admin sign-in failed (if the admin password was changed after the first start, keycloak-secrets no longer holds it)"
api() { curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$token") -H 'Content-Type: application/json' "$@"; }
base="https://$keycloak_host/admin/realms/$realm"

# The realm brokers tenants' own IdPs, so a tenant could sign in first under
# this username. Trust only a user whose id the backend's Secret records (only a
# hub admin can write it), or that the admin names with ADOPT_KEYCLOAK_USER_ID,
# and that has no brokered identity; otherwise stop. Keycloak's own record of
# the user can't be the mark: an attribute the realm's user profile doesn't
# declare is dropped, and any realm admin can grant a group.
# The user has an email because a realm can require one before it issues
# tokens. A tenant's IdP can claim any email, and a first-login flow may link a
# brokered login to an existing account by email, so the address is random
# (kept across reruns) and nobody outside the hub can know it.
recorded_id="$(secret_value "$namespace" ai-grid-backend-keycloak user-id)"
user_json="$(api "$base/users?username=$backend_user&exact=true&briefRepresentation=false" | jq -c '.[0] // empty')"
if [ -z "$user_json" ]; then
  backend_email="${backend_user}+$(openssl rand -hex 16)@console.invalid"
  jq -n --arg u "$backend_user" --arg e "$backend_email" \
    '{username: $u, enabled: true, email: $e, emailVerified: true, firstName: "AI Grid", lastName: "console backend",
      requiredActions: []}' |
    api -X POST "$base/users" -d @- >/dev/null
  user_json="$(api "$base/users?username=$backend_user&exact=true&briefRepresentation=false" | jq -ce '.[0]')"
  recorded_id="$(jq -r .id <<<"$user_json")"
fi
user_id="$(jq -r .id <<<"$user_json")"
case "$user_id" in
  "$recorded_id" | "$adopt_user_id") ;;
  *) die "Keycloak user $backend_user in realm $realm (id $user_id) isn't the one $namespace/ai-grid-backend-keycloak records; if you know this script made it, rerun with ADOPT_KEYCLOAK_USER_ID=$user_id" ;;
esac
[ "$(api "$base/users/$user_id/federated-identity" | jq length)" = 0 ] ||
  die "Keycloak user $backend_user in realm $realm has a brokered identity; refusing to give it admin roles"
# A realm may require profile fields or actions; a user with pending required
# actions can't get a token ("Account is not fully set up"). Keep its random
# email, or give it one.
backend_email="$(jq -r '.email // empty' <<<"$user_json")"
case "$backend_email" in
  "$backend_user+"????????????????????????????????"@console.invalid") ;;
  *) backend_email="${backend_user}+$(openssl rand -hex 16)@console.invalid" ;;
esac
jq --arg e "$backend_email" \
  '. + {email: $e, emailVerified: true, firstName: "AI Grid", lastName: "console backend", requiredActions: []}' <<<"$user_json" |
  api -X PUT "$base/users/$user_id" -d @- >/dev/null
backend_password="$(secret_value "$namespace" ai-grid-backend-keycloak password)"
backend_password="${backend_password:-$(openssl rand -base64 24)}"
PW="$backend_password" jq -n '{type: "password", value: env.PW, temporary: false}' |
  api -X PUT "$base/users/$user_id/reset-password" -d @- >/dev/null
realm_management="$(api "$base/clients?clientId=realm-management" | jq -re '.[0].id')"
api "$base/clients/$realm_management/roles" |
  jq '[.[] | select(.name | IN("view-users", "query-users", "view-realm", "manage-realm", "view-identity-providers", "manage-identity-providers"))]' |
  api -X POST "$base/users/$user_id/role-mappings/clients/$realm_management" -d @- >/dev/null
PW="$backend_password" BACKEND_USER_ID="$user_id" jq -n --arg ns "$namespace" --arg url "$backend_keycloak_url" --arg realm "$realm" --arg user "$backend_user" \
  '{apiVersion: "v1", kind: "Secret", metadata: {name: "ai-grid-backend-keycloak", namespace: $ns}, type: "Opaque",
    stringData: {url: $url, realm: $realm, "admin-realm": $realm, username: $user, password: env.PW, "user-id": env.BACKEND_USER_ID}}' |
  apply
unset backend_password token
printf 'Created or updated %s/ai-grid-backend-keycloak (Keycloak user %s in realm %s).\n' "$namespace" "$backend_user" "$realm"

# OpenShift sign-in for provider admins: an OAuthClient and the proxy's Secret.
redirect="https://$host/oauth2/callback"
client_secret="$(secret_value "$namespace" "$name-oauth" OAUTH2_PROXY_CLIENT_SECRET)"
cookie_secret="$(secret_value "$namespace" "$name-oauth" OAUTH2_PROXY_COOKIE_SECRET)"
# kube-auth-proxy takes the cookie secret as raw bytes (16, 24 or 32).
[ "${#cookie_secret}" = 32 ] || cookie_secret=""
export CS="${client_secret:-$(openssl rand -hex 32)}" CK="${cookie_secret:-$(openssl rand -hex 16)}"
jq -n --arg n "$name" --arg r "$redirect" '{apiVersion: "oauth.openshift.io/v1", kind: "OAuthClient",
  metadata: {name: $n}, grantMethod: "auto", redirectURIs: [$r], secret: env.CS}' | apply
jq -n --arg n "$name" --arg r "$redirect" --arg ns "$namespace" '{apiVersion: "v1", kind: "Secret",
  metadata: {name: "\($n)-oauth", namespace: $ns}, type: "Opaque",
  stringData: {OAUTH2_PROXY_CLIENT_ID: $n, OAUTH2_PROXY_CLIENT_SECRET: env.CS,
    OAUTH2_PROXY_COOKIE_SECRET: env.CK, OAUTH2_PROXY_REDIRECT_URL: $r}}' | apply
unset CS CK client_secret cookie_secret
printf 'Created or updated OAuthClient %s and %s/%s-oauth.\n' "$name" "$namespace" "$name"

# The backend's token for the catalog repository, mounted as a file.
k create secret generic ai-grid-backend-git -n "$namespace" --from-file=token="$AI_GRID_GIT_TOKEN_FILE" \
  --dry-run=client -o yaml | apply
printf 'Created or updated %s/ai-grid-backend-git.\n' "$namespace"

if [ "$changed" = yes ]; then
  k rollout restart deployment "$name" -n "$namespace" >/dev/null
  printf 'Restarted the console to read the changed Secrets.\n'
else
  printf 'Nothing changed; the console keeps running.\n'
fi
printf 'Console: https://%s (sign in with an OpenShift login that may patch managedclusters).\n' "$host"
