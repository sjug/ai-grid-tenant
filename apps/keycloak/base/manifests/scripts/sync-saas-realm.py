#!/usr/bin/env python3
"""Applies the Git-owned parts of saas-realm.json to the live saas realm.

Keycloak imports the saas realm only when it doesn't exist yet, so what is
created at runtime (organizations, their identity providers, users) survives a
restart. The two Argo CD hooks that run this script are how an edit to
saas-realm.json reaches a realm that already exists.

sync-saas-realm.py bootstrap REALM_FILE
    The keycloak-realm-sync-bootstrap hook. REALM_FILE is the realm file as it
    is in Git, placeholders and all: only the keycloak-realm-sync client and
    its service account are read from it. When that client signs in and its
    service account holds the roles the file gives it, this exits without
    signing in as anyone else. Otherwise (a realm imported before the client
    was in the file, or a client secret generated again) it signs in to master
    as the bootstrap admin and creates or repairs only that client and its
    roles.
    Environment: KEYCLOAK_URL, KEYCLOAK_REALM_SYNC_CLIENT_SECRET,
    KC_BOOTSTRAP_ADMIN_USERNAME and KC_BOOTSTRAP_ADMIN_PASSWORD.

sync-saas-realm.py sync RENDERED_REALM_FILE
    The keycloak-saas-realm-sync hook. Signs in as keycloak-realm-sync and
    applies the rendered file. It deletes and re-creates nothing:
    - the realm's settings: the file's top-level values that aren't lists or
      objects;
    - a partial import with ifResourceExists SKIP adds the clients, identity
      providers, identity provider mappers, users, groups and roles the realm
      lacks;
    - the built-in first broker login flow requires a unique user and keeps its
      organization membership step;
    - the profile client scope's username mapper and declarative user profile
      are applied through their Admin REST endpoints;
    - the file's clients, identity providers and identity provider mappers that
      exist are updated in place, on top of their live representation, so their
      ids, sessions, organization links and brokered users' links stay. A
      client's protocol mappers become the file's. The redirect URIs of the
      KEYCLOAK_CLIENT_ID client stay as they are: the keycloak-redirect-uris
      CronJob owns them;
    - the file's identity providers lose the mappers the file doesn't give them.
      Identity providers the file doesn't have (the console's organizations')
      aren't touched, and nor are clients, identity providers or users that
      were removed from the file: they stay until someone deletes them;
    - the file's service-account users get the roles it gives them.
    Environment: KEYCLOAK_URL, KEYCLOAK_CLIENT_ID and
    KEYCLOAK_REALM_SYNC_CLIENT_SECRET.

With the examples component, bootstrap also takes the configured example realm
names. sync-example REALM RAW_REALM_FILE runs with only that realm's secrets.
It prints no secret value. It runs on Python 3.6.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

REALM = "saas"
SYNC_CLIENT = "keycloak-realm-sync"
SYNC_CLIENT_SECRET_PLACEHOLDER = "${KEYCLOAK_REALM_SYNC_CLIENT_SECRET}"
EXAMPLE_CLIENT = "keycloak-example-realm-sync"
OWNER_ATTRIBUTE = "ai-grid.example-realm-sync"
EXAMPLE_KEYS = {"grid-tenant-1-idp": "GRID_TENANT_1", "grid-tenant-2-idp": "GRID_TENANT_2"}
EXAMPLE_ROLES = ["manage-realm", "manage-users", "manage-clients"]
EXAMPLE_CLIENT_SETTINGS = {
    "protocol": "openid-connect", "clientAuthenticatorType": "client-secret",
    "enabled": True, "publicClient": False, "serviceAccountsEnabled": True,
    "standardFlowEnabled": False, "directAccessGrantsEnabled": False, "implicitFlowEnabled": False,
    "fullScopeAllowed": True,
}
UNIQUE_USER_FLOW = "User creation or linking"
NOT_SETTINGS = {"id", "realm", "keycloakVersion"}
PARTIAL_IMPORT_KEYS = ("clients", "identityProviders", "identityProviderMappers", "users", "groups", "roles")


class Failure(Exception):
    pass


class HTTPFailure(Failure):
    def __init__(self, message, status):
        super().__init__(message)
        self.status = status


def keycloak_url():
    return os.environ["KEYCLOAK_URL"].rstrip("/")


def quote(value):
    return urllib.parse.quote(value, safe="")


def request(method, path, token=None, body=None, form=None):
    headers = {}
    data = None
    if token:
        headers["Authorization"] = "Bearer " + token
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(keycloak_url() + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as err:
        status, raw = err.code, err.read()
    try:
        return status, json.loads(raw.decode()) if raw else None
    except ValueError:
        return status, None


def error_message(data):
    if isinstance(data, dict):
        for key in ("errorMessage", "error_description", "error"):
            if data.get(key):
                return str(data[key])
    return ""


def wait_for_keycloak(timeout=600, realm=REALM):
    deadline = time.time() + timeout
    while True:
        try:
            status, _ = request("GET", "/realms/" + realm)
        except OSError:
            status = None
        if status == 200:
            return
        if time.time() > deadline:
            raise Failure("realm %s isn't served at %s after %ds" % (realm, keycloak_url(), timeout))
        time.sleep(5)


def token(realm, form):
    status, data = request("POST", "/realms/%s/protocol/openid-connect/token" % realm, form=form)
    if status == 200 and data and data.get("access_token"):
        return data["access_token"], status, ""
    return None, status, error_message(data)


def sync_client_token(realm=REALM, client_id=SYNC_CLIENT, secret_key="KEYCLOAK_REALM_SYNC_CLIENT_SECRET"):
    return token(realm, {
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": os.environ[secret_key],
    })


def bootstrap_admin_token():
    access_token, status, message = token("master", {
        "grant_type": "password",
        "client_id": "admin-cli",
        "username": os.environ["KC_BOOTSTRAP_ADMIN_USERNAME"],
        "password": os.environ["KC_BOOTSTRAP_ADMIN_PASSWORD"],
    })
    if not access_token:
        raise Failure("the bootstrap admin can't sign in: HTTP %s %s" % (status, message))
    return access_token


class Admin:
    """One realm's Admin REST API with one access token."""

    def __init__(self, access_token, realm=REALM):
        self.access_token = access_token
        self.realm = realm

    def call(self, method, path, body=None):
        status, data = request(method, "/admin/realms/%s%s" % (self.realm, path), token=self.access_token, body=body)
        if status not in (200, 201, 204):
            # Import errors can echo fields from a fixture containing initial credentials.
            detail = error_message(data) if self.realm == REALM else ""
            raise HTTPFailure("%s /admin/realms/%s%s: HTTP %d %s" % (method, self.realm, path, status, detail),
                              status)
        return data

    def client(self, client_id, required=True):
        found = [c for c in self.call("GET", "/clients?clientId=" + quote(client_id)) if c["clientId"] == client_id]
        if not found:
            if not required:
                return None
            raise Failure("client %s not found" % client_id)
        return found[0]


