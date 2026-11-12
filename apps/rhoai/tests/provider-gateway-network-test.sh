#!/usr/bin/env bash
# Renders the RHOAI ApplicationSet's gateway values and role profiles, then asserts
# that machine-network peers reach only the provider gateway. RHAI_CHART_DIR skips
# the OCI pull. Needs helm, PyYAML and, without RHAI_CHART_DIR, registry access.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tpl/templates" "$T/odh-gitops"
fails=0
total=0

ok() { total=$((total + 1)); printf '   ok   %-56s %s\n' "$1" "${2:-}"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); printf '   FAIL %-56s %s\n' "$1" "${2:-}"; }

python3 - "$HERE/../hub/01-applicationset.yaml" > "$T/source" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as stream:
    appset = yaml.safe_load(stream)
sources = [source for source in appset["spec"]["template"]["spec"]["sources"]
           if source.get("repoURL") == "oci://ghcr.io/opendatahub-io/odh-gitops/rhai-on-openshift-chart"]
assert len(sources) == 1, "expected exactly one RHOAI OCI chart source"
source = sources[0]
assert source.get("path") == ".", "expected the RHOAI OCI chart root path"
assert not any(source.get("path") == "apps/rhoai/grid-model-client"
               for source in appset["spec"]["template"]["spec"]["sources"]), \
    "the RHOAI chart must own grid-model-client resources"
print(source["repoURL"], source["targetRevision"])
PY
read -r repo chart_version < "$T/source"

if [ -n "${RHAI_CHART_DIR:-}" ]; then
  CHART=$RHAI_CHART_DIR
else
  helm pull "$repo" --version "$chart_version" --destination "$T/odh-gitops" --untar
  CHART=$T/odh-gitops/rhai-on-openshift-chart
fi
[ -f "$CHART/Chart.yaml" ] || { echo "chart not found at $CHART" >&2; exit 1; }
printf 'RHOAI chart version: %s\n' "$chart_version"

python3 - "$HERE/../hub/01-applicationset.yaml" "$T/src.json" <<'PY'
import json
import sys
import yaml

with open(sys.argv[1]) as stream:
    appset = yaml.safe_load(stream)
sources = [source for source in appset["spec"]["template"]["spec"]["sources"]
           if source.get("repoURL") == "oci://ghcr.io/opendatahub-io/odh-gitops/rhai-on-openshift-chart"]
assert len(sources) == 1, "expected exactly one RHOAI OCI chart source"
source = sources[0]
value_files = source["helm"]["valueFiles"]
assert not any("provider-gateway.yaml" in value_file for value_file in value_files), \
    "the RHOAI source must not read provider-gateway.yaml"
json.dump({"values": source["helm"]["values"]}, open(sys.argv[2], "w"))
PY
if [ -e "$HERE/../provider-gateway.yaml" ]; then
  bad "provider-gateway.yaml is absent" "$HERE/../provider-gateway.yaml"
else
  ok "provider-gateway.yaml is absent"
fi

if python3 - "$HERE/../values.yaml" <<'PY'
import sys
import yaml

values = yaml.safe_load(open(sys.argv[1]))
related_images = {item["name"]: item["value"]
                  for item in values["global"]["relatedImages"]}
expected = {
    "RELATED_IMAGE_ODH_PRAXIS_AI_GRID_GATEWAY_IMAGE":
        "registry.redhat.io/rhoai/odh-praxis-ai-grid-gateway-rhel9@sha256:3b59054cd8cc84fa44bd3b77e3d2648f8e28578ec9a298d8cd3128b4c6bfe472",
}
assert related_images == expected, f"unexpected Grid related images: {related_images}"
PY
then
  ok "Grid payload images are tenant-owned"
else
  bad "Grid payload images are tenant-owned" "related-image contract failed"
fi

printf 'apiVersion: v2\nname: tpl\nversion: 0.1.0\n' > "$T/tpl/Chart.yaml"
printf '%s\n' '{{ tpl .Values.src (dict "metadata" (dict "labels" .Values.labels) "name" "site") }}' \
  > "$T/tpl/templates/values.yaml"

render_values() {
  local labels_json=$1
  python3 - "$T/src.json" "$labels_json" "$T/in.json" <<'PY'
import json
import sys

source = json.load(open(sys.argv[1]))
json.dump({"src": source["values"], "labels": json.loads(sys.argv[2])}, open(sys.argv[3], "w"))
PY
  helm template x "$T/tpl" -f "$T/in.json" | grep -v -E '^(---|# Source:)' > "$T/values.yaml"
}

