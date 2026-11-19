#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
namespace="${KEYCLOAK_NAMESPACE:-maas-db}"
port="${PORT:-8000}"
forward_port="${FORWARD_PORT:-18080}"

keycloak_url="$(
  kubectl get route keycloak -n "$namespace" \
    -o jsonpath='{.status.ingress[0].host}'
)"
[[ -n "$keycloak_url" ]] || {
  echo "Route $namespace/keycloak has no public host" >&2
  exit 1
}

client_secret="$(
  kubectl get secret keycloak-secrets -n "$namespace" \
    -o jsonpath='{.data.KEYCLOAK_CLIENT_SECRET}' | base64 --decode
)"
[[ -n "$client_secret" ]] || {
  echo "Secret $namespace/keycloak-secrets has no KEYCLOAK_CLIENT_SECRET" >&2
  exit 1
}

export KEYCLOAK_PUBLIC_URL="https://$keycloak_url"
export KEYCLOAK_URL="http://127.0.0.1:$forward_port"
export KEYCLOAK_REALM=saas
export KEYCLOAK_CLIENT_ID=tenant-demo
export KEYCLOAK_CLIENT_SECRET="$client_secret"
export KEYCLOAK_REDIRECT_URI="http://localhost:$port/callback"
export PORT="$port"

kubectl port-forward -n "$namespace" service/keycloak "$forward_port:8080" \
  >/tmp/keycloak-token-inspector-forward.log 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true' EXIT
sleep 1

node "$script_dir/server.js"