def apply_settings(admin, realm):
    settings = {key: value for key, value in realm.items()
                if key not in NOT_SETTINGS and not isinstance(value, (dict, list))}
    admin.call("PUT", "", settings)
    print("realm settings applied: %s" % ", ".join(sorted(settings)))


def add_missing(admin, realm):
    body = {key: realm[key] for key in PARTIAL_IMPORT_KEYS if key in realm}
    body["ifResourceExists"] = "SKIP"
    result = admin.call("POST", "/partialImport", body)
    added = sorted("%s %s" % (r["resourceType"].lower(), r["resourceName"])
                   for r in result.get("results", []) if r.get("action") == "ADDED")
    print("added: %s" % (", ".join(added) or "nothing"))


def flow_executions(admin, alias):
    path = "/authentication/flows/%s/executions" % quote(alias)
    return [execution for execution in admin.call("GET", path) if execution.get("level", 0) == 0]


def require_unique_broker_users(admin):
    path = "/authentication/flows/%s/executions" % quote(UNIQUE_USER_FLOW)
    executions = [step for step in flow_executions(admin, UNIQUE_USER_FLOW)
                  if step.get("providerId") == "idp-create-user-if-unique"]
    if len(executions) != 1:
        raise Failure("user creation sub-flow must have one idp-create-user-if-unique step")
    execution = executions[0]
    if execution.get("requirement") == "REQUIRED":
        print("broker user creation is required")
        return
    execution = dict(execution)
    execution["requirement"] = "REQUIRED"
    admin.call("PUT", path, execution)
    print("broker user creation set to REQUIRED")