render_role() {
  local role=$1 labels_json=$2
  render_values "$labels_json"
  helm template rhai-on-openshift "$CHART" \
    -f "$HERE/../values.yaml" \
    -f "$HERE/../roles/$role.yaml" \
    -f "$T/values.yaml" \
    --set skipCrdCheck=true \
    --set praxis-gateway.grid.siteName=site \
    --set praxis-provider-gateway.grid.siteName=site \
    --set operator.rhoai.olm.createNamespace=false \
    --set dependencies.loki.olm.createNamespace=false \
    > "$T/render.yaml"
}

policy_peers() {
  local policy_name=$1
  python3 - "$T/render.yaml" "$policy_name" <<'PY'
import sys
import yaml

def peers(entries):
    result = []
    for entry in entries:
        if "ipBlock" in entry:
            result.append("ipBlock=" + entry["ipBlock"]["cidr"])
        elif "namespaceSelector" in entry:
            labels = entry["namespaceSelector"]["matchLabels"]
            result.append("ns=" + ",".join(f"{key}={value}" for key, value in labels.items()))
        elif "podSelector" in entry:
            labels = entry["podSelector"]["matchLabels"]
            result.append("pod=" + ",".join(f"{key}={value}" for key, value in labels.items()))
    return " ".join(result)

for document in yaml.safe_load_all(open(sys.argv[1])):
    if document and document.get("kind") == "NetworkPolicy" and document["metadata"]["name"] == sys.argv[2]:
        print(peers(document["spec"]["ingress"][0]["from"]))
        break
else:
    print("NO NETWORKPOLICY")
PY
}

BASE='pod=grid.opendatahub.io/gateway-client=true ns=network.openshift.io/policy-group=ingress'
INVALID='ipBlock=invalid ai-grid/machine-network label '

check() {
  local description=$1 expected=$2 role=$3 policy_name=$4 labels_json=$5
  if render_role "$role" "$labels_json" && got=$(policy_peers "$policy_name"); then
    if [ "$got" = "$expected" ]; then
      ok "$description"
    else
      bad "$description" "$got"
    fi
  else
    bad "$description" "render failed"
  fi
}

