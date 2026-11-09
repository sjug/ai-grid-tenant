#!/usr/bin/env bash
# Renders apps/metallb/chart per input shape and asserts the objects, and renders the ApplicationSet's range
# parameter (extracted from the YAML) from a ManagedCluster label. Needs helm and python3 with PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); CHART=$HERE/../chart; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %-54s %s\n' "$1" "${2:-}"; }
bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %-54s %s\n' "$1" "${2:-}"; }
cat > "$T/shape.py" <<'END_SHAPE'
import sys, yaml
out = []
for d in yaml.safe_load_all(sys.stdin):
    if not d: continue
    k = d["kind"]; n = d["metadata"]["name"]
    if k == "IPAddressPool": out.append(f"{k}/{n}[{','.join(d['spec']['addresses'])}|auto={d['spec']['autoAssign']}]")
    else: out.append(f"{k}/{n}")
print(" ".join(sorted(out)))
END_SHAPE
cat > "$T/appset.py" <<'END_APPSET'
import sys, yaml, json
d = yaml.safe_load(open(sys.argv[1])); spec = d["spec"]["template"]["spec"]
src = [s for s in spec["sources"] if "helm" in s][0]; params = {p["name"]: p["value"] for p in src["helm"]["parameters"]}
sel = d["spec"]["generators"][0]["clusters"]["selector"]
optin = [e for e in sel["matchExpressions"] if e["key"] == "ai-grid/metallb-pool"]
json.dump({"src": params["range"], "labels": {"ai-grid/metallb-pool": "192.0.2.10-192.0.2.50"}}, open(sys.argv[2], "w"))
ok = bool(optin) and optin[0]["operator"] == "Exists" and src["helm"].get("ignoreMissingValueFiles") is True \
     and src["helm"]["valueFiles"] == ["$values/apps/metallb/values-{{ .name }}.yaml"]
sys.exit(0 if ok else 1)
END_APPSET
render() { helm template metallb "$CHART" "$@" 2>&1; }
t() { # name want helm-args...
  local name=$1 want=$2; shift 2; local out got
  if ! out=$(render "$@"); then got="RENDER FAILED: $(printf '%s' "$out" | grep -m1 -o -E 'range .*|pool .*|is required.*' | head -1)"; else got=$(printf '%s' "$out" | python3 "$T/shape.py"); fi
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "got: $got"; fi; }
FULL='IPAddressPool/ai-grid[192.0.2.10-192.0.2.50|auto=True] L2Advertisement/ai-grid MetalLB/metallb Namespace/metallb-system OperatorGroup/metallb-operator Subscription/metallb-operator'
t "label range: operator, instance, one pool, L2" "$FULL" --set range=192.0.2.10-192.0.2.50
t "no input: render refused" "RENDER FAILED: range is required (the ai-grid/metallb-pool label) unless pools is set"
t "range not first-last: refused" 'RENDER FAILED: range "192.0.2.0/24" is not an IPv4 range first-last' --set range=192.0.2.0/24
t "range with a bad octet: refused" 'RENDER FAILED: range "192.0.2.10-192.0.2.300" is not an IPv4 range first-last' --set range=192.0.2.10-192.0.2.300
t "reversed range: refused" 'RENDER FAILED: range "192.0.2.50-192.0.2.10" ends before it starts' --set range=192.0.2.50-192.0.2.10
t "range across an octet boundary, ordered: accepted" 'IPAddressPool/ai-grid[192.0.1.200-192.0.2.10|auto=True] L2Advertisement/ai-grid MetalLB/metallb Namespace/metallb-system OperatorGroup/metallb-operator Subscription/metallb-operator' --set range=192.0.1.200-192.0.2.10
t "single-address range: accepted" 'IPAddressPool/ai-grid[192.0.2.10-192.0.2.10|auto=True] L2Advertisement/ai-grid MetalLB/metallb Namespace/metallb-system OperatorGroup/metallb-operator Subscription/metallb-operator' --set range=192.0.2.10-192.0.2.10
cat > "$T/site.yaml" <<'END_SITE'
pools:
  - name: tenant
    addresses: ["192.0.2.64/27", "192.0.2.100-192.0.2.110"]
  - name: transit
    addresses: ["198.51.100.0/28"]
    l2: false
    autoAssign: false
END_SITE
t "pools file: two pools, L2 only where asked, label ignored" 'IPAddressPool/tenant[192.0.2.64/27,192.0.2.100-192.0.2.110|auto=True] IPAddressPool/transit[198.51.100.0/28|auto=False] L2Advertisement/tenant MetalLB/metallb Namespace/metallb-system OperatorGroup/metallb-operator Subscription/metallb-operator' -f "$T/site.yaml" --set range=192.0.2.10-192.0.2.50
printf 'pools:\n  - name: empty\n    addresses: []\n' > "$T/empty.yaml"
t "pool without addresses: refused" 'RENDER FAILED: pool "empty" has no addresses' -f "$T/empty.yaml"
t "existing operator: no namespace, group or subscription" 'IPAddressPool/ai-grid[192.0.2.10-192.0.2.50|auto=True] L2Advertisement/ai-grid MetalLB/metallb' --set range=192.0.2.10-192.0.2.50 --set operator.install=false
t "existing instance too: pools only" 'IPAddressPool/ai-grid[192.0.2.10-192.0.2.50|auto=True] L2Advertisement/ai-grid' --set range=192.0.2.10-192.0.2.50 --set operator.install=false --set instance.create=false
if python3 "$T/appset.py" "$HERE/../hub/00-applicationset.yaml" "$T/v.json"; then ok "opt-in by label presence; optional per-site values file"; else bad "opt-in by label presence; optional per-site values file"; fi
mkdir -p "$T/tpl/templates"; printf 'apiVersion: v2\nname: tpl\nversion: 0.1.0\n' > "$T/tpl/Chart.yaml"
printf '%s\n' 'range: "{{ tpl .Values.src (dict "metadata" (dict "labels" .Values.labels) "name" "site") }}"' > "$T/tpl/templates/out.yaml"
got=$(helm template x "$T/tpl" -f "$T/v.json" | sed -n 's/^range: "\(.*\)"$/\1/p')
if [ "$got" = "192.0.2.10-192.0.2.50" ]; then ok "ApplicationSet passes the label as range"; else bad "ApplicationSet passes the label as range" "$got"; fi
cat > "$T/prune.py" <<'END_PRUNE'
import sys, yaml
want = {"Namespace", "OperatorGroup", "Subscription", "MetalLB"}; seen = {}
for d in yaml.safe_load_all(sys.stdin):
    if d: seen[d["kind"]] = d["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-options", "")
protected = {k for k, v in seen.items() if "Prune=false" in v}
sys.exit(0 if protected == want and not (set(seen) - want) & protected else 1)
END_PRUNE
if render --set range=192.0.2.10-192.0.2.50 | python3 "$T/prune.py"; then ok "operator objects never pruned; pools remain prunable"; else bad "operator objects never pruned; pools remain prunable"; fi
echo "metallb render tests: $((total-fails)) ok, $fails failed"; exit "$fails"