def user_profile_configuration(realm):
    components = realm.get("components", {}).get("org.keycloak.userprofile.UserProfileProvider", [])
    providers = [component for component in components if component.get("providerId") == "declarative-user-profile"]
    if len(providers) != 1:
        raise Failure("realm file must have one declarative user-profile provider")
    values = providers[0].get("config", {}).get("kc.user.profile.config", [])
    if len(values) != 1:
        raise Failure("realm file has no single kc.user.profile.config value")
    try:
        return json.loads(values[0])
    except ValueError:
        raise Failure("realm file has invalid kc.user.profile.config JSON")


def update_user_profile(admin, realm):
    wanted = user_profile_configuration(realm)
    current = admin.call("GET", "/users/profile")
    if current == wanted:
        print("user profile configuration in place")
        return
    admin.call("PUT", "/users/profile", wanted)
    print("user profile configuration updated")


PROFILE_USERNAME_MAPPER_TYPE = "oidc-usermodel-attribute-mapper"


def update_profile_username_mapper(admin):
    scopes = [scope for scope in admin.call("GET", "/client-scopes") if scope.get("name") == "profile"]
    if len(scopes) != 1:
        raise Failure("built-in profile client scope not found")
    scope_id = scopes[0]["id"]
    path = "/client-scopes/%s/protocol-mappers/models" % scope_id
    mappers = admin.call("GET", path)
    matches = [mapper for mapper in mappers
               if mapper.get("name") == "username" and
               (mapper.get("config") or {}).get("claim.name") == "preferred_username"]
    if len(matches) != 1:
        raise Failure("profile client scope must have one preferred_username mapper named username")
    mapper = dict(matches[0])
    config = dict(mapper.get("config") or {})
    # The built-in mapper is an oidc-usermodel-property-mapper, which reads only
    # the user's built-in properties: pointed at a custom attribute, it emits no
    # preferred_username at all. The attribute mapper reads user attributes.
    if (mapper.get("protocolMapper") == PROFILE_USERNAME_MAPPER_TYPE and
            config.get("user.attribute") == "maas_preferred_username"):
        print("profile username mapper in place")
        return
    mapper["protocolMapper"] = PROFILE_USERNAME_MAPPER_TYPE
    config["user.attribute"] = "maas_preferred_username"
    mapper["config"] = config
    admin.call("PUT", "%s/%s" % (path, mapper["id"]), mapper)
    print("profile username mapper updated")


def update_clients(admin, realm, redirect_uris_owned_elsewhere=None):
    scope_ids = None
    for wanted in realm.get("clients", []):
        live = admin.client(wanted["clientId"])
        merged = dict(live)
        merged.update(wanted)
        merged["id"] = live["id"]
        if wanted["clientId"] == redirect_uris_owned_elsewhere:
            merged["redirectUris"] = live.get("redirectUris", [])
        admin.call("PUT", "/clients/" + live["id"], merged)
        # A client update ignores the client's scopes; add the ones it lacks.
        for kind in ("default", "optional"):
            path = "/clients/%s/%s-client-scopes" % (live["id"], kind)
            have = {scope["name"] for scope in admin.call("GET", path)}
            for name in wanted.get(kind + "ClientScopes", []):
                if name in have:
                    continue
                if scope_ids is None:
                    scope_ids = {scope["name"]: scope["id"] for scope in admin.call("GET", "/client-scopes")}
                if name not in scope_ids:
                    raise Failure("client %s: client scope %s not found" % (wanted["clientId"], name))
                admin.call("PUT", "%s/%s" % (path, scope_ids[name]))
        print("client %s updated" % wanted["clientId"])