check_contract() {
  local description=$1 role=$2 labels_json=$3
  if render_role "$role" "$labels_json" &&
     python3 - "$T/render.yaml" "$HERE/../hub/02-ingress-clusters-policy.yaml" "$role" <<'PY'
import sys
import yaml
from pathlib import Path

render_path, policy_path, role = sys.argv[1:]
rbac_path = Path(policy_path).with_name("00-tenant-templating-rbac.yaml")
documents = [document for document in yaml.safe_load_all(open(render_path)) if document]
services = {document["metadata"]["name"]: document for document in documents
            if document.get("kind") == "Service"}
config_maps = {document["metadata"]["name"]: document for document in documents
               if document.get("kind") == "ConfigMap"}
deployments = {document["metadata"]["name"]: document for document in documents
               if document.get("kind") == "Deployment"}
service_accounts = {document["metadata"]["name"] for document in documents
                    if document.get("kind") == "ServiceAccount"}
secrets = {document["metadata"]["name"] for document in documents
           if document.get("kind") == "Secret"}
payload_image = \
    "registry.redhat.io/rhoai/odh-praxis-ai-grid-gateway-rhel9@sha256:3b59054cd8cc84fa44bd3b77e3d2648f8e28578ec9a298d8cd3128b4c6bfe472"

if "grid-provider-gateway" in deployments:
    provider = deployments["grid-provider-gateway"]["spec"]["template"]["spec"]
    praxis = next(container for container in provider["containers"] if container["name"] == "praxis")
    assert praxis["image"] == payload_image, "provider gateway lost its RHOAI payload image"

expected_services = {
    "ingress": {"grid-gateway"},
    "inference": {"grid-provider-gateway"},
    "combined": {"grid-gateway", "grid-provider-gateway"},
}[role]
assert set(services) >= expected_services, f"missing services: {expected_services - set(services)}"
assert set(services).isdisjoint({"grid-gateway", "grid-provider-gateway"} - expected_services), \
    f"unexpected gateways: {set(services) & ({'grid-gateway', 'grid-provider-gateway'} - expected_services)}"

expected_model_clients = {
    "ingress": set(),
    "inference": {"grid-model-client", "grid-model-client-token"},
    "combined": {"grid-model-client", "grid-model-client-token"},
}[role]
assert expected_model_clients <= service_accounts | secrets, \
    f"missing chart-owned model-client resources: {expected_model_clients - (service_accounts | secrets)}"
assert not ({"grid-model-client", "grid-model-client-token"} - expected_model_clients) & (service_accounts | secrets), \
    "unexpected model-client resources"

if "grid-gateway" in services:
    consumer = deployments["grid-gateway"]["spec"]["template"]["spec"]
    praxis = next(container for container in consumer["containers"] if container["name"] == "praxis")
    assert praxis["image"] == payload_image, "consumer gateway lost its RHOAI payload image"
    annotations = services["grid-gateway"]["metadata"].get("annotations", {})
    assert annotations.get("service.beta.openshift.io/serving-cert-secret-name") == \
        "grid-gateway-listener-tls", "grid-gateway lost its service certificate"
    config = config_maps["grid-gateway-config"]["data"]["praxis.yaml"]
    assert "/etc/praxis/listener-tls/tls.crt" in config, "grid-gateway lost its listener certificate"
    assert "filter: grid_site_route" in config, "grid-gateway lost its consumer route filter"

if "grid-provider-gateway" in services:
    annotations = services["grid-provider-gateway"]["metadata"].get("annotations", {})
    assert "service.beta.openshift.io/serving-cert-secret-name" not in annotations, \
        "grid-provider-gateway must serve its Grid identity, not a service certificate"
    config = config_maps["grid-provider-gateway-config"]["data"]["praxis.yaml"]
    assert "client_cert_mode: require_named" in config, "provider lost Grid mTLS"
    assert "filter: grid_provider" in config, "provider lost its Grid filter"

authorino = deployments["authorino"]["spec"]["template"]["spec"]
container = next(item for item in authorino["containers"] if item["name"] == "authorino")
if role in {"ingress", "combined"}:
    env = {item["name"]: item["value"] for item in container["env"]}
    assert "/etc/pki/tls/certs" in env["SSL_CERT_DIR"], "Authorino lost its trusted CA directory"
    trusted_mount = next((item for item in container["volumeMounts"]
                          if item["mountPath"] == "/etc/pki/tls/certs"), None)
    assert trusted_mount is not None, "Authorino trust bundle is not mounted"
    volumes = {item["name"]: item for item in authorino["volumes"]}
    config_maps_mounted = {source["configMap"]["name"]
                           for source in volumes[trusted_mount["name"]]["projected"]["sources"]}
    assert config_maps_mounted == {"odh-trusted-ca-bundle", "openshift-service-ca.crt", "home-keycloak-ca"}, \
        f"unexpected Authorino trust ConfigMaps: {config_maps_mounted}"

policy = yaml.safe_load(open(policy_path))
templates = policy["spec"]["policy-templates"]
ca_configuration = next(template["objectDefinition"] for template in templates
                        if template["objectDefinition"]["metadata"]["name"] == "rhoai-authorino-home-keycloak-ca")
ca_raw = ca_configuration["spec"]["object-templates-raw"]
assert "home-keycloak-ca" in ca_raw, "ACM lost the home Keycloak CA distribution"
assert "operator.authorino.kuadrant.io/v1beta1" in ca_raw, "ACM lost the Authorino CR volume contract"
hub_branch = ca_raw.split("{{hub- else hub}}", 1)[0]
assert "binaryData:" in hub_branch, "combined-hub Authorino CA branch is empty"
assert 'fromConfigMap "openshift-config-managed" "default-ingress-cert" "ca-bundle.crt"' in ca_raw, \
    "home CA must use the public default ingress certificate ConfigMap"
assert "fromSecret " not in ca_raw, \
    "home CA templating must not require Secret access"
assert 'lookup "v1" "Secret"' not in ca_raw, \
    "home CA lookup would require Secret list and watch permissions"
assert "ca-bundle.crt:" not in hub_branch, \
    "home CA must not reuse odh-trusted-ca-bundle's ca-bundle.crt key in Authorino's trust directory"
assert "home-keycloak-ca.crt:" in hub_branch, "home CA lost its own key"
assert "complianceType: mustonlyhave" in hub_branch, \
    "home CA must use mustonlyhave so the old ca-bundle.crt key is removed"
rbac_documents = list(yaml.safe_load_all(open(rbac_path)))
roles = [document for document in rbac_documents
         if document and document.get("kind") == "Role"]
assert not any(role["metadata"]["namespace"] == "openshift-ingress-operator" for role in roles), \
    "home CA templating must not use ingress-operator Secret RBAC"
managed_config_role = next(role for role in roles
                           if role["metadata"]["namespace"] == "openshift-config-managed")
config_map_rule = next(rule for rule in managed_config_role["rules"]
                       if rule["resources"] == ["configmaps"])
assert "resourceNames" not in config_map_rule, \
    "ConfigMap list and watch permissions cannot be constrained by resourceNames"
assert config_map_rule["verbs"] == ["get", "list", "watch"], \
    "home CA Role must only read public ingress ConfigMaps"
configuration = next(template["objectDefinition"] for template in templates
                     if template["objectDefinition"]["metadata"]["name"] == "rhoai-grid-external-provider")
external_provider = next(object_template["objectDefinition"]
                          for object_template in configuration["spec"]["object-templates"]
                          if object_template["objectDefinition"]["kind"] == "ExternalProvider")
assert external_provider["spec"]["endpoint"] == "grid-gateway.redhat-ai-grid.svc.cluster.local", \
    "MaaS no longer targets the consumer gateway"
assert external_provider["spec"]["config"]["tls.caCertificates"] == \
    "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt", \
    "MaaS no longer trusts the consumer gateway service certificate"
PY
  then
    ok "$description"
  else
    bad "$description" "contract check failed"
  fi
}

