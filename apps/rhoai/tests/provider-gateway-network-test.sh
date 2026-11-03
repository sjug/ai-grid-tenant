#!/usr/bin/env bash
# Renders the provider gateway ApplicationSet's values under ManagedCluster label contexts, then the pinned
# chart, and asserts the NetworkPolicy peers per label value. RHAI_CHART_DIR skips the clone. Needs helm, git, PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/tpl/templates"; fails=0; total=0
APPSET=$HERE/../hub/04-provider-gateway-applicationset.yaml; VALUES=$HERE/../provider-gateway.yaml
ok() { total=$((total+1)); printf '   ok   %-56s %s\n' "$1" "${2:-}"; }
bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %-56s %s\n' "$1" "${2:-}"; }
python3 -c 'import sys, yaml, json
d = yaml.safe_load(open(sys.argv[1])); src = None
for s in d["spec"]["template"]["spec"]["sources"]:
    if s.get("path", "").endswith("praxis-gateway"): src = s
assert src, "no praxis-gateway source"
json.dump({"values": src["helm"]["values"], "repoURL": src["repoURL"], "targetRevision": src["targetRevision"], "path": src["path"],
           "valueFiles": src["helm"]["valueFiles"]}, open(sys.argv[2], "w"))' "$APPSET" "$T/src.json"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["valueFiles"])' "$T/src.json")" = "['\$values/apps/rhoai/provider-gateway.yaml']" ]; then
  ok "the ApplicationSet still reads provider-gateway.yaml"; else bad "the ApplicationSet still reads provider-gateway.yaml"; fi
if grep -q -E 'ipBlock|cidr' "$VALUES"; then bad "provider-gateway.yaml carries no address range" "$(grep -n -E 'ipBlock|cidr' "$VALUES" | head -1)"; else ok "provider-gateway.yaml carries no address range"; fi

# Render the values string the way the ApplicationSet controller does (go template with sprig).
printf 'apiVersion: v2\nname: tpl\nversion: 0.1.0\n' > "$T/tpl/Chart.yaml"
printf '%s\n' '{{ tpl .Values.src (dict "metadata" (dict "labels" .Values.labels) "name" "site") }}' > "$T/tpl/templates/values.yaml"
render_values() { # labels-json -> $T/values.yaml
  python3 -c 'import json,sys; json.dump({"src": json.load(open(sys.argv[1]))["values"], "labels": json.loads(sys.argv[2])}, open(sys.argv[3], "w"))' "$T/src.json" "$1" "$T/in.json"
  helm template x "$T/tpl" -f "$T/in.json" | grep -v -E '^(---|# Source:)' > "$T/values.yaml"; }
peers_of() { python3 -c 'import sys, yaml
def peers(lst):
    out = []
    for p in lst:
        if "ipBlock" in p: out.append("ipBlock=" + p["ipBlock"]["cidr"])
        elif "namespaceSelector" in p: out.append("ns=" + ",".join(f"{k}={v}" for k, v in p["namespaceSelector"]["matchLabels"].items()))
        elif "podSelector" in p: out.append("pod=" + ",".join(f"{k}={v}" for k, v in p["podSelector"]["matchLabels"].items()))
    return " ".join(out)
if sys.argv[1] == "values": print(peers(yaml.safe_load(open(sys.argv[2]))["networkPolicy"]["from"]))
else:
    for d in yaml.safe_load_all(sys.stdin):
        if d and d.get("kind") == "NetworkPolicy" and d["metadata"]["name"] == "grid-provider-gateway": print(peers(d["spec"]["ingress"][0]["from"])); break
    else: print("NO NETWORKPOLICY")' "$@"; }
BASE='pod=grid.opendatahub.io/gateway-client=true ns=network.openshift.io/policy-group=ingress'
t() { # name want labels-json
  render_values "$3"; local got; got=$(peers_of values "$T/values.yaml")
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1" "$got"; fi; }
t "no label: router and client peers only" "$BASE" '{"ai-grid/role": "inference"}'
t "label: machine network decoded and appended" "$BASE ipBlock=192.0.2.0/24" '{"ai-grid/role": "inference", "ai-grid/machine-network": "192.0.2.0_24"}'
t "empty label: no address range" "$BASE" '{"ai-grid/machine-network": ""}'
INVALID='ipBlock=invalid ai-grid/machine-network label '
for v in not-a-cidr 192.0.2.1_0 0.0.0.0_0 192.0.2.0_33 256.0.2.0_24 192.0.2.0/24 192.0.2_24 '192.0.2.0_24 '; do
  t "rejected label value: $v" "$BASE $INVALID$v" "{\"ai-grid/machine-network\": \"$v\"}"
done
t "prefix 32 accepted" "$BASE ipBlock=192.0.2.7/32" '{"ai-grid/machine-network": "192.0.2.7_32"}'
t "prefix 1 accepted" "$BASE ipBlock=128.0.0.0/1" '{"ai-grid/machine-network": "128.0.0.0_1"}'
# every rejected value must come out as something no CIDR parser accepts
if python3 -c 'import ipaddress, sys
for v in ["invalid ai-grid/machine-network label not-a-cidr", "invalid ai-grid/machine-network label 192.0.2.1_0"]:
    try: ipaddress.ip_network(v, strict=False); sys.exit("parsed: " + v)
    except ValueError: pass'; then ok "rejected values parse as no network"; else bad "rejected values parse as no network"; fi

# The pinned chart.
read -r repo rev path < <(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["repoURL"], c["targetRevision"], c["path"])' "$T/src.json")
if [ -n "${RHAI_CHART_DIR:-}" ]; then CHART=$RHAI_CHART_DIR
else
  git clone -q --depth 1 "$repo" "$T/odh-gitops" && git -C "$T/odh-gitops" fetch -q --depth 1 origin "$rev" && git -C "$T/odh-gitops" checkout -q FETCH_HEAD
  CHART=$T/odh-gitops/$path
fi
[ -f "$CHART/Chart.yaml" ] || { echo "chart not found at $CHART" >&2; exit 1; }
np_peers() { # labels-json -> the rendered NetworkPolicy's first ingress rule peers, or "RENDER FAILED: <last line>"
  render_values "$1"; local out
  if ! out=$(helm template grid-provider-gateway "$CHART" -f "$VALUES" -f "$T/values.yaml" --set grid.siteName=site 2>&1); then printf 'RENDER FAILED: %s' "$(printf '%s' "$out" | grep -m1 -i 'error')"; return; fi
  printf '%s' "$out" | peers_of manifest; }
c() { # name want labels-json
  local got; got=$(np_peers "$3")
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1" "$got"; fi; }
c "chart, no label: router and client peers only" "$BASE" '{"ai-grid/role": "inference"}'
c "chart, label: site network admitted" "$BASE ipBlock=192.0.2.0/24" '{"ai-grid/machine-network": "192.0.2.0_24"}'
c "chart, rejected label: unparseable cidr reaches the manifest" "$BASE ${INVALID}192.0.2.1_0" '{"ai-grid/machine-network": "192.0.2.1_0"}'
echo "provider-gateway-network tests: $((total-fails)) ok, $fails failed"; exit "$fails"