def update_identity_providers(admin, realm):
    for wanted in realm.get("identityProviders", []):
        path = "/identity-provider/instances/" + quote(wanted["alias"])
        live = admin.call("GET", path)
        merged = dict(live)
        merged.update(wanted)
        merged["config"] = dict(live.get("config") or {})
        merged["config"].update(wanted.get("config") or {})
        admin.call("PUT", path, merged)
        print("identity provider %s updated" % wanted["alias"])


def update_identity_provider_mappers(admin, realm):
    for wanted in realm.get("identityProviderMappers", []):
        path = "/identity-provider/instances/%s/mappers" % quote(wanted["identityProviderAlias"])
        found = [m for m in admin.call("GET", path) if m["name"] == wanted["name"]]
        if not found:
            raise Failure("identity provider mapper %s not found" % wanted["name"])
        merged = dict(found[0])
        merged.update(wanted)
        merged["id"] = found[0]["id"]
        admin.call("PUT", "%s/%s" % (path, merged["id"]), merged)
        print("identity provider mapper %s updated" % wanted["name"])


def delete_dropped_identity_provider_mappers(admin, realm):
    """Deletes the mappers of the file's identity providers that the file doesn't have."""
    for provider in realm.get("identityProviders", []):
        alias = provider["alias"]
        wanted = {m["name"] for m in realm.get("identityProviderMappers", []) if m["identityProviderAlias"] == alias}
        path = "/identity-provider/instances/%s/mappers" % quote(alias)
        for live in admin.call("GET", path):
            if live["name"] not in wanted:
                admin.call("DELETE", "%s/%s" % (path, live["id"]))
                print("identity provider mapper %s deleted: the file no longer has it" % live["name"])


def role_mappings(admin, user):
    """The service account of user, and (roles path, mapping path, wanted role names) for each of its role sets."""
    account = admin.call("GET", "/clients/%s/service-account-user" % admin.client(user["serviceAccountClientId"])["id"])
    mappings = []
    if user.get("realmRoles"):
        mappings.append(("/roles/", "/users/%s/role-mappings/realm" % account["id"], user["realmRoles"]))
    for role_client_id, names in sorted((user.get("clientRoles") or {}).items()):
        role_client = admin.client(role_client_id)["id"]
        mappings.append(("/clients/%s/roles/" % role_client,
                         "/users/%s/role-mappings/clients/%s" % (account["id"], role_client), names))
    return mappings


def grant_service_account_roles(admin, realm):
    for user in realm.get("users", []):
        if not user.get("serviceAccountClientId"):
            continue
        granted = []
        for roles_path, mapping_path, names in role_mappings(admin, user):
            have = {role["name"] for role in admin.call("GET", mapping_path)}
            missing = [admin.call("GET", roles_path + quote(name)) for name in names if name not in have]
            if missing:
                admin.call("POST", mapping_path, missing)
                granted += [role["name"] for role in missing]
        print("service account %s: %s" % (user["username"], ("granted " + ", ".join(granted)) if granted else "roles in place"))


def sync_client_definition(raw_realm):
    """The keycloak-realm-sync client and service account from the unrendered realm file, with the client's secret."""
    clients = [c for c in raw_realm.get("clients", []) if c.get("clientId") == SYNC_CLIENT]
    users = [u for u in raw_realm.get("users", []) if u.get("serviceAccountClientId") == SYNC_CLIENT]
    if len(clients) != 1 or len(users) != 1:
        raise Failure("the realm file has no single %s client and service account" % SYNC_CLIENT)
    client = dict(clients[0])
    if client.get("secret") != SYNC_CLIENT_SECRET_PLACEHOLDER:
        raise Failure("client %s's secret in the realm file isn't %s" % (SYNC_CLIENT, SYNC_CLIENT_SECRET_PLACEHOLDER))
    client["secret"] = os.environ["KEYCLOAK_REALM_SYNC_CLIENT_SECRET"]
    if "${" in json.dumps(users[0]) or "${" in json.dumps(dict(clients[0], secret="")):
        raise Failure("the %s client or service account holds a placeholder other than its secret" % SYNC_CLIENT)
    return {"clients": [client], "users": users}


