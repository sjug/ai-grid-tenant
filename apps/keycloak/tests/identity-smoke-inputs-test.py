#!/usr/bin/env python3
"""Check the identity smoke-test inputs without contacting a cluster."""

import os
import re
import unittest


ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../.."))
MAIN_SCRIPT = os.path.join(ROOT, "docs/maas-oidc-smoke/scripts/maas-oidc-smoke.sh")
WRAPPER_SCRIPT = os.path.join(ROOT, "docs/maas-oidc-smoke/scripts/identity-isolation-smoke.sh")


class IdentitySmokeInputsTest(unittest.TestCase):
    def setUp(self):
        with open(MAIN_SCRIPT) as stream:
            self.main_source = stream.read()
        with open(WRAPPER_SCRIPT) as stream:
            self.wrapper_source = stream.read()

    def test_broker_and_password_overrides_are_independent_of_username(self):
        self.assertRegex(self.main_source, r'broker_hint="\$\{BROKER_HINT:-\$broker_hint\}"')
        self.assertRegex(self.main_source, r'password_key="\$\{PASSWORD_SECRET_KEY:-\$password_key\}"')
        self.assertIn("broker_hint=grid-tenant-1", self.main_source)
        self.assertIn("password_key=GRID_TENANT_1_TEST_USER_PASSWORD", self.main_source)
        self.assertIn("broker_hint=grid-tenant-2", self.main_source)
        self.assertIn("password_key=GRID_TENANT_2_TEST_USER_PASSWORD", self.main_source)

    def test_identity_only_mode_stops_before_mutating_or_expensive_stages(self):
        self.assertIn('identity_only="${IDENTITY_ONLY:-0}"', self.main_source)
        self.assertIn('[[ "$identity_only" == 0 || "$identity_only" == 1 ]]', self.main_source)
        cutoff = self.main_source.index("if [[ \"$identity_only\" == 1 ]]")
        api_key = self.main_source.index("api_key_id=\"\"")
        inference = self.main_source.index("POST /v1/chat/completions")
        rate_limit = self.main_source.index("print_section \"Token rate limit\"")
        self.assertLess(cutoff, api_key)
        self.assertLess(cutoff, inference)
        self.assertLess(cutoff, rate_limit)

    def test_identity_result_file_is_private_and_excludes_credentials(self):
        self.assertIn('identity_result_file="${IDENTITY_RESULT_FILE:-}"', self.main_source)
        self.assertIn("chmod 600 \"$identity_result_file\"", self.main_source)
        result_builder = self.main_source[
            self.main_source.index("organizations_json="):
            self.main_source.index("print_section \"Identity-only result\"")
        ]
        for forbidden in ("access_token", "client_secret", "password", "api_key"):
            self.assertNotIn(forbidden, result_builder)
        for required in ("issuer", "subject", "organization_id", "preferred_username"):
            self.assertIn(required, result_builder)

    def test_wrapper_uses_two_runtime_providers_and_keeps_both_usernames_alice(self):
        for variable in (
            "IDP_A",
            "IDP_B",
            "ORG_A",
            "ORG_B",
            "PASSWORD_SECRET_KEY_A",
            "PASSWORD_SECRET_KEY_B",
        ):
            self.assertIn("${" + variable + ":?", self.wrapper_source)
        self.assertEqual(self.wrapper_source.count('run_login "$IDP_'), 4)
        self.assertIn("BROKER_HINT=\"$idp\"", self.wrapper_source)
        self.assertIn("PASSWORD_SECRET_KEY=\"$password_key\"", self.wrapper_source)
        self.assertIn("IDENTITY_ONLY=1", self.wrapper_source)
        self.assertIn("IDENTITY_RESULT_FILE=\"$result_file\"", self.wrapper_source)

    def test_wrapper_compares_subjects_and_expected_organizations(self):
        self.assertIn("subject_a_1", self.wrapper_source)
        self.assertIn("subject_b_1", self.wrapper_source)
        self.assertIn("subject_a_2", self.wrapper_source)
        self.assertIn("subject_b_2", self.wrapper_source)
        self.assertIn("organization_id", self.wrapper_source)
        self.assertIn("ORG_A", self.wrapper_source)
        self.assertIn("ORG_B", self.wrapper_source)


if __name__ == "__main__":
    unittest.main()
