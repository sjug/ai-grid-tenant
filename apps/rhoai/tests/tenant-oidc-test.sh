#!/usr/bin/env bash
# Checks the AITenant OIDC Secret namespace and hub-template add-on contract.
# Needs PyYAML.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

python3 - "$HERE/../hub/02-ingress-clusters-policy.yaml" "$HERE/../hub/00-tenant-templating-rbac.yaml" "$HERE/../../acm/manifests/core/policy-addons.yaml" <<'PY'
import sys
import yaml

policy = yaml.safe_load(open(sys.argv[1]))
rbac_documents = list(yaml.safe_load_all(open(sys.argv[2])))
templates = [template["objectDefinition"] for template in policy["spec"]["policy-templates"]]
secret_policy = next(template for template in templates
                      if template.get("metadata", {}).get("name") == "rhoai-tenant-oidc-client-secret")
# ai-gateway-controller reads spec.oidc.clientSecretRef in the AITenant's tenant
# namespace (status.tenantNamespace): the namespace of the MaasTenantConfig that
# rhoai-maastenantconfig creates. The Secret goes there, and only there.
config_policy = next(template for template in templates
                     if template.get("metadata", {}).get("name") == "rhoai-maastenantconfig")
config = next(t["objectDefinition"] for t in config_policy["spec"]["object-templates"]
              if t["objectDefinition"].get("kind") == "MaasTenantConfig")
tenant_namespace = config["metadata"]["namespace"]
secrets = [t["objectDefinition"] for t in secret_policy["spec"]["object-templates"]]
assert [s["metadata"]["namespace"] for s in secrets] == [tenant_namespace], secrets
assert secret_policy["spec"]["namespaceSelector"]["include"] == [tenant_namespace]
secret = secrets[0]
assert secret["metadata"]["name"] == "tenant-demo-oidc-client"
assert set(secret["data"]) == {"clientSecret"}

tenant_policy = next(template for template in templates
                      if template.get("metadata", {}).get("name") == "rhoai-aitenant")
tenant = tenant_policy["spec"]["object-templates"][0]["objectDefinition"]
assert tenant["metadata"]["namespace"] == "ai-tenants"
assert tenant["spec"]["oidc"]["clientSecretRef"] == {
    "name": "tenant-demo-oidc-client",
    "key": "clientSecret",
}

maas_role = next(document for document in rbac_documents
                 if document and document.get("kind") == "Role"
                 and document["metadata"]["namespace"] == "maas-db"
                 and document["metadata"]["name"] == "rhoai-tenant-templating")
secret_rules = [rule for rule in maas_role["rules"] if rule.get("resources") == ["secrets"]]
named_get = next(rule for rule in secret_rules if "get" in rule["verbs"])
assert named_get["resourceNames"] == ["keycloak-secrets"]
list_watch = next(rule for rule in secret_rules if "list" in rule["verbs"])
assert set(list_watch["verbs"]) == {"list", "watch"}
assert "resourceNames" not in list_watch

route_role = next(document for document in rbac_documents
                  if document and document.get("kind") == "Role"
                  and document["metadata"]["name"] == "rhoai-hub-templating-routes")
assert all("secrets" not in rule.get("resources", []) for rule in route_role["rules"])
route_binding = next(document for document in rbac_documents
                     if document and document.get("kind") == "RoleBinding"
                     and document["metadata"]["name"] == "rhoai-hub-templating-routes")
assert route_binding["subjects"] == [
    {"kind": "Group", "name": "system:open-cluster-management:addon:governance-standalone-hub-templating"}
]

addons = [document for document in yaml.safe_load_all(open(sys.argv[3])) if document]
templating = next(addon for addon in addons
                  if addon.get("kind") == "ClusterManagementAddOn"
                  and addon["metadata"]["name"] == "governance-standalone-hub-templating")
assert templating["spec"]["installStrategy"] == {
    "type": "Placements",
    "placements": [{"name": "policy-addons-clusters", "namespace": "open-cluster-management"}],
}
PY

echo "tenant-oidc tests: 1 ok, 0 failed"