def sync_client_problem(user, realm=REALM, secret_key="KEYCLOAK_REALM_SYNC_CLIENT_SECRET"):
    """Check a fresh client login and its effective realm-local role mappings."""
    client_id = user["serviceAccountClientId"]
    access_token, status, message = sync_client_token(realm, client_id, secret_key)
    if not access_token:
        detail = " %s" % message if realm == REALM else ""
        if status in (400, 401):
            return "%s can't sign in (HTTP %s%s)" % (client_id, status, detail)
        raise Failure("%s can't sign in: HTTP %s%s" % (client_id, status, detail))
    admin = Admin(access_token, realm)
    try:
        if client_id == EXAMPLE_CLIENT:
            client = owned_example_client(admin)
            if client is None or any(client.get(k) != v for k, v in EXAMPLE_CLIENT_SETTINGS.items()):
                return "example sync client settings need repair"
        missing = []
        for _, mapping_path, names in role_mappings(admin, user):
            have = {role["name"] for role in admin.call("GET", mapping_path + "/composite")}
            missing += [name for name in names if name not in have]
    except HTTPFailure as err:
        if err.status != 403:
            raise
        return "%s signs in but may not read its own roles" % client_id
    if missing:
        return "%s signs in but lacks %s" % (client_id, ", ".join(sorted(missing)))
    return None


def bootstrap(path):
    with open(path) as stream:
        raw_realm = json.load(stream)
    if raw_realm.get("realm") != REALM:
        raise Failure("%s is not the %s realm" % (path, REALM))
    definition = sync_client_definition(raw_realm)
    wait_for_keycloak()
    problem = sync_client_problem(definition["users"][0])
    if problem is None:
        print("%s signs in and holds its roles; nothing to do" % SYNC_CLIENT)
        return
    print("%s; creating or repairing it as the bootstrap admin" % problem)
    admin = Admin(bootstrap_admin_token())
    add_missing(admin, definition)
    update_clients(admin, definition)
    grant_service_account_roles(admin, definition)
    problem = sync_client_problem(definition["users"][0])
    if problem is not None:
        raise Failure(problem)
    print("%s signs in and holds its roles" % SYNC_CLIENT)


def sync(path):
    with open(path) as stream:
        realm = json.load(stream)
    if realm.get("realm") != REALM:
        raise Failure("%s is not the %s realm" % (path, REALM))
    wait_for_keycloak()
    access_token, status, message = sync_client_token()
    if not access_token:
        raise Failure("%s can't sign in: HTTP %s %s; the keycloak-realm-sync-bootstrap hook creates or repairs it"
                      % (SYNC_CLIENT, status, message))
    admin = Admin(access_token)
    apply_settings(admin, realm)
    require_unique_broker_users(admin)
    add_missing(admin, realm)
    update_user_profile(admin, realm)
    update_profile_username_mapper(admin)
    # The keycloak-redirect-uris CronJob sets this client's redirect URIs.
    update_clients(admin, realm, redirect_uris_owned_elsewhere=os.environ["KEYCLOAK_CLIENT_ID"])
    update_identity_providers(admin, realm)
    update_identity_provider_mappers(admin, realm)
    delete_dropped_identity_provider_mappers(admin, realm)
    grant_service_account_roles(admin, realm)
    print("realm %s: the file's resources are applied" % REALM)


