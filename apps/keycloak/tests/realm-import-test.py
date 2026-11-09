#!/usr/bin/env python3
"""Renders every Keycloak overlay and checks the realm import contract.

- keycloak-realm-import holds every realm (saas, and with the examples the
  tenant IdP realms), each imported only when it is missing. The tenant realms'
  users have fixed ids, which saas links its brokered users to, so importing a
  tenant realm again keeps the links. The tenant realms behave like an
  organization's own identity provider: their broker client sends groups from
  group membership and roles from its own client roles, and no user carries
  claim values as attributes.
- Two PostSync hooks apply saas-realm.json to an existing realm, the bootstrap
  Job before the sync Job. The bootstrap Job holds the bootstrap admin's two
  keys and the sync client's secret; the sync Job holds exactly the values the
  saas realm file's placeholders need, and never the admin's.
- The direct overlay, applied with kubectl, has no hooks.

Usage: realm-import-test.py OUT_DIR. For each overlay it writes, under
OUT_DIR/<overlay>, the files and scripts the containers see, which
realm-import-test.sh runs. Needs kubectl and PyYAML.
"""

import ast
import json
import os
import re
import subprocess
import sys

import yaml

APP = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT_DIR = sys.argv[1]
PLACEHOLDER = re.compile(r"\$\{([A-Z0-9_]+)\}")
SYNC_SECRET = "KEYCLOAK_REALM_SYNC_CLIENT_SECRET"
ADMIN_KEYS = {"KC_BOOTSTRAP_ADMIN_USERNAME", "KC_BOOTSTRAP_ADMIN_PASSWORD"}
KEYCLOAK_URL = {"name": "KEYCLOAK_URL", "value": "http://keycloak.maas-db.svc.cluster.local:8080"}
# Where each placeholder's value lives.
SOURCES = {
    "KEYCLOAK_CLIENT_ID": ("secretKeyRef", "keycloak-secrets", "KEYCLOAK_CLIENT_ID"),
    "KEYCLOAK_HOME_URL": ("secretKeyRef", "keycloak-secrets", "KEYCLOAK_HOME_URL"),
    "KEYCLOAK_REDIRECT_URI": ("secretKeyRef", "keycloak-secrets", "KEYCLOAK_REDIRECT_URI"),
    "KEYCLOAK_CLIENT_SECRET": ("secretKeyRef", "keycloak-secrets", "KEYCLOAK_CLIENT_SECRET"),
    "GRID_TENANT_1_BROKER_CLIENT_SECRET": ("secretKeyRef", "keycloak-secrets", "GRID_TENANT_1_BROKER_CLIENT_SECRET"),
    "GRID_TENANT_2_BROKER_CLIENT_SECRET": ("secretKeyRef", "keycloak-secrets", "GRID_TENANT_2_BROKER_CLIENT_SECRET"),
    "KEYCLOAK_REDIRECT_URIS_CLIENT_SECRET": (
        "secretKeyRef", "keycloak-redirect-uris-secret", "KEYCLOAK_REDIRECT_URIS_CLIENT_SECRET"),
    SYNC_SECRET: ("secretKeyRef", "keycloak-realm-sync-secret", SYNC_SECRET),
    "KEYCLOAK_SIGNING_KEYSTORE_PASSWORD": ("secretKeyRef", "keycloak-signing-keystore-password", "password"),
    "KEYCLOAK_PUBLIC_URL": ("configMapKeyRef", "keycloak-public-url", "KEYCLOAK_PUBLIC_URL"),
}
KEYCLOAK_START = [
    "set -Eeuo pipefail",
    "/opt/keycloak/bin/kc.sh import --dir /opt/keycloak/data/import/create-only --override false",
    "exec /opt/keycloak/bin/kc.sh start",
]


def render(overlay):
    output = subprocess.check_output(["kubectl", "kustomize", os.path.join(APP, "overlays", overlay)])
    return [document for document in yaml.safe_load_all(output) if document]


def find(documents, kind, name):
    found = [d for d in documents if d.get("kind") == kind and d["metadata"]["name"] == name]
    assert len(found) == 1, (kind, name, len(found))
    return found[0]


