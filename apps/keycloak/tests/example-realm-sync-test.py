#!/usr/bin/env python3
"""Exercise the hook entry points against a stateful Keycloak Admin API stub."""

import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
from urllib.parse import parse_qs, unquote, urlsplit

APP = Path(__file__).resolve().parents[1]
SCRIPT = APP / "base/manifests/scripts/sync-saas-realm.py"
EXAMPLES = APP / "components/examples"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("sync", str(SCRIPT))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
ONE, TWO = "grid-tenant-1-idp", "grid-tenant-2-idp"
SERVICE = sync.EXAMPLE_CLIENT
BROKER = "saas-broker"
MGMT = "realm-management"


def fixture_path(realm):
    return EXAMPLES / (realm + "-realm.json")


class Realm:
    def __init__(self, name):
        fixture = json.loads(fixture_path(name).read_text())
        self.groups = {"/ai-grid-users": "g-users", "/runtime": "g-runtime"}
        if name == ONE:
            self.groups["/ai-grid-admins"] = "g-admins"
        self.users = {u["id"]: u for u in fixture["users"] if not (name == TWO and u["username"] == "alice")}
        for u in self.users.values():
            u["credentials"] = [{"type": "password", "value": "runtime-password"}]
            u["groups"] = [g for g in u.get("groups", []) if g in self.groups] + ["/runtime"]
        self.users["runtime-id"] = {"id": "runtime-id", "username": "runtime", "groups": ["/runtime"]}
        self.clients = {BROKER: {"clientId": BROKER, "id": "broker-id", "secret": "broker-secret",
                                 "protocolMappers": [{"name": "runtime"}]},
                        MGMT: {"clientId": MGMT, "id": "management-id"}}
        self.grants = set()
        self.defaults = {"extra"}
        self.optional = {"email", "optional-extra"}


