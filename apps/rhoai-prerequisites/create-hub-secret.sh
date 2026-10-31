#!/usr/bin/env bash

set -Eeuo pipefail

namespace="${NAMESPACE:-rhoai-prerequisites}"
context="${HUB_CONTEXT:-}"

usage() {
  cat <<'EOF'
Create or update the hub-side RHOAI pre-release pull Secret used by the
rhoai-prerequisites ACM policy.

Required environment:
  RHOAI_QUAY_PULL_SECRET  Base64-encoded "username:password" for quay.io/rhoai.

Optional environment:
  RHOAI_STAGE_PULL_SECRET Base64-encoded "username:password" for registry.stage.redhat.io,
                          which the registry.redhat.io/rhaii* mirrors pull from.
  HUB_CONTEXT             Hub kubeconfig context.
  NAMESPACE               Hub namespace; defaults to rhoai-prerequisites.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ -n "${RHOAI_QUAY_PULL_SECRET:-}" ] || {
  usage >&2
  die "RHOAI_QUAY_PULL_SECRET must be set"
}

for required_command in kubectl jq base64; do
  command -v "$required_command" >/dev/null 2>&1 || die "required command not found: $required_command"
done

decoded_credentials="$(printf '%s' "$RHOAI_QUAY_PULL_SECRET" | base64 -d 2>/dev/null || true)"
[ -n "$decoded_credentials" ] || die "RHOAI_QUAY_PULL_SECRET is not valid base64"
[[ "$decoded_credentials" == *:* ]] || die "decoded RHOAI_QUAY_PULL_SECRET must be username:password"
if [ -n "${RHOAI_STAGE_PULL_SECRET:-}" ]; then
  decoded_stage="$(printf '%s' "$RHOAI_STAGE_PULL_SECRET" | base64 -d 2>/dev/null || true)"
  [[ "$decoded_stage" == *:* ]] || die "RHOAI_STAGE_PULL_SECRET must be base64 of username:password"
fi

kubectl_args=()
if [ -n "$context" ]; then
  kubectl_args+=(--context "$context")
fi

# Declarative, so it cannot collide with Argo CD creating the same namespace
# between a check and a create on a fresh hub.
kubectl "${kubectl_args[@]}" create namespace "$namespace" --dry-run=client -o yaml |
  kubectl "${kubectl_args[@]}" apply -f -

docker_config_json="$(jq -n '{auths: ({"quay.io": {auth: env.RHOAI_QUAY_PULL_SECRET}}
  + if (env.RHOAI_STAGE_PULL_SECRET // "") != "" then {"registry.stage.redhat.io": {auth: env.RHOAI_STAGE_PULL_SECRET}} else {} end)}')"
docker_config_json_b64="$(printf '%s' "$docker_config_json" | base64 -w0)"

kubectl "${kubectl_args[@]}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: rhoai-quay-pull-secret
  namespace: $namespace
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $docker_config_json_b64
EOF

printf 'Created or updated %s/%s.\n' "$namespace" rhoai-quay-pull-secret