def generated(documents, prefix):
    found = [d for d in documents if d.get("kind") == "ConfigMap"
             and re.fullmatch(re.escape(prefix) + r"-[a-z0-9]{10}", d["metadata"]["name"])]
    assert len(found) <= 1, prefix
    return found[0] if found else None


def script(container):
    parts = container.get("command", []) + container.get("args", [])
    assert parts[:2] == ["/bin/bash", "-c"], parts[:2]
    return parts[2]


def volumes(pod_spec):
    return {volume["name"]: volume for volume in pod_spec.get("volumes", [])}


def mounts(container):
    return {mount["mountPath"]: mount for mount in container.get("volumeMounts", [])}


def placeholders(text):
    return set(PLACEHOLDER.findall(text))


def env_sources(container):
    """{name: (kind, object, key)} for the env read from Secrets and ConfigMaps."""
    sources = {}
    for variable in container.get("env", []):
        reference = variable.get("valueFrom")
        if reference is None:
            continue
        (kind, ref), = reference.items()
        sources[variable["name"]] = (kind, ref["name"], ref["key"])
    return sources


def check_hook_pod(job, name):
    annotations = job["metadata"]["annotations"]
    assert annotations["argocd.argoproj.io/hook"] == "PostSync", name
    assert set(annotations["argocd.argoproj.io/hook-delete-policy"].split(",")) == {
        "BeforeHookCreation", "HookSucceeded"}, name
    pod = job["spec"]["template"]["spec"]
    assert pod["restartPolicy"] == "Never", name
    assert pod["automountServiceAccountToken"] is False, name
    assert pod["enableServiceLinks"] is False, name
    assert "serviceAccountName" not in pod, name
    assert pod["securityContext"] == {"seccompProfile": {"type": "RuntimeDefault"}}, name
    assert len(pod["containers"]) == 1 and "initContainers" not in pod, name
    container = pod["containers"][0]
    assert "envFrom" not in container, name
    assert container["securityContext"] == {
        "allowPrivilegeEscalation": False,
        "readOnlyRootFilesystem": True,
        "capabilities": {"drop": ["ALL"]},
    }, name
    for volume in pod["volumes"]:
        assert "secret" not in volume and "projected" not in volume, (name, volume)
        if "emptyDir" in volume:
            assert volume["emptyDir"]["medium"] == "Memory", (name, volume)
    for mount in container["volumeMounts"]:
        if "configMap" in volumes(pod)[mount["name"]]:
            assert mount["readOnly"] is True, (name, mount)
    return pod, container


TENANT_REALM_FILES = ("grid-tenant-1-idp-realm.json", "grid-tenant-2-idp-realm.json")
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"


def check_tenant_realm(name, realm):
    """A tenant IdP realm sends groups and roles the way an organization's own identity provider would."""
    assert realm["realm"] != "saas", name
    broker = [c for c in realm["clients"] if c["clientId"] == "saas-broker"]
    assert len(broker) == 1, name
    mappers = {m["config"].get("claim.name"): m for m in broker[0]["protocolMappers"]}
    groups, roles = mappers["groups"], mappers["roles"]
    # groups: the user's group names, from group membership.
    assert groups["protocolMapper"] == "oidc-group-membership-mapper", (name, groups)
    assert groups["config"]["full.path"] == "false", name
    # roles: the user's roles of the broker client, unprefixed.
    assert roles["protocolMapper"] == "oidc-usermodel-client-role-mapper", (name, roles)
    assert roles["config"]["usermodel.clientRoleMapping.clientId"] == "saas-broker", name
    assert roles["config"].get("usermodel.clientRoleMapping.rolePrefix", "") == "", name
    assert roles["config"]["multivalued"] == "true", name
    for mapper in (groups, roles):
        assert mapper["config"]["id.token.claim"] == "true", (name, mapper["name"])
    # Top-level groups only, and only the broker client's roles.
    group_paths = {"/" + group["name"] for group in realm.get("groups", [])}
    assert all(not group.get("subGroups") for group in realm.get("groups", [])), name
    broker_roles = {role["name"] for role in realm["roles"]["client"]["saas-broker"]}
    assert set(realm["roles"]) == {"client"} and set(realm["roles"]["client"]) == {"saas-broker"}, name
    admins = 0
    for user in realm["users"]:
        assert re.fullmatch(UUID, user.get("id", "")), (name, user["username"])
        # No claim value lives in a user attribute: the admin manages groups and roles.
        assert not any(key.startswith("maas_") for key in user.get("attributes", {})), (name, user["username"])
        assert set(user.get("groups", [])) <= group_paths, (name, user["username"])
        client_roles = user.get("clientRoles", {})
        assert set(client_roles) <= {"saas-broker", "realm-management"}, (name, user["username"])
        assert set(client_roles.get("saas-broker", [])) <= broker_roles, (name, user["username"])
        assert "realmRoles" not in user, (name, user["username"])
        if "admins" in client_roles.get("saas-broker", []):
            admins += 1
            # The organization's admin administers its identity provider's users and groups, nothing else.
            assert set(client_roles["realm-management"]) == IDP_ADMIN_ROLES, (name, user["username"])
        else:
            assert "realm-management" not in client_roles, (name, user["username"])
    assert admins >= 1, name


