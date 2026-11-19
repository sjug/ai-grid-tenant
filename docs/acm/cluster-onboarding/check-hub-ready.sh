#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Check hub registration readiness without changing either cluster or requesting tokens.

Usage: check-hub-ready.sh [--hub-context <context>]
                          [--registration-sa-namespace <namespace> | --use-bootstrap-token]

Defaults to HUB_CONTEXT or the current context. Exit 0 means registration prerequisites are ready;
exit 1 means not ready or inaccessible. This does not check full Grid readiness.
EOF
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

hub_context="${HUB_CONTEXT:-}"
registration_sa_namespace="${REGISTRATION_SA_NAMESPACE:-}"
use_bootstrap_token=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hub-context|--registration-sa-namespace)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      if [ "$1" = --hub-context ]; then hub_context=$2; else registration_sa_namespace=$2; fi
      shift 2
      ;;
    --use-bootstrap-token) use_bootstrap_token=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

if [ "$use_bootstrap_token" = true ] && [ -n "$registration_sa_namespace" ]; then
  usage_error "--use-bootstrap-token and --registration-sa-namespace are mutually exclusive"
fi

for command_name in kubectl jq; do
  command -v "$command_name" >/dev/null || { printf 'Missing command: %s\n' "$command_name" >&2; exit 1; }
done
[ -n "$hub_context" ] || hub_context=$(kubectl config current-context) || die "cannot determine current context"

context_exists() {
  kubectl config get-contexts -o name | grep -Fxq -- "$1"
}

context_exists "$hub_context" || die "hub context not found: $hub_context"

not_ready() {
  printf 'NOT READY: %s\n' "$*" >&2
  printf 'Check hub bootstrap/Argo source errors and ACM registration status before retrying.\n' >&2
  exit 1
}

printf 'Checking hub registration on context %s...\n' "$hub_context"
if ! managers=$(kubectl --context "$hub_context" --request-timeout=15s \
  get clustermanagers.operator.open-cluster-management.io -o json); then
  not_ready 'Cannot read ClusterManager. ACM/OCM may not be installed, or access may have expired.'
fi

# Applied alone only establishes that manifests exist. Require the controller's
# functional registration condition for the current ClusterManager generation.
if ! jq -e 'any(.items[];
    .metadata.generation as $generation |
    any(.status.conditions[]?; .type == "Applied" and .status == "True") and
    any(.status.conditions[]?; .type == "HubRegistrationDegraded" and
      .status == "False" and (.observedGeneration // 0) >= $generation))' \
  <<<"$managers" >/dev/null; then
  jq -r '.items[] | .metadata.name as $name | .status.conditions[]? |
    select(.type == "Applied" or .type == "HubRegistrationDegraded") |
    "\($name): \(.type)=\(.status) \(.message // "")"' <<<"$managers" >&2
  not_ready 'Hub registration is not functional at the current generation yet.'
fi

if ! kubectl --context "$hub_context" --request-timeout=15s \
  get managedclusters.cluster.open-cluster-management.io -o name >/dev/null; then
  not_ready 'ManagedCluster API is unavailable or this user cannot list clusters.'
fi

if [ "$use_bootstrap_token" = false ]; then
  candidate_namespaces=(open-cluster-management multicluster-engine)
  if [ -n "$registration_sa_namespace" ]; then candidate_namespaces=("$registration_sa_namespace"); fi
  found=false
  for namespace in "${candidate_namespaces[@]}"; do
    if kubectl --context "$hub_context" --request-timeout=15s get serviceaccount \
      agent-registration-bootstrap -n "$namespace" -o name >/dev/null 2>&1; then
      printf 'Registration ServiceAccount: %s/agent-registration-bootstrap\n' "$namespace"
      found=true
      break
    fi
  done
  [ "$found" = true ] || not_ready 'Registration bootstrap ServiceAccount is missing or inaccessible.'
fi

printf 'READY: hub registration prerequisites are available.\n'
