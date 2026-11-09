#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  apps/keycloak/install.sh [--render]

Options:
  --render          Print the rendered manifests and do not apply them.

The script uses the direct default profile. It installs in the maas-db
namespace, applies the manifests with kubectl, reads the Route host assigned
by OpenShift, and creates the public-URL ConfigMap. It does not install or
use Argo CD or ACM.
It still requires the CloudNativePG, External Secrets, and cert-manager CRDs
and controllers.
EOF
}

namespace="maas-db"
render=false

while (($# > 0)); do
  case "$1" in
    --render)
      render=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$namespace" ]] || { echo "Namespace must not be empty" >&2; exit 2; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_dir="$script_dir/overlays/direct"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

resource="$(realpath --relative-to="$tmpdir" "$profile_dir")"

cat > "$tmpdir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $resource
namespace: $namespace
EOF

if [[ "$render" == true ]]; then
  kubectl kustomize --load-restrictor=LoadRestrictionsNone "$tmpdir"
  exit 0
fi

kubectl create namespace "$namespace" --dry-run=client -o yaml |
  kubectl apply -f -

kubectl apply -f "$script_dir/base/manifests/route.yaml"

kubectl wait --for=jsonpath='{.status.ingress[0].host}' route/keycloak \
  -n "$namespace" --timeout=120s

route_host="$(
  kubectl get route keycloak -n "$namespace" \
    -o jsonpath='{.status.ingress[0].host}'
)"
[[ -n "$route_host" ]] || { echo "Route keycloak has no public host" >&2; exit 1; }

kubectl create configmap keycloak-public-url \
  --from-literal="KEYCLOAK_PUBLIC_URL=https://$route_host" \
  -n "$namespace" --dry-run=client -o yaml |
  kubectl apply -f -

kubectl kustomize --load-restrictor=LoadRestrictionsNone "$tmpdir" |
  kubectl apply -f -

kubectl rollout status deployment/keycloak -n "$namespace" --timeout=300s