IDP_ADMIN_ROLES = {"view-users", "query-users", "query-groups", "query-clients", "manage-users"}


def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as stream:
        stream.write(content)


def check_overlay(overlay, with_examples, with_hooks):
    documents = render(overlay)
    out = os.path.join(OUT_DIR, overlay)

    realm_import = generated(documents, "keycloak-realm-import")
    scripts = generated(documents, "keycloak-realm-scripts")
    assert generated(documents, "keycloak-realm-overwrite") is None, overlay
    saas_source = "components/examples/saas-realm.json" if with_examples else "base/manifests/realms/saas-realm.json"
    assert realm_import["data"]["saas-realm.json"] == open(os.path.join(APP, saas_source)).read(), overlay
    if with_examples:
        assert set(realm_import["data"]) == {"saas-realm.json", *TENANT_REALM_FILES}, overlay
        user_ids = []
        for name in TENANT_REALM_FILES:
            content = realm_import["data"][name]
            assert content == open(os.path.join(APP, "components/examples", name)).read(), name
            check_tenant_realm(name, json.loads(content))
            user_ids += [user["id"] for user in json.loads(content)["users"]]
        assert user_ids and len(user_ids) == len(set(user_ids)), user_ids
    else:
        assert set(realm_import["data"]) == {"saas-realm.json"}, overlay
    assert set(scripts["data"]) == {"render-realm.sh", "sync-saas-realm.py"}, overlay
    for name, content in scripts["data"].items():
        assert content == open(os.path.join(APP, "base/manifests/scripts", name)).read(), name

    # The Deployment: keycloak-realm-import is rendered to create-only, the
    # only import.
    deployment = find(documents, "Deployment", "keycloak")
    assert deployment["spec"]["strategy"] == {"type": "RollingUpdate"}, overlay
    pod = deployment["spec"]["template"]["spec"]
    pod_volumes = volumes(pod)
    init = next(c for c in pod["initContainers"] if c["name"] == "render-realm-import")
    keycloak = next(c for c in pod["containers"] if c["name"] == "keycloak")
    init_mounts = mounts(init)
    assert pod_volumes[init_mounts["/opt/keycloak/realm-import-source"]["name"]]["configMap"]["name"] == \
        realm_import["metadata"]["name"], overlay
    assert pod_volumes[init_mounts["/opt/keycloak/realm-scripts"]["name"]]["configMap"]["name"] == \
        scripts["metadata"]["name"], overlay
    assert "/opt/keycloak/realm-overwrite-source" not in init_mounts, overlay
    # The rendered realms hold secrets.
    assert pod_volumes[init_mounts["/opt/keycloak/data/import"]["name"]]["emptyDir"]["medium"] == "Memory"
    init_script = script(init)
    assert "render_dir /opt/keycloak/realm-import-source /opt/keycloak/data/import/create-only" in init_script
    assert "overwrite" not in init_script and "override true" not in script(keycloak), overlay
    assert "bash /opt/keycloak/realm-scripts/render-realm.sh" in init_script
    assert {"keycloak-secrets", "keycloak-redirect-uris-secret", "keycloak-realm-sync-secret"} <= {
        source["secretRef"]["name"] for source in init.get("envFrom", []) if "secretRef" in source}, overlay
    start = [line.strip() for line in script(keycloak).strip().splitlines()]
    assert start == KEYCLOAK_START, start

    # render-realm.sh knows every placeholder of every realm file.
    known = set(re.search(r"^placeholders=\(\n(.*?)\n\)$", scripts["data"]["render-realm.sh"],
                          re.MULTILINE | re.DOTALL).group(1).split())
    for name in ("base/manifests/realms/saas-realm.json", "components/examples/saas-realm.json",
                 "components/examples/grid-tenant-1-idp-realm.json",
                 "components/examples/grid-tenant-2-idp-realm.json"):
        assert placeholders(open(os.path.join(APP, name)).read()) <= known, name
    assert known == set(SOURCES) | {"GRID_TENANT_1_TEST_USER_PASSWORD", "GRID_TENANT_2_TEST_USER_PASSWORD"}, known

    # The sync client in the realm file.
    realm = json.loads(realm_import["data"]["saas-realm.json"])
    sync_client = next(c for c in realm["clients"] if c["clientId"] == "keycloak-realm-sync")
    assert sync_client["serviceAccountsEnabled"] is True
    assert sync_client["publicClient"] is False
    assert sync_client["standardFlowEnabled"] is False
    assert sync_client["directAccessGrantsEnabled"] is False
    assert sync_client["secret"] == "${%s}" % SYNC_SECRET
    account = next(u for u in realm["users"] if u.get("serviceAccountClientId") == "keycloak-realm-sync")
    assert account["clientRoles"] == {
        "realm-management": ["manage-realm", "manage-clients", "manage-identity-providers", "manage-users"]}
    assert "realmRoles" not in account

    jobs = [d for d in documents if d.get("kind") == "Job"]
    if not with_hooks:
        assert jobs == [], overlay
    else:
        assert {job["metadata"]["name"] for job in jobs} == {"keycloak-realm-sync-bootstrap",
                                                            "keycloak-saas-realm-sync"}, overlay
        bootstrap_job = find(documents, "Job", "keycloak-realm-sync-bootstrap")
        sync_job = find(documents, "Job", "keycloak-saas-realm-sync")
        # Argo CD runs hooks of one phase in sync-wave order: bootstrap first.
        waves = {job["metadata"]["name"]: int(job["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"])
                 for job in jobs}
        assert waves["keycloak-realm-sync-bootstrap"] < waves["keycloak-saas-realm-sync"], waves

        # The bootstrap Job: the admin's two keys and the sync client's secret, nothing else.
        bootstrap_pod, bootstrap = check_hook_pod(bootstrap_job, "bootstrap")
        assert bootstrap["command"] == [
            "python3", "/opt/keycloak/realm-scripts/sync-saas-realm.py", "bootstrap",
            "/opt/keycloak/realm-import-source/saas-realm.json"], bootstrap["command"]
        assert env_sources(bootstrap) == {
            "KC_BOOTSTRAP_ADMIN_USERNAME": ("secretKeyRef", "keycloak-secrets", "KC_BOOTSTRAP_ADMIN_USERNAME"),
            "KC_BOOTSTRAP_ADMIN_PASSWORD": ("secretKeyRef", "keycloak-secrets", "KC_BOOTSTRAP_ADMIN_PASSWORD"),
            SYNC_SECRET: SOURCES[SYNC_SECRET],
        }, env_sources(bootstrap)
        assert KEYCLOAK_URL in bootstrap["env"]
        assert {v["name"] for v in bootstrap["env"]} == {"PYTHONDONTWRITEBYTECODE", "KEYCLOAK_URL"} | \
            set(env_sources(bootstrap)), bootstrap["env"]
        assert volumes(bootstrap_pod)["realm-import-source"]["configMap"]["name"] == realm_import["metadata"]["name"]
        assert volumes(bootstrap_pod)["realm-scripts"]["configMap"]["name"] == scripts["metadata"]["name"]
        assert set(volumes(bootstrap_pod)) == {"realm-import-source", "realm-scripts"}

        # The sync Job: exactly the saas file's placeholders and the sync
        # client's secret, each from where it lives; no admin key.
        sync_pod, sync = check_hook_pod(sync_job, "sync")
        sync_script = script(sync)
        assert "bash /opt/keycloak/realm-scripts/render-realm.sh" in sync_script
        assert "< /opt/keycloak/realm-import-source/saas-realm.json > /work/saas-realm.json" in sync_script
        assert "python3 /opt/keycloak/realm-scripts/sync-saas-realm.py sync /work/saas-realm.json" in sync_script
        sync_sources = env_sources(sync)
        wanted = placeholders(realm_import["data"]["saas-realm.json"]) | {SYNC_SECRET}
        assert set(sync_sources) == wanted, (overlay, sorted(set(sync_sources) ^ wanted))
        for name, source in sync_sources.items():
            assert source == SOURCES[name], (name, source)
        assert not ADMIN_KEYS & {v["name"] for v in sync["env"]}
        assert not any(source[2] in ADMIN_KEYS for source in sync_sources.values())
        assert KEYCLOAK_URL in sync["env"]
        assert {v["name"] for v in sync["env"]} == {"PYTHONDONTWRITEBYTECODE", "KEYCLOAK_URL"} | set(sync_sources)
        assert volumes(sync_pod)["realm-import-source"]["configMap"]["name"] == realm_import["metadata"]["name"]
        assert volumes(sync_pod)["realm-scripts"]["configMap"]["name"] == scripts["metadata"]["name"]
        assert volumes(sync_pod)["work"]["emptyDir"]["medium"] == "Memory"
        assert set(volumes(sync_pod)) == {"realm-import-source", "realm-scripts", "work"}, overlay
        write(os.path.join(out, "job.sh"), sync_script)
        write(os.path.join(out, "sync-env"), "\n".join(sorted(sync_sources)) + "\n")

    secret = find(documents, "ExternalSecret", "keycloak-realm-sync-secret")
    assert secret["spec"]["refreshPolicy"] == "CreatedOnce"
    assert secret["spec"]["target"]["name"] == "keycloak-realm-sync-secret"
    assert [rewrite["regexp"]["target"] for source in secret["spec"]["dataFrom"]
            for rewrite in source["rewrite"]] == [SYNC_SECRET]
    generator = secret["spec"]["dataFrom"][0]["sourceRef"]["generatorRef"]["name"]
    assert find(documents, "Password", generator)["spec"]["symbols"] == 0

    # The files as the containers see them, for realm-import-test.sh.
    root = os.path.join(out, "opt/keycloak")
    for name, content in realm_import["data"].items():
        write(os.path.join(root, "realm-import-source", name), content)
    for name, content in scripts["data"].items():
        write(os.path.join(root, "realm-scripts", name), content)
    write(os.path.join(out, "init.sh"), init_script.replace("/opt/keycloak", root))
    write(os.path.join(out, "start.sh"), script(keycloak))


SYNC_PY = open(os.path.join(APP, "base/manifests/scripts/sync-saas-realm.py")).read()

check_overlay("core", with_examples=False, with_hooks=True)
check_overlay("default", with_examples=True, with_hooks=True)
check_overlay("direct", with_examples=True, with_hooks=False)

# The sync script never overwrites by re-creation, and deletes only the
# mappers of the file's identity providers that the file dropped.
assert '"ifResourceExists"] = "SKIP"' in SYNC_PY
assert "OVERWRITE" not in SYNC_PY
deleting = set()
for function in ast.parse(SYNC_PY).body:
    if isinstance(function, ast.FunctionDef):
        for node in ast.walk(function):
            if isinstance(node, ast.Call) and node.args and isinstance(node.args[0], ast.Constant) \
                    and node.args[0].value == "DELETE":
                deleting.add(function.name)
assert deleting == {"delete_dropped_identity_provider_mappers"}, deleting
print("keycloak realm import render checks: ok")
