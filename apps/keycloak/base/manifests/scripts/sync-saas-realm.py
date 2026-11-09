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

It prints no secret value. It runs on Python 3.6.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REALM = "saas"
SYNC_CLIENT = "keycloak-realm-sync"
SYNC_CLIENT_SECRET_PLACEHOLDER = "${KEYCLOAK_REALM_SYNC_CLIENT_SECRET}"
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


def wait_for_keycloak(timeout=600):
    deadline = time.time() + timeout
    while True:
        try:
            status, _ = request("GET", "/realms/" + REALM)
        except OSError:
            status = None
        if status == 200:
            return
        if time.time() > deadline:
            raise Failure("realm %s isn't served at %s after %ds" % (REALM, keycloak_url(), timeout))
        time.sleep(5)


def token(realm, form):
    status, data = request("POST", "/realms/%s/protocol/openid-connect/token" % realm, form=form)
    if status == 200 and data and data.get("access_token"):
        return data["access_token"], status, ""
    return None, status, error_message(data)


def sync_client_token():
    return token(REALM, {
        "grant_type": "client_credentials",
        "client_id": SYNC_CLIENT,
        "client_secret": os.environ["KEYCLOAK_REALM_SYNC_CLIENT_SECRET"],
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
    """The saas realm's Admin REST API with one access token."""

    def __init__(self, access_token):
        self.access_token = access_token

    def call(self, method, path, body=None):
        status, data = request(method, "/admin/realms/%s%s" % (REALM, path), token=self.access_token, body=body)
        if status not in (200, 201, 204):
            raise HTTPFailure("%s /admin/realms/%s%s: HTTP %d %s" % (method, REALM, path, status, error_message(data)),
                              status)
        return data

    def client(self, client_id):
        found = [c for c in self.call("GET", "/clients?clientId=" + quote(client_id)) if c["clientId"] == client_id]
        if not found:
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


def sync_client_problem(user):
    """None when keycloak-realm-sync signs in and its service account holds the roles user gives it; else why not."""
    access_token, status, message = sync_client_token()
    if not access_token:
        if status in (400, 401):
            return "%s can't sign in (HTTP %s %s)" % (SYNC_CLIENT, status, message)
        raise Failure("%s can't sign in: HTTP %s %s" % (SYNC_CLIENT, status, message))
    admin = Admin(access_token)
    try:
        missing = []
        for _, mapping_path, names in role_mappings(admin, user):
            have = {role["name"] for role in admin.call("GET", mapping_path + "/composite")}
            missing += [name for name in names if name not in have]
    except HTTPFailure as err:
        if err.status != 403:
            raise
        return "%s signs in but may not read its own roles" % SYNC_CLIENT
    if missing:
        return "%s signs in but lacks %s" % (SYNC_CLIENT, ", ".join(sorted(missing)))
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
    add_missing(admin, realm)
    # The keycloak-redirect-uris CronJob sets this client's redirect URIs.
    update_clients(admin, realm, redirect_uris_owned_elsewhere=os.environ["KEYCLOAK_CLIENT_ID"])
    update_identity_providers(admin, realm)
    update_identity_provider_mappers(admin, realm)
    delete_dropped_identity_provider_mappers(admin, realm)
    grant_service_account_roles(admin, realm)
    print("realm %s: the file's resources are applied" % REALM)


def main(argv):
    commands = {"bootstrap": bootstrap, "sync": sync}
    if len(argv) != 3 or argv[1] not in commands:
        raise Failure("usage: sync-saas-realm.py bootstrap REALM_FILE | sync RENDERED_REALM_FILE")
    commands[argv[1]](argv[2])


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Failure as err:
        print("error: %s" % err, file=sys.stderr)
        sys.exit(1)