def example_file(realm, path):
    if realm not in EXAMPLE_KEYS:
        raise Failure("unconfigured example realm")
    with open(path) as stream:
        fixture = json.load(stream)
    if fixture.get("realm") != realm:
        raise Failure("fixture does not match example realm %s" % realm)
    return fixture


def owned_example_client(admin):
    client = admin.client(EXAMPLE_CLIENT, required=False)
    if client is None:
        return None
    live = admin.call("GET", "/clients/" + client["id"])
    if (live.get("attributes") or {}).get(OWNER_ATTRIBUTE) != "true":
        raise Failure("%s: reserved sync client is already in use" % admin.realm)
    return live


def bootstrap_example(realm):
    secret_key = EXAMPLE_KEYS[realm] + "_SYNC_CLIENT_SECRET"
    account = {"username": "service-account-" + EXAMPLE_CLIENT, "serviceAccountClientId": EXAMPLE_CLIENT,
               "clientRoles": {"realm-management": EXAMPLE_ROLES}}
    wait_for_keycloak(realm=realm)
    if sync_client_problem(account, realm, secret_key) is None:
        return
    admin = Admin(bootstrap_admin_token(), realm)
    live = owned_example_client(admin)
    wanted = dict(live or {}, **EXAMPLE_CLIENT_SETTINGS)
    attributes = dict(wanted.get("attributes") or {})
    attributes[OWNER_ATTRIBUTE] = "true"
    wanted.update(clientId=EXAMPLE_CLIENT, attributes=attributes, secret=os.environ[secret_key])
    if live is None:
        admin.call("POST", "/clients", wanted)
    else:
        admin.call("PUT", "/clients/" + live["id"], wanted)
    grant_service_account_roles(admin, {"users": [account]})
    problem = sync_client_problem(account, realm, secret_key)
    if problem:
        raise Failure("%s: %s" % (realm, problem))
    print("%s: example sync client ready" % realm)


def get_if_present(admin, path):
    try:
        return admin.call("GET", path)
    except HTTPFailure as err:
        if err.status != 404:
            raise
        return None


def fixture_user(admin, user):
    username = user["username"]
    try:
        if str(uuid.UUID(user["id"])) != user["id"]:
            raise ValueError()
    except (KeyError, ValueError):
        raise Failure("%s: %s needs a fixed UUID" % (admin.realm, username))
    live = get_if_present(admin, "/users/" + user["id"])
    if live is not None:
        if live["username"] != username or live["id"] != user["id"]:
            raise Failure("%s: fixture identity mismatch for %s" % (admin.realm, username))
        return live
    for field in ("username", "email"):
        if user.get(field) and admin.call("GET", "/users?exact=true&%s=%s" % (field, quote(user[field]))):
            raise Failure("%s: %s conflicts with an existing %s" % (admin.realm, username, field))
    return None


def ensure_fixture_groups(admin, groups):
    ids = {}
    for group in groups:
        name = group["name"]
        if not name or "/" in name or group.get("subGroups"):
            raise Failure("example groups must be named top-level groups")
        path = "/" + name
        endpoint = "/group-by-path/" + quote(name)
        live = get_if_present(admin, endpoint)
        if live is None:
            admin.call("POST", "/groups", {"name": name})
            live = admin.call("GET", endpoint)
        if live["path"] != path:
            raise Failure("%s: unexpected group path for %s" % (admin.realm, name))
        ids[path] = live["id"]
    return ids


