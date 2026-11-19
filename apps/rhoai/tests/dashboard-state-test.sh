#!/usr/bin/env bash
# Render dashboard states per role. RHAI_CHART_DIR skips the clone. Needs helm, git and PyYAML.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
total=0
ok() { total=$((total+1)); printf '   ok   %s\n' "$1"; }
bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %s\n' "$1"; }

python3 - "$HERE/../hub/01-applicationset.yaml" > "$T/source" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as stream:
    appset = yaml.safe_load(stream)
sources = [source for source in appset["spec"]["template"]["spec"]["sources"]
           if source.get("repoURL") == "oci://ghcr.io/opendatahub-io/odh-gitops/rhai-on-openshift-chart"]
assert len(sources) == 1, "expected exactly one RHOAI chart source"
source = sources[0]
assert source.get("path") == ".", "expected the RHOAI OCI chart root path"
print(source["repoURL"], source["targetRevision"])
PY
read -r repo rev < "$T/source"
if [ -n "${RHAI_CHART_DIR:-}" ]; then
  CHART=$RHAI_CHART_DIR
else
  helm pull "${repo}" --version "$rev" --destination "$T/odh-gitops" --untar
  CHART=$T/odh-gitops/rhai-on-openshift-chart
fi
[ -f "$CHART/Chart.yaml" ] || { echo "chart not found at $CHART" >&2; exit 1; }
printf 'RHOAI chart version: %s\n' "$rev"

mkdir -p "$T/undeclared/roles"
for file in "$HERE/../values.yaml" "$HERE"/../roles/*.yaml; do
  name=${file##*/}
  output=$T/undeclared/$name
  if [ "$name" != values.yaml ]; then output=$T/undeclared/roles/$name; fi
  if python3 - "$file" "$output" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as stream:
    values = yaml.safe_load(stream)
dashboard = values.get("components", {}).get("dashboard", {}).get("dsc", {})
assert "managementState" not in dashboard, "legacy dashboard.dsc.managementState is present"
dashboard.pop("standard", None)
with open(sys.argv[2], "w") as stream:
    yaml.safe_dump(values, stream)
PY
  then ok "$name: legacy dashboard state absent"
  else bad "$name: legacy dashboard state check failed"
  fi
done

render() {
  helm template rhai-on-openshift "$CHART" -f "$1" -f "$2" \
    --set skipCrdCheck=true \
    --set praxis-gateway.grid.siteName=site \
    --set praxis-provider-gateway.grid.siteName=site > "$3"
}
states() {
  python3 - "$1" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as stream:
    clusters = [doc for doc in yaml.safe_load_all(stream)
                if doc and doc.get("kind") == "DataScienceCluster"]
assert len(clusters) == 1, f"expected one DataScienceCluster, got {len(clusters)}"
dashboard = clusters[0]["spec"]["components"]["dashboard"]
print(dashboard["standard"]["managementState"], dashboard["maasPortal"]["managementState"])
PY
}

for role in ingress combined inference; do
  want='Managed Managed'
  if [ "$role" = inference ]; then want='Removed Removed'; fi
  if render "$HERE/../values.yaml" "$HERE/../roles/$role.yaml" "$T/$role.yaml" &&
     got=$(states "$T/$role.yaml"); then
    if [ "$got" = "$want" ]; then
      ok "$role: standard and MaaS portal = $got"
    else
      bad "$role: got '$got', wanted '$want'"
    fi
  else
    bad "$role: chart render or DataScienceCluster extraction failed"
  fi

  if render "$T/undeclared/values.yaml" "$T/undeclared/roles/$role.yaml" "$T/$role-undeclared.yaml" &&
     got=$(states "$T/$role-undeclared.yaml"); then
    printf '   info %s: undeclared standard resolves to %s\n' "$role" "${got%% *}"
  else
    bad "$role: unable to observe undeclared standard"
  fi
done
echo "dashboard-state tests: $((total-fails)) ok, $fails failed"
exit "$fails"
