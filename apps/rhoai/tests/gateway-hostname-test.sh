#!/usr/bin/env bash
# Renders the MaaS Gateway hostname policy and checks its ApplicationSet wiring.
# Needs helm, PyYAML and kubectl.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

helm template rhoai-gateway-hostname "$HERE/../gateway-hostname" \
  -f "$HERE/../values.yaml" \
  --set clusterNamespace=target-cluster > "$TMP_DIR/rendered.yaml"

python3 - "$TMP_DIR/rendered.yaml" "$HERE/../hub/01-applicationset.yaml" <<'PY'
import sys
import yaml

rendered_documents = list(yaml.safe_load_all(open(sys.argv[1])))
policy = next(document for document in rendered_documents
               if document and document.get("kind") == "ConfigurationPolicy")
assert policy["metadata"]["namespace"] == "target-cluster"
gateway = policy["spec"]["object-templates"][0]["objectDefinition"]
assert gateway["metadata"]["name"] == "maas-default-gateway"
assert gateway["metadata"]["namespace"] == "openshift-ingress"
hostnames = [listener["hostname"] for listener in gateway["spec"]["listeners"]]
assert hostnames == [
    "maas.{{ (lookup \"config.openshift.io/v1\" \"Ingress\" \"\" \"cluster\").spec.domain }}",
    "maas.{{ (lookup \"config.openshift.io/v1\" \"Ingress\" \"\" \"cluster\").spec.domain }}",
], hostnames

appset = yaml.safe_load(open(sys.argv[2]))
sources = appset["spec"]["template"]["spec"]["sources"]
source = next(item for item in sources if item.get("path") == "apps/rhoai/gateway-hostname")
assert source["helm"]["valueFiles"] == ["$values/apps/rhoai/values.yaml"]
parameters = {parameter["name"]: parameter["value"]
              for parameter in source["helm"]["parameters"]}
assert parameters == {"clusterNamespace": "{{ .name }}",
                      "role": '{{ index .metadata.labels "ai-grid/role" }}'}
differences = next(item for item in appset["spec"]["template"]["spec"]["ignoreDifferences"]
                   if item.get("kind") == "Gateway")
assert differences["jqPathExpressions"] == [
    '.spec.listeners[] | select(.name == "http") | .hostname',
    '.spec.listeners[] | select(.name == "https") | .hostname',
]
PY

# An inference-only site has no MaaS Gateway: nothing renders there.
inference_objects=$(helm template rhoai-gateway-hostname "$HERE/../gateway-hostname" \
  -f "$HERE/../values.yaml" --set clusterNamespace=target-cluster --set role=inference |
  grep -c '^kind:' || true)
[ "$inference_objects" = 0 ] || { echo "gateway-hostname renders $inference_objects objects for role inference" >&2; exit 1; }

echo "gateway-hostname tests: 2 ok, 0 failed"