def create_fixture_user(admin, user):
    password_key = EXAMPLE_KEYS[admin.realm] + "_TEST_USER_PASSWORD"
    credentials = []
    for credential in user["credentials"]:
        if credential["type"] != "password" or credential["value"] != "${%s}" % password_key:
            raise Failure("%s: unexpected credential for %s" % (admin.realm, user["username"]))
        credentials.append(dict(credential, value=os.environ[password_key]))
    role_mappings_to_check = []
    for client_id, names in user.get("clientRoles", {}).items():
        client_uuid = admin.client(client_id)["id"]
        for name in names:
            admin.call("GET", "/clients/%s/roles/%s" % (client_uuid, quote(name)))
        role_mappings_to_check.append((client_uuid, names))
    add_missing(admin, {"users": [dict(user, credentials=credentials)]})
    if fixture_user(admin, user) is None:
        raise Failure("%s: import did not create %s with its fixture ID" % (admin.realm, user["username"]))
    for client_uuid, names in role_mappings_to_check:
        mappings = admin.call("GET", "/users/%s/role-mappings/clients/%s" % (user["id"], client_uuid))
        if not set(names) <= {role["name"] for role in mappings}:
            raise Failure("%s: imported user %s lacks declared roles" % (admin.realm, user["username"]))


def ensure_default_scopes(admin, broker, names):
    path = "/clients/" + broker["id"]
    defaults = path + "/default-client-scopes"
    missing = set(names) - {s["name"] for s in admin.call("GET", defaults)}
    if not missing:
        return
    scopes = {s["name"]: s["id"] for s in admin.call("GET", "/client-scopes")}
    if not missing <= scopes.keys():
        raise Failure("%s: missing realm scopes %s" % (admin.realm, sorted(missing - scopes.keys())))
    optional = {s["name"] for s in admin.call("GET", path + "/optional-client-scopes")}
    for name in sorted(missing):
        # Keycloak ignores the default PUT if the same optional link still exists.
        if name in optional:
            admin.call("DELETE", path + "/optional-client-scopes/" + scopes[name])
        admin.call("PUT", defaults + "/" + scopes[name])
    if not set(names) <= {s["name"] for s in admin.call("GET", defaults)}:
        raise Failure("%s: broker default scopes did not converge" % admin.realm)


def sync_example(realm, fixture):
    wait_for_keycloak(realm=realm)
    access_token, status, _ = sync_client_token(realm, EXAMPLE_CLIENT, EXAMPLE_KEYS[realm] + "_SYNC_CLIENT_SECRET")
    if not access_token:
        raise Failure("%s: sync client login returned HTTP %s" % (realm, status))
    admin = Admin(access_token, realm)
    broker = admin.client("saas-broker")
    desired = [c for c in fixture["clients"] if c["clientId"] == "saas-broker"]
    if len(desired) != 1:
        raise Failure("%s: fixture must contain one saas-broker client" % realm)
    # Validate every identity before granting any access; passwords are create-only.
    missing = [user for user in fixture["users"] if fixture_user(admin, user) is None]
    groups = ensure_fixture_groups(admin, fixture["groups"])
    for user in fixture["users"]:
        if set(user.get("groups", [])) - groups.keys():
            raise Failure("%s: undeclared group for %s" % (realm, user["username"]))
    for user in missing:
        create_fixture_user(admin, user)
    for user in fixture["users"]:
        for path in user.get("groups", []):
            # Keycloak's join is idempotent and preserves all other memberships.
            admin.call("PUT", "/users/%s/groups/%s" % (user["id"], groups[path]))
    ensure_default_scopes(admin, broker, desired[0].get("defaultClientScopes", []))
    print("%s: fixture users, memberships and broker scopes reconciled" % realm)


def main(argv):
    if len(argv) >= 3 and argv[1] == "bootstrap":
        for realm in argv[3:]:
            example_file(realm, os.path.join(os.path.dirname(argv[2]), realm + "-realm.json"))
        bootstrap(argv[2])
        for realm in argv[3:]:
            bootstrap_example(realm)
    elif len(argv) == 3 and argv[1] == "sync":
        sync(argv[2])
    elif len(argv) == 4 and argv[1] == "sync-example":
        sync_example(argv[2], example_file(argv[2], argv[3]))
    else:
        raise Failure("usage: bootstrap REALM_FILE [EXAMPLE_REALM ...] | sync RENDERED_REALM_FILE | "
                      "sync-example EXAMPLE_REALM RAW_REALM_FILE")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Failure as err:
        print("error: %s" % err, file=sys.stderr)
        sys.exit(1)
