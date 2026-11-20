#!/usr/bin/env bash
# A cluster that already runs the platform's cert-manager Operator carries the ManagedCluster label
# ai-grid/platform-cert-manager=true, and the rhoai ApplicationSet's inline values then turn off the chart's
# cert-manager dependency. Renders those inline values (extracted from the ApplicationSet) per label context, then the
# pinned chart per role with each, and asserts that without the label nothing changes and with it exactly the chart's
# cert-manager Namespace, OperatorGroup and Subscription go away. A second OperatorGroup in cert-manager-operator fails
# the operator's CSV with TooManyOperatorGroups. RHAI_CHART_DIR skips the OCI pull. Needs helm and PyYAML.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/chart/templates"; fails=0; total=0
APPSET=$HERE/../hub/01-applicationset.yaml
ok() { total=$((total+1)); printf '   ok   %-62s %s\n' "$1" "${2:-}"; }
bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %-62s %s\n' "$1" "${2:-}"; }
python3 -c 'import sys, yaml, json
d = yaml.safe_load(open(sys.argv[1])); src = [s for s in d["spec"]["template"]["spec"]["sources"]
    if s.get("repoURL", "").startswith("oci://") and s.get("path") == "."]
assert len(src) == 1, src
json.dump({"values": src[0]["helm"]["values"], "chart": {"repoURL": src[0]["repoURL"], "targetRevision": src[0]["targetRevision"]}},
          open(sys.argv[2], "w"))' "$APPSET" "$T/appset.json"

# Part one: the ApplicationSet's inline values, templated as Argo CD would for a cluster with the given labels.
# Caveat: this uses Helm's tpl, not Argo CD's goTemplate with missingkey=error, so it misses errors only Argo CD raises.
printf 'apiVersion: v2\nname: values\nversion: 0.1.0\n' > "$T/chart/Chart.yaml"
printf '%s\n' '{{ tpl .Values.values (dict "name" "site" "metadata" (dict "labels" .Values.labels)) }}' > "$T/chart/templates/out.yaml"
inline() { # labels-json out
  python3 -c 'import json,sys; json.dump({"values": json.load(open(sys.argv[1]))["values"], "labels": json.loads(sys.argv[2])}, open(sys.argv[3], "w"))' \
    "$T/appset.json" "$1" "$T/in.json"
  helm template x "$T/chart" -f "$T/in.json" | sed '1,/^# Source:/d' > "$2"; }
inline '{"ai-grid/role": "combined"}' "$T/none.yaml"
inline '{"ai-grid/role": "combined", "ai-grid/platform-cert-manager": "false"}' "$T/false.yaml"
inline '{"ai-grid/role": "combined", "ai-grid/platform-cert-manager": "true"}' "$T/true.yaml"
check() { python3 -c 'import sys, yaml
none, other = (yaml.safe_load(open(p)) for p in sys.argv[2:4])
want = sys.argv[1] == "off"
dep = other.pop("dependencies", None)
if want:
    assert dep == {"certManager": {"enabled": False}}, dep
else:
    assert dep is None, dep
assert "dependencies" not in none and other == none, "other inline values changed"' "$@"; }
if cmp -s "$T/none.yaml" "$T/false.yaml" && check on "$T/none.yaml" "$T/false.yaml"; then ok "no label or another value: inline values unchanged"
else bad "no label or another value: inline values unchanged"; fi
if check off "$T/none.yaml" "$T/true.yaml"; then ok "label true: inline values add only certManager.enabled false"
else bad "label true: inline values add only certManager.enabled false"; fi

# Part two: the pinned chart, per role, with each set of inline values.
read -r repo rev < <(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["chart"]; print(c["repoURL"], c["targetRevision"])' "$T/appset.json")
if [ -n "${RHAI_CHART_DIR:-}" ]; then CHART=$RHAI_CHART_DIR
else
  helm pull "$repo" --version "$rev" --destination "$T/odh-gitops" --untar
  CHART=$T/odh-gitops/rhai-on-openshift-chart
fi
[ -f "$CHART/Chart.yaml" ] || { echo "chart not found at $CHART" >&2; exit 1; }
helm dependency build "$CHART" >/dev/null
printf 'RHOAI chart version: %s\n' "$rev"
render() { # role inline-values out
  helm template rhai-on-openshift "$CHART" -f "$HERE/../values.yaml" -f "$HERE/../roles/$1.yaml" -f "$2" \
    --set praxis-gateway.grid.siteName=site \
    --set praxis-provider-gateway.grid.siteName=site \
    --set operator.rhoai.olm.createNamespace=true \
    --set dependencies.loki.olm.createNamespace=true \
    --set dependencies.clusterObservability.enabled=true \
  | python3 -c 'import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d:
        print(d["kind"], d["metadata"].get("namespace") or "-", d["metadata"]["name"], yaml.safe_dump(d, sort_keys=True).replace("\n", "\\n"))' \
  | sort > "$3"; }
want='Namespace - cert-manager-operator
OperatorGroup cert-manager-operator openshift-cert-manager-operator
Subscription cert-manager-operator openshift-cert-manager-operator'
for role in combined ingress inference; do
  render "$role" "$T/none.yaml" "$T/$role-none.txt"
  render "$role" "$T/false.yaml" "$T/$role-false.txt"
  render "$role" "$T/true.yaml" "$T/$role-true.txt"
  got=$(cut -d' ' -f1-3 "$T/$role-none.txt" | grep ' cert-manager-operator' || true)
  if [ "$got" = "$want" ]; then ok "$role: chart installs cert-manager without the label"
  else bad "$role: chart installs cert-manager without the label" "got: $got"; fi
  if cmp -s "$T/$role-none.txt" "$T/$role-false.txt"; then ok "$role: another label value renders the same"
  else bad "$role: another label value renders the same"; fi
  removed=$(comm -23 "$T/$role-none.txt" "$T/$role-true.txt" | cut -d' ' -f1-3)
  added=$(comm -13 "$T/$role-none.txt" "$T/$role-true.txt" | cut -d' ' -f1-3)
  if [ "$removed" = "$want" ] && [ -z "$added" ]; then ok "$role: label removes only the chart's cert-manager"
  else bad "$role: label removes only the chart's cert-manager" "removed: $removed added: $added"; fi
done
echo "platform-cert-manager tests: $((total-fails)) ok, $fails failed"; exit "$fails"
