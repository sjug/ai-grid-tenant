#!/usr/bin/env bash
# Renders the Keycloak app and checks the redirect URI reconciler contract.
# Needs kubectl and PyYAML.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

kubectl kustomize "$HERE/../base" > "$TMP_DIR/rendered.yaml"

python3 - "$TMP_DIR/rendered.yaml" "$TMP_DIR" \
  "$HERE/../base/manifests/realms/saas-realm.json" \
  "$HERE/../components/examples/saas-realm.json" <<'PY'
import copy
import sys
import json
import yaml

documents = list(yaml.safe_load_all(open(sys.argv[1])))
cron_job = next(document for document in documents
                if document and document.get("kind") == "CronJob"
                and document["metadata"]["name"] == "keycloak-redirect-uris")
keycloak_deployment = next(document for document in documents
                           if document and document.get("kind") == "Deployment"
                           and document["metadata"]["name"] == "keycloak")
assert cron_job["spec"]["schedule"] == "*/5 * * * *"
assert cron_job["spec"]["concurrencyPolicy"] == "Forbid"
pod_spec = cron_job["spec"]["jobTemplate"]["spec"]["template"]["spec"]
assert pod_spec["serviceAccountName"] == "keycloak-redirect-uris"

init_container = pod_spec["initContainers"][0]
update_container = pod_spec["containers"][0]
init_script = init_container["command"][2]
update_script = update_container["command"][2]
update_secret_names = {
    secret["secretRef"]["name"]
    for secret in update_container.get("envFrom", [])
    if "secretRef" in secret
}
assert "keycloak-redirect-uris-secret" in update_secret_names
keycloak_pod_spec = keycloak_deployment["spec"]["template"]["spec"]
keycloak_init_container = keycloak_pod_spec["initContainers"][0]
keycloak_init_secret_names = {
    secret["secretRef"]["name"]
    for secret in keycloak_init_container.get("envFrom", [])
    if "secretRef" in secret
}
assert "keycloak-redirect-uris-secret" in keycloak_init_secret_names
keycloak_container = next(container for container in keycloak_pod_spec["containers"]
                          if container["name"] == "keycloak")
assert "--override false" in keycloak_container["args"][0]
realm_volume = next(volume for volume in keycloak_pod_spec["volumes"]
                    if volume["name"] == "realm-import-source")
assert realm_volume["configMap"]["name"] != "keycloak-realm-import"
assert realm_volume["configMap"]["name"].startswith("keycloak-realm-import-")
assert "ai-grid/enabled=true,ai-grid/role in (ingress,combined)" in init_script
assert "consoleurl.cluster.open-cluster-management.io" in init_script
assert "https://maas.apps.%s/oauth2/callback" in init_script
assert "http://localhost:8000/callback" in init_script
assert "kcadm.sh update" in update_script
assert '--config "$kcadm_config"' in update_script
assert '--realm saas' in update_script
assert '--client keycloak-redirect-uris' in update_script
assert '--secret "$KEYCLOAK_REDIRECT_URIS_CLIENT_SECRET"' in update_script
assert "KC_BOOTSTRAP_ADMIN_USERNAME" not in update_script
assert "KC_BOOTSTRAP_ADMIN_PASSWORD" not in update_script
assert "redirectUris=" in update_script

secret = next(document for document in documents
              if document and document.get("kind") == "ExternalSecret"
              and document["metadata"]["name"] == "keycloak-redirect-uris-secret")
generators = {
    source["sourceRef"]["generatorRef"]["name"]
    for source in secret["spec"]["dataFrom"]
}
assert "keycloak-redirect-uris-client-secret" in generators
assert any(
    rewrite["regexp"]["target"] == "KEYCLOAK_REDIRECT_URIS_CLIENT_SECRET"
    for source in secret["spec"]["dataFrom"]
    for rewrite in source["rewrite"]
)
assert secret["spec"]["target"]["name"] == "keycloak-redirect-uris-secret"

realm_config_map = next(document for document in documents
                        if document and document.get("kind") == "ConfigMap"
                        and document["metadata"]["name"].startswith("keycloak-realm-import"))
realm = json.loads(realm_config_map["data"]["saas-realm.json"])
admin_client = next(client for client in realm["clients"]
                    if client["clientId"] == "keycloak-redirect-uris")
assert admin_client["serviceAccountsEnabled"] is True
service_account = next(user for user in realm["users"]
                       if user["serviceAccountClientId"] == "keycloak-redirect-uris")
assert service_account["clientRoles"]["realm-management"] == ["view-clients", "manage-clients"]
base_realm = json.load(open(sys.argv[3]))
examples_realm = json.load(open(sys.argv[4]))
expected_examples_realm = copy.deepcopy(base_realm)
for key in ("identityProviders", "identityProviderMappers", "organizations"):
    expected_examples_realm[key] = examples_realm[key]
assert examples_realm == expected_examples_realm
with open(f"{sys.argv[2]}/init.sh", "w") as stream:
    stream.write(init_script)
with open(f"{sys.argv[2]}/update.sh", "w") as stream:
    stream.write(update_script)
PY

bash -n "$TMP_DIR/init.sh"
bash -n "$TMP_DIR/update.sh"

echo "keycloak-redirect-uris tests: 1 ok, 0 failed"