INGRESS='{"ai-grid/role":"ingress"}'
INFERENCE='{"ai-grid/role":"inference"}'
COMBINED='{"ai-grid/role":"combined"}'
INGRESS_NETWORK='{"ai-grid/role":"ingress","ai-grid/machine-network":"192.0.2.0_24"}'
INFERENCE_NETWORK='{"ai-grid/role":"inference","ai-grid/machine-network":"192.0.2.0_24"}'
COMBINED_NETWORK='{"ai-grid/role":"combined","ai-grid/machine-network":"192.0.2.0_24"}'

check "ingress consumer has base peers only" "$BASE" ingress grid-gateway "$INGRESS"
check "ingress has no provider gateway" "NO NETWORKPOLICY" ingress grid-provider-gateway "$INGRESS"
check "ingress machine network is not exposed" "$BASE" ingress grid-gateway "$INGRESS_NETWORK"
check "inference provider has base peers only" "$BASE" inference grid-provider-gateway "$INFERENCE"
check "inference has no consumer gateway" "NO NETWORKPOLICY" inference grid-gateway "$INFERENCE"
check "inference machine network reaches provider" "$BASE ipBlock=192.0.2.0/24" \
  inference grid-provider-gateway "$INFERENCE_NETWORK"
check "combined provider has base peers only" "$BASE" combined grid-provider-gateway "$COMBINED"
check "combined consumer has base peers only" "$BASE" combined grid-gateway "$COMBINED"
check "combined machine network reaches provider only" "$BASE ipBlock=192.0.2.0/24" \
  combined grid-provider-gateway "$COMBINED_NETWORK"
check "combined consumer excludes machine network" "$BASE" combined grid-gateway "$COMBINED_NETWORK"

for value in not-a-cidr 192.0.2.1_0 0.0.0.0_0 192.0.2.0_33 256.0.2.0_24 \
             192.0.2.0/24 192.0.2_24 '192.0.2.0_24 '; do
  labels_json="{\"ai-grid/role\":\"inference\",\"ai-grid/machine-network\":\"$value\"}"
  check "rejected label reaches provider unparseable: $value" "$BASE $INVALID$value" \
    inference grid-provider-gateway "$labels_json"
done

check "prefix 32 accepted" "$BASE ipBlock=192.0.2.7/32" inference grid-provider-gateway \
  '{"ai-grid/role":"inference","ai-grid/machine-network":"192.0.2.7_32"}'
check "prefix 1 accepted" "$BASE ipBlock=128.0.0.0/1" inference grid-provider-gateway \
  '{"ai-grid/role":"inference","ai-grid/machine-network":"128.0.0.0_1"}'

check_contract "ingress preserves the MaaS gateway and trust contract" ingress "$INGRESS"
check_contract "inference preserves the Grid provider contract" inference "$INFERENCE"
check_contract "combined preserves both gateway and trust contracts" combined "$COMBINED"

echo "provider-gateway-network tests: $((total - fails)) ok, $fails failed"
exit "$fails"
