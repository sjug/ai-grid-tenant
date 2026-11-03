#!/usr/bin/env bash
# Renders apps/rhoai/maas-sites per role and the ApplicationSet's enabled parameter (extracted from the YAML).
# Needs helm and PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); CHART="$HERE/../maas-sites"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %s\n' "$1"; }; bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %s\n' "$1"; }
if out=$(helm template x "$CHART" --set enabled=false) && ! printf '%s\n' "$out" | grep -v -E '^(#|---|$)' | grep -q .; then ok "inference (enabled=false) renders nothing"; else bad "inference render failed or rendered objects"; fi
helm template x "$CHART" > "$T/default.yaml"
if python3 - "$T/default.yaml" <<'END_PY'; then ok "ingress/combined renders the partial with both trust ConfigMaps"; else bad "default render shape"; fi
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x][0]
assert d["kind"] == "Authorino" and d["metadata"]["namespace"] == "kuadrant-system"
items = d["spec"]["volumes"]["items"]; assert len(items) == 1, items
assert items[0]["configMaps"] == ["odh-trusted-ca-bundle", "openshift-service-ca.crt"] and items[0]["mountPath"] == "/etc/pki/tls/certs"
assert "ServerSideApply=true" in d["metadata"]["annotations"]["argocd.argoproj.io/sync-options"]
END_PY
cat > "$T/extra.yaml" <<'END_V'
authorino:
  extraVolumeItems:
    - name: existing-mount
      mountPath: /etc/authorino/existing
      secrets:
        - existing-secret
END_V
helm template x "$CHART" -f "$T/extra.yaml" > "$T/extra-out.yaml"
if python3 - "$T/extra-out.yaml" <<'END_PY'; then ok "existing volume item declared in values is preserved next to the trust mount"; else bad "extra volume item lost"; fi
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x][0]; items = d["spec"]["volumes"]["items"]
assert [i["name"] for i in items] == ["trusted-ca-bundle", "existing-mount"], items
assert items[1]["secrets"] == ["existing-secret"] and items[1]["mountPath"] == "/etc/authorino/existing"
END_PY
if python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d["spec"]["template"]["spec"]["sources"]:
    if s.get("path") == "apps/rhoai/maas-sites":
        h = s["helm"]; assert h.get("ignoreMissingValueFiles") is True, "ignoreMissingValueFiles"
        assert any(v.endswith("/apps/rhoai/maas-sites/values-{{ .name }}.yaml") for v in h.get("valueFiles", [])), "per-site values file"
        open(sys.argv[2], "w").write([p for p in h["parameters"] if p["name"] == "enabled"][0]["value"]); break
else: raise SystemExit("maas-sites helm source not found")' "$HERE/../hub/01-applicationset.yaml" "$T/expr"; then ok "ApplicationSet passes a per-site values file (ignored when absent) to the chart"; else bad "ApplicationSet per-site values path"; fi
mkdir -p "$T/chart/templates"; printf 'apiVersion: v2\nname: enabled\nversion: 0.1.0\n' > "$T/chart/Chart.yaml"
cat > "$T/chart/templates/out.yaml" <<'END_TPL'
enabled: "{{ tpl .Values.expr (dict "metadata" (dict "labels" .Values.labels)) }}"
END_TPL
for pair in "inference false" "ingress true" "combined true"; do read -r role want <<<"$pair"
  python3 -c 'import json,sys; json.dump({"expr": open(sys.argv[1]).read(), "labels": {"ai-grid/role": sys.argv[2]}}, open(sys.argv[3], "w"))' "$T/expr" "$role" "$T/v.json"
  got=$(helm template x "$T/chart" -f "$T/v.json" | sed -n 's/^enabled: "\(.*\)"$/\1/p')
  if [ "$got" = "$want" ]; then ok "enabled parameter for role $role = $got"; else bad "enabled parameter for role $role = '$got', wanted $want"; fi
done
echo "maas-sites render tests: $((total-fails)) ok, $fails failed"; exit "$fails"
