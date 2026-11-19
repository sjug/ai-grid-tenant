#!/usr/bin/env bash
# Ensure every managed custom resource has an explicit Argo CD health decision.
# Usage: scripts/check-gitops-health-checks.sh
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

health_manifest="apps/gitops-config/manifests/argocd.yaml"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

managed="$workdir/managed.tsv"
external="$workdir/external.tsv"
all_managed="$workdir/all-managed.tsv"
configured_raw="$workdir/configured-raw.tsv"
configured="$workdir/configured.tsv"
allowlisted="$workdir/allowlisted.tsv"

# Adjacent apiVersion/kind pairs are traversed at any indentation so resources
# embedded in ACM objectDefinition trees are included. Build-time Kustomize
# documents and Kubernetes core objects do not need a custom Lua health check.
find . -path './.git' -prune -o -type f -name '*.yaml' -print0 |
  while IFS= read -r -d '' file; do
    awk '
      function indent(line) {
        match(line, /[^ ]/)
        return RSTART - 1
      }
      /^[[:space:]]*$/ {next}
      /^[[:space:]]*#/ {next}
      /^[[:space:]]*apiVersion:/ {api = $2; api_indent = indent($0); next}
      /^[[:space:]]*kind:/ {
        if (api != "" && indent($0) == api_indent) {
          split(api, parts, "/")
          group = parts[1]
          if (group != "v1" && group != "apps" && group != "batch" &&
              group != "networking.k8s.io" && group != "rbac.authorization.k8s.io" &&
              group != "kustomize.config.k8s.io") {
            print group "\t" $2
          }
        }
        api = ""
        next
      }
      {api = ""}
    ' "$file"
  done | sort -u > "$managed"

# Resources rendered by remote charts or referenced only by Argo
# ignoreDifferences are not present as adjacent apiVersion/kind pairs in this
# repository. Keep this list aligned with the live Application resource set.
cat > "$external" <<'EOF'
admissionregistration.k8s.io	ValidatingAdmissionPolicy
admissionregistration.k8s.io	ValidatingAdmissionPolicyBinding
dscinitialization.opendatahub.io	DSCInitialization
gateway.networking.k8s.io	GatewayClass
grid.praxis.fast	GridNetwork
grid.praxis.fast	InferenceProvider
kuadrant.io	Kuadrant
operator.openshift.io	LeaderWorkerSetOperator
EOF

cat "$managed" "$external" | sort -u > "$all_managed"

awk '
  function flush() {
    if (group != "") {
      if (kind == "" || !has_check) {
        print "error: incomplete health check for " group "/" kind > "/dev/stderr"
        failed = 1
      } else {
        print group "\t" kind
      }
      group = ""
      kind = ""
      has_check = 0
    }
  }
  /^  resourceHealthChecks:/ {inside = 1; next}
  inside && /^  [A-Za-z]/ {inside = 0; flush()}
  inside && /^    - group:/ {flush(); group = $3}
  inside && /^      kind:/ {kind = $2}
  inside && /^      check: \|/ {has_check = 1}
  END {
    if (inside) {flush()}
    if (failed) {exit 1}
  }
' "$health_manifest" > "$configured_raw"
sort -u "$configured_raw" > "$configured"

# Policy uses Argo CD's built-in compliance health check (verified against live
# Application resource health). GridSite is intentionally omitted because site
# discovery and enrollment can remain Pending independently of GitOps. The other
# entries are declarative resources whose current CRDs expose no operand status.
cat > "$allowlisted" <<'EOF'
admissionregistration.k8s.io	ValidatingAdmissionPolicy
admissionregistration.k8s.io	ValidatingAdmissionPolicyBinding
argoproj.io	AppProject
config.openshift.io	ImageDigestMirrorSet
grid.praxis.fast	GridSite
metallb.io	IPAddressPool
metallb.io	L2Advertisement
metallb.io	MetalLB
monitoring.coreos.com	PodMonitor
monitoring.coreos.com	ServiceMonitor
monitoring.rhobs	ScrapeConfig
policy.open-cluster-management.io	PlacementBinding
policy.open-cluster-management.io	Policy
submariner.io	Broker
user.openshift.io	Group
EOF

bad=0

while IFS=$'\t' read -r group kind; do
  if ! grep -qFx "$group	$kind" "$configured" &&
     ! grep -qFx "$group	$kind" "$allowlisted"; then
    echo "error: managed custom resource has no GitOps health decision: $group/$kind" >&2
    bad=1
  fi
done < "$all_managed"

while IFS=$'\t' read -r group kind; do
  if ! grep -qFx "$group	$kind" "$all_managed"; then
    echo "error: configured health check has no repository or external managed-resource entry: $group/$kind" >&2
    bad=1
  fi
  if grep -qFx "$group	$kind" "$allowlisted"; then
    echo "error: configured health check is also allowlisted: $group/$kind" >&2
    bad=1
  fi
done < "$configured"

while IFS=$'\t' read -r group kind; do
  if grep -qFx "$group	$kind" "$configured"; then
    echo "error: allowlisted resource is explicitly configured; remove its allowlist entry: $group/$kind" >&2
    bad=1
  fi
  if ! grep -qFx "$group	$kind" "$all_managed"; then
    echo "error: obsolete health-check allowlist entry: $group/$kind" >&2
    bad=1
  fi
done < "$allowlisted"

if awk '/^  resourceHealthChecks:/ {inside = 1; next} inside && /^  [A-Za-z]/ {inside = 0} inside && /^      check: \|/ {checks++} END {exit !(checks > 0)}' "$health_manifest"; then
  :
else
  echo "error: $health_manifest has no resource health checks" >&2
  bad=1
fi

if [[ -s "$configured_raw" ]] && [[ -n "$(sort "$configured_raw" | uniq -d)" ]]; then
  echo "error: duplicate GitOps health checks:" >&2
  sort "$configured" | uniq -d >&2
  bad=1
fi

if ((bad)); then
  exit 1
fi

echo "ok: $(wc -l < "$configured" | tr -d ' ') health checks cover managed custom resources or documented exceptions"