class Keycloak:
    def __init__(self):
        self.realms = {realm: Realm(realm) for realm in (ONE, TWO)}
        self.calls = []
        self.fail_once = None

    def request(self, method, path, token=None, body=None, form=None):
        self.calls.append((method, path))
        if self.fail_once == (method, path):
            self.fail_once = None
            return 503, {"error": "unavailable"}
        parts = urlsplit(path)
        fields = [unquote(p) for p in parts.path.strip("/").split("/")]
        if fields[0] == "realms":
            realm = fields[1]
            if method == "GET" and len(fields) == 2 and realm in self.realms:
                return 200, {"realm": realm}
            assert method == "POST" and fields[2:] == ["protocol", "openid-connect", "token"]
            if realm == "master":
                assert form["grant_type"] == "password" and form["client_id"] == "admin-cli"
            else:
                client = self.realms[realm].clients.get(SERVICE, {})
                assert form["grant_type"] == "client_credentials" and form["client_id"] == SERVICE
                if not client.get("serviceAccountsEnabled") or client.get("secret") != form["client_secret"]:
                    return 401, {}
            return 200, {"access_token": realm}
        assert fields[:2] == ["admin", "realms"]
        realm = fields[2]
        assert token in ("master", realm), "cross-realm credential"
        state = self.realms[realm]
        if token != "master" and "manage-clients" not in state.grants:
            return 403, {}
        status, result = self.admin(state, method, fields[3:], parse_qs(parts.query), copy.deepcopy(body))
        return status, copy.deepcopy(result)

    def admin(self, state, method, path, query, body):
        if path == ["clients"]:
            if method == "GET":
                client = state.clients.get(query["clientId"][0])
                return 200, [client] if client else []
            assert method == "POST" and body["clientId"] == SERVICE
            assert SERVICE not in state.clients
            state.clients[SERVICE] = dict(body, id="service-id")
            return 201, None
        if path == ["clients", "service-id"]:
            if method == "GET":
                return 200, state.clients[SERVICE]
            assert method == "PUT"
            state.clients[SERVICE].update(body)
            return 204, None
        if path == ["clients", "service-id", "service-account-user"] and method == "GET":
            return 200, {"id": "service-user"}
        if len(path) == 4 and path[0] == "clients" and path[2] == "roles" and method == "GET":
            return 200, {"id": "r-" + path[3], "name": path[3]}
        if path[:4] == ["users", "service-user", "role-mappings", "clients"]:
            assert path[4] == "management-id"
            if method == "POST":
                state.grants.update(r["name"] for r in body)
                return 204, None
            assert method == "GET"
            return 200, [{"name": n} for n in state.grants]
        if path == ["users"] and method == "GET":
            assert query.pop("exact") == ["true"]
            (key, values), = query.items()
            return 200, [u for u in state.users.values() if u.get(key) == values[0]]
        if len(path) == 2 and path[0] == "users" and method == "GET":
            return (200, state.users[path[1]]) if path[1] in state.users else (404, {})
        if path[0] == "group-by-path" and method == "GET":
            name = "/" + path[1]
            return (200, {"id": state.groups[name], "path": name}) if name in state.groups else (404, {})
        if path == ["groups"] and method == "POST":
            name = body["name"]
            assert "/" + name not in state.groups
            state.groups["/" + name] = "g-" + name
            return 201, None
        if path == ["partialImport"] and method == "POST":
            assert set(body) == {"users", "ifResourceExists"} and body["ifResourceExists"] == "SKIP"
            for u in body["users"]:
                if not any(v["username"] == u["username"] for v in state.users.values()):
                    assert u["id"] not in state.users
                    state.users[u["id"]] = u
            return 200, {"results": []}
        if len(path) == 5 and path[0] == "users" and path[2:4] == ["role-mappings", "clients"]:
            assert method == "GET"
            client, = [c for c in state.clients.values() if c["id"] == path[4]]
            return 200, [{"name": n} for n in state.users[path[1]]["clientRoles"][client["clientId"]]]
        if len(path) == 4 and path[0] == "users" and path[2] == "groups":
            assert method == "PUT"
            group, = [g for g in state.groups if state.groups[g] == path[3]]
            groups = state.users[path[1]].setdefault("groups", [])
            if group not in groups:
                groups.append(group)
            return 204, None
        if path == ["client-scopes"] and method == "GET":
            return 200, [{"id": n + "-id", "name": n} for n in ("email", "profile")]
        if path[:2] == ["clients", "broker-id"] and path[2] in ("default-client-scopes", "optional-client-scopes"):
            collection = state.defaults if path[2] == "default-client-scopes" else state.optional
            if method == "GET":
                return 200, [{"name": n, "id": n + "-id"} for n in collection]
            scope = path[3][:-3]
            if method == "DELETE":
                assert collection is state.optional
                collection.remove(scope)
            else:
                assert method == "PUT" and collection is state.defaults
                if scope not in state.optional:
                    collection.add(scope)
            return 204, None
        raise AssertionError("unexpected Admin request: %s %s" % (method, path))


