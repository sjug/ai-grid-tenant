#!/usr/bin/env bash
# Renders the Loki createNamespace parameter (extracted from the ApplicationSet) per label context, then the
# pinned chart per role and mode, asserting its Namespace objects. RHAI_CHART_DIR skips the OCI pull. Needs helm, git, PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/chart/templates"; fails=0; total=0
APPSET=$HERE/../hub/01-applicationset.yaml
python3 -c 'import sys, yaml, json
d = yaml.safe_load(open(sys.argv[1])); params = {}; chart = None
for s in d["spec"]["template"]["spec"]["sources"]:
    for p in (s.get("helm") or {}).get("parameters", []):
        if p["name"] in ("operator.rhoai.olm.createNamespace", "dependencies.loki.olm.createNamespace"): params[p["name"]] = p["value"]
    if s.get("repoURL", "").startswith("oci://") and s.get("path") == ".": chart = {"repoURL": s["repoURL"], "targetRevision": s["targetRevision"], "path": s["path"]}
assert len(params) == 2 and chart, (params, chart); json.dump({"params": params, "chart": chart}, open(sys.argv[2], "w"))' "$APPSET" "$T/appset.json"
python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["params"], open(sys.argv[2], "w"))' "$T/appset.json" "$T/params.json"
ok() { total=$((total+1)); printf '   ok   %-52s %s\n' "$1" "${2:-}"; }
bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %-52s %s\n' "$1" "${2:-}"; }

printf 'apiVersion: v2\nname: ns\nversion: 0.1.0\n' > "$T/chart/Chart.yaml"
cat > "$T/chart/templates/out.yaml" <<'END_TPL'
loki: "{{ tpl (index .Values.params "dependencies.loki.olm.createNamespace") (dict "metadata" (dict "labels" .Values.labels)) }}"
END_TPL
t() { # name want labels-json
  local name=$1 want=$2 labels=$3 got
  python3 -c 'import json,sys; json.dump({"params": json.load(open(sys.argv[1])), "labels": json.loads(sys.argv[2])}, open(sys.argv[3], "w"))' "$T/params.json" "$labels" "$T/v.json"
  got=$(helm template x "$T/chart" -f "$T/v.json" | sed -n 's/^loki: "\(.*\)"$/\1/p')
  if [ "$got" = "$want" ]; then ok "$name" "loki=$want"; else bad "$name" "got '$got' wanted $want"; fi; }
t platform-owned-namespace-not-created false '{"ai-grid/platform-namespaces": "true"}'
t self-managed-spoke-creates true '{"ai-grid/role": "inference"}'
t self-managed-hub-creates true '{"local-cluster": "true"}'
t other-label-value-creates true '{"ai-grid/platform-namespaces": "no"}'
rhoai=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["operator.rhoai.olm.createNamespace"])' "$T/params.json")
if [ "$rhoai" = '{{ ne (index .metadata.labels "local-cluster") "true" | toString }}' ]; then ok rhoai-operator-namespace-parameter-unchanged; else bad rhoai-operator-namespace-parameter-unchanged "$rhoai"; fi

# Part two: the pinned chart.
read -r repo rev path < <(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["chart"]; print(c["repoURL"], c["targetRevision"], c["path"])' "$T/appset.json")
if [ -n "${RHAI_CHART_DIR:-}" ]; then CHART=$RHAI_CHART_DIR
else
  helm pull "$repo" --version "$rev" --destination "$T/odh-gitops" --untar
  CHART=$T/odh-gitops/rhai-on-openshift-chart
fi
[ -f "$CHART/Chart.yaml" ] || { echo "chart not found at $CHART" >&2; exit 1; }
helm dependency build "$CHART" >/dev/null
render() { # role loki-create rhoai-create -> writes $T/out.json {namespaces: [...], loki_subscription_ns: ...}
  helm template rhai-on-openshift "$CHART" -f "$HERE/../values.yaml" -f "$HERE/../roles/$1.yaml" \
    --set praxis-gateway.grid.siteName=site \
    --set praxis-provider-gateway.grid.siteName=site \
    --set "dependencies.loki.olm.createNamespace=$2" --set "operator.rhoai.olm.createNamespace=$3" \
  | python3 -c 'import sys, yaml, json
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
ns = sorted(d["metadata"]["name"] for d in docs if d.get("kind") == "Namespace")
sub = [d["metadata"].get("namespace") for d in docs if d.get("kind") == "Subscription" and d["metadata"]["name"] == "loki-operator"]
json.dump({"namespaces": ns, "loki_subscription_ns": sub[0] if sub else None}, open(sys.argv[1], "w"))' "$T/out.json"; }
has_ns() { python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["namespaces"] else 1)' "$T/out.json" "$1"; }
sub_ns() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["loki_subscription_ns"])' "$T/out.json"; }
for role in combined ingress inference; do
  render "$role" true false
  if has_ns openshift-operators-redhat; then ok "$role: chart creates loki namespace when true"; else bad "$role: chart creates loki namespace when true" "absent"; fi
  if [ "$(sub_ns)" = openshift-operators-redhat ]; then ok "$role: loki subscription targets that namespace"; else bad "$role: loki subscription targets that namespace" "$(sub_ns)"; fi
  if has_ns redhat-ods-operator; then bad "$role: rhoai operator namespace left to its own parameter" "emitted"; else ok "$role: rhoai operator namespace left to its own parameter"; fi
  render "$role" false false
  if has_ns openshift-operators-redhat; then bad "$role: chart leaves loki namespace alone when false" "emitted"; else ok "$role: chart leaves loki namespace alone when false"; fi
  if [ "$(sub_ns)" = openshift-operators-redhat ]; then ok "$role: subscription still needs the platform namespace"; else bad "$role: subscription still needs the platform namespace" "$(sub_ns)"; fi
done
render combined false true
if has_ns redhat-ods-operator && ! has_ns openshift-operators-redhat; then ok "rhoai operator namespace follows only its own parameter"; else bad "rhoai operator namespace follows only its own parameter"; fi
echo "operator-namespaces tests: $((total-fails)) ok, $fails failed"; exit "$fails"
