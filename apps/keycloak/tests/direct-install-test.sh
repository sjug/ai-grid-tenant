#!/usr/bin/env bash
set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

kubectl kustomize --load-restrictor=LoadRestrictionsNone \
  "$here/../overlays/direct" > "$tmpdir/initial.yaml"
kubectl kustomize --load-restrictor=LoadRestrictionsNone \
  "$here/../overlays/direct/jobs" > "$tmpdir/jobs.yaml"

if grep -Eq 'kind: (Placement|PlacementBinding|Policy)$' "$tmpdir/initial.yaml"; then
  echo "the direct initial render contains ACM resources" >&2
  exit 1
fi

if grep -q 'kind: Job$' "$tmpdir/initial.yaml"; then
  echo "the direct initial render contains a Job" >&2
  exit 1
fi

if grep -q 'managedclusters' "$tmpdir/initial.yaml"; then
  echo "the direct initial render queries ACM managed clusters" >&2
  exit 1
fi

if grep -Eq 'cluster\.open-cluster-management\.io|policy\.open-cluster-management\.io' "$tmpdir/jobs.yaml"; then
  echo "the direct jobs render contains ACM resources" >&2
  exit 1
fi

job_count="$(
  awk 'BEGIN { RS = "---" } $0 ~ /kind: Job/ { count += 1 } END { print count + 0 }' \
    "$tmpdir/jobs.yaml"
)"
[[ "$job_count" == 2 ]] || {
  echo "the direct jobs render contains $job_count Jobs, expected 2" >&2
  exit 1
}

for name in keycloak-realm-sync-bootstrap keycloak-saas-realm-sync; do
  grep -q "name: $name" "$tmpdir/jobs.yaml" || {
    echo "the direct jobs render lacks Job $name" >&2
    exit 1
  }
done

for name in keycloak-realm-import keycloak-realm-scripts; do
  if grep -q "name: $name$" "$tmpdir/jobs.yaml"; then
    echo "the direct jobs render references ungenerated ConfigMap $name" >&2
    exit 1
  fi
done

grep -q 'GRID_TENANT_1_BROKER_CLIENT_SECRET' "$tmpdir/jobs.yaml"
grep -q 'GRID_TENANT_2_BROKER_CLIENT_SECRET' "$tmpdir/jobs.yaml"

# The separately rendered Jobs must mount the exact ConfigMaps installed by
# the initial apply and run the same containers as the default Argo hooks.
kubectl kustomize "$here/../overlays/default" > "$tmpdir/default.yaml"
python3 - "$tmpdir" <<'PY'
import os
import sys
import yaml

def resources(name):
    with open(os.path.join(sys.argv[1], name + ".yaml")) as stream:
        return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(stream) if d}

initial = resources("initial")
argo = resources("default")
for key, job in resources("jobs").items():
    if key[0] != "Job":
        continue
    pod = job["spec"]["template"]["spec"]
    assert pod == argo[key]["spec"]["template"]["spec"], key
    for volume in pod["volumes"]:
        if "configMap" in volume:
            assert ("ConfigMap", volume["configMap"]["name"]) in initial
    for container in pod["containers"]:
        for variable in container["env"]:
            secret = variable.get("valueFrom", {}).get("secretKeyRef")
            if secret and secret["name"].endswith("-realm-sync"):
                assert ("ExternalSecret", secret["name"]) in initial
PY

echo "keycloak direct install tests: 1 ok, 0 failed"