class ExampleSyncTest(unittest.TestCase):
    def setUp(self):
        self.kc = Keycloak()
        env = {"KC_BOOTSTRAP_ADMIN_USERNAME": "admin", "KC_BOOTSTRAP_ADMIN_PASSWORD": "admin-test",
               "KEYCLOAK_URL": "stub", "KEYCLOAK_CLIENT_ID": "tenant-demo", "KEYCLOAK_REALM_SYNC_CLIENT_SECRET": "saas-test"}
        for realm, prefix in sync.EXAMPLE_KEYS.items():
            env[prefix + "_SYNC_CLIENT_SECRET"] = realm + "-secret"
            env[prefix + "_TEST_USER_PASSWORD"] = realm + "-seed"
        for patch in (mock.patch.dict(os.environ, env), mock.patch.object(sync, "request", self.kc.request),
                      contextlib.redirect_stdout(io.StringIO())):
            patch.__enter__()
            self.addCleanup(patch.__exit__, None, None, None)

    def bootstrap(self, *realms):
        for realm in realms:
            sync.bootstrap_example(realm)

    def run_hook(self, realm):
        sync.main(["hook", "sync-example", realm, str(fixture_path(realm))])

    def test_upgrade_and_repeat(self):
        self.bootstrap(ONE, TWO)
        state = self.kc.realms[TWO]
        bob = next(u for u in state.users.values() if u["username"] == "bob")
        bob["enabled"] = False
        bob["clientRoles"][BROKER] = ["runtime-role"]
        previous = copy.deepcopy(bob)
        runtime = copy.deepcopy(state.users["runtime-id"])
        broker = copy.deepcopy(state.clients[BROKER])
        for realm in (ONE, TWO):
            self.run_hook(realm)
            self.assertEqual(self.kc.realms[realm].defaults, {"extra", "profile", "email"})
        self.assertEqual(state.optional, {"optional-extra"})
        self.assertEqual(bob, dict(previous, groups=previous["groups"] + ["/ai-grid-bob"]))
        self.assertEqual(state.users["runtime-id"], runtime)
        self.assertEqual(state.clients[BROKER], broker)
        alice = next(u for u in json.loads(fixture_path(TWO).read_text())["users"] if u["username"] == "alice")
        self.assertEqual(state.users[alice["id"]], dict(alice, credentials=[dict(alice["credentials"][0], value=TWO + "-seed")]))
        self.assertNotIn(alice["id"], self.kc.realms[ONE].users)
        before = copy.deepcopy(state.__dict__)
        self.kc.calls.clear()
        self.bootstrap(TWO)
        self.run_hook(TWO)
        self.assertEqual(before, state.__dict__)
        self.assertFalse(any("/master/" in path or path.endswith("/partialImport") for _, path in self.kc.calls))

    def test_bootstrap_repairs_only_owned_client(self):
        self.bootstrap(TWO)
        state = self.kc.realms[TWO]
        for failure in ("rotated", "role"):
            if failure == "rotated":
                state.clients[SERVICE]["secret"] = "old"
            else:
                state.grants.remove("manage-users")
            self.kc.calls.clear()
            self.bootstrap(TWO)
            self.assertEqual(state.clients[SERVICE]["secret"], TWO + "-secret")
            self.assertEqual(state.grants, set(sync.EXAMPLE_ROLES))
            self.assertEqual(state.clients[SERVICE]["id"], "service-id")
            master_login = self.kc.calls.index(("POST", "/realms/master/protocol/openid-connect/token"))
            self.assertIn(("POST", "/realms/" + TWO + "/protocol/openid-connect/token"), self.kc.calls[master_login+1:])
        state.clients[SERVICE]["attributes"] = {}
        for secret in (TWO + "-secret", "different"):
            state.clients[SERVICE]["secret"] = secret
            before = copy.deepcopy(state.__dict__)
            with self.assertRaisesRegex(sync.Failure, "reserved"):
                self.bootstrap(TWO)
            self.assertEqual(before, state.__dict__)

    def test_wrong_target_and_collisions(self):
        for realm in ("master", "saas", "unknown", ONE):
            with self.assertRaises(sync.Failure):
                sync.main(["hook", "sync-example", realm, str(fixture_path(TWO))])
        with self.assertRaises(sync.Failure):
            sync.main(["hook", "bootstrap", str(EXAMPLES / "saas-realm.json"), "master"])
        self.assertEqual(self.kc.calls, [])
        self.bootstrap(TWO)
        users = self.kc.realms[TWO].users
        for collision in ({"username": "alice"}, {"email": "alice@grid-tenant-2.test"}):
            users["runtime-id"].update(collision)
            with self.assertRaisesRegex(sync.Failure, "conflicts"):
                self.run_hook(TWO)
            users["runtime-id"] = {"id": "runtime-id", "username": "runtime"}
        next(u for u in users.values() if u["username"] == "bob")["username"] = "changed"
        with self.assertRaisesRegex(sync.Failure, "mismatch"):
            self.run_hook(TWO)
        self.assertNotIn("/ai-grid-bob", self.kc.realms[TWO].groups)

    def test_retry_after_partial_success(self):
        self.bootstrap(TWO)
        state = self.kc.realms[TWO]
        bob = next(u for u in state.users.values() if u["username"] == "bob")
        prefix = "/admin/realms/" + TWO
        self.kc.fail_once = ("PUT", prefix + "/users/" + bob["id"] + "/groups/g-ai-grid-bob")
        with self.assertRaises(sync.HTTPFailure):
            self.run_hook(TWO)
        alice = next(u for u in state.users.values() if u["username"] == "alice")
        alice["credentials"] = ["changed-after-create"]
        self.kc.fail_once = ("PUT", prefix + "/clients/broker-id/default-client-scopes/email-id")
        with self.assertRaises(sync.HTTPFailure):
            self.run_hook(TWO)
        self.assertNotIn("email", state.optional | state.defaults)
        self.run_hook(TWO)
        self.assertIn("email", state.defaults)
        self.assertIn("/ai-grid-bob", bob["groups"])
        self.assertEqual(alice["credentials"], ["changed-after-create"])

    def test_unexpected_bootstrap_error_does_not_use_master(self):
        self.kc.fail_once = ("POST", "/realms/" + TWO + "/protocol/openid-connect/token")
        with self.assertRaisesRegex(sync.Failure, "503"):
            self.bootstrap(TWO)
        self.assertFalse(any("/master/" in path for _, path in self.kc.calls))

    def test_partial_import_skip_is_verified(self):
        self.bootstrap(TWO)
        state = self.kc.realms[TWO]
        original = self.kc.admin

        def concurrent_user(state, method, path, query, body):
            if method == "POST" and path == ["partialImport"]:
                state.users["runtime-id"]["username"] = "alice"
            return original(state, method, path, query, body)

        with mock.patch.object(self.kc, "admin", concurrent_user), self.assertRaisesRegex(sync.Failure, "conflicts"):
            self.run_hook(TWO)
        self.assertEqual(state.users["runtime-id"]["groups"], ["/runtime"])

    def test_saas_request_sequence(self):
        # Exercise the public SaaS command with a small broker fixture and pin its API sequence.
        conf = {"components": {"org.keycloak.userprofile.UserProfileProvider": [
            {"providerId": "declarative-user-profile", "config": {"kc.user.profile.config": ["{}"]}}]}, "realm": "saas"}
        flow = "/authentication/flows/User%20creation%20or%20linking/executions"
        mapper = {"name": "username", "protocolMapper": sync.PROFILE_USERNAME_MAPPER_TYPE,
                  "config": {"claim.name": "preferred_username", "user.attribute": "maas_preferred_username"}}
        expected = [("GET", "/realms/saas", {}), ("POST", "/realms/saas/protocol/openid-connect/token", {"access_token": "saas"})]
        expected.extend((method, "/admin/realms/saas" + path, answer) for method, path, answer in [
            ("PUT", "", {}), ("GET", flow, [{"providerId": "idp-create-user-if-unique", "requirement": "REQUIRED"}]),
            ("POST", "/partialImport", {}), ("GET", "/users/profile", {}), ("GET", "/client-scopes", [{"name": "profile", "id": "p"}]),
            ("GET", "/client-scopes/p/protocol-mappers/models", [mapper])])

        def answer(method, path, **kwargs):
            wanted_method, wanted_path, response = expected.pop(0)
            self.assertEqual((method, path), (wanted_method, wanted_path))
            return 200, response

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(sync, "request", answer):
            path = Path(directory) / "saas-realm.json"
            path.write_text(json.dumps(conf))
            sync.main(["hook", "sync", str(path)])
        self.assertEqual(expected, [])


if __name__ == "__main__":
    unittest.main()
