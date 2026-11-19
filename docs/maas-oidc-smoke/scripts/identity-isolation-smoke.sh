#!/usr/bin/env bash
# Compares two company identities that both use the external username alice.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SCRIPT="$SCRIPT_DIR/maas-oidc-smoke.sh"

: "${IDP_A:?IDP_A is required}"
: "${IDP_B:?IDP_B is required}"
: "${ORG_A:?ORG_A is required}"
: "${ORG_B:?ORG_B is required}"
: "${PASSWORD_SECRET_KEY_A:?PASSWORD_SECRET_KEY_A is required}"
: "${PASSWORD_SECRET_KEY_B:?PASSWORD_SECRET_KEY_B is required}"

fail() {
  printf 'identity-isolation-smoke.sh: %s\n' "$*" >&2
  exit 1
}

run_login() {
  local idp=$1
  local password_key=$2
  local result_file=$3

  BROKER_HINT="$idp" \
    PASSWORD_SECRET_KEY="$password_key" \
    IDENTITY_ONLY=1 \
    IDENTITY_RESULT_FILE="$result_file" \
    "$MAIN_SCRIPT" alice
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

result_a_1="$tmpdir/a-1.json"
result_b_1="$tmpdir/b-1.json"
result_a_2="$tmpdir/a-2.json"
result_b_2="$tmpdir/b-2.json"

run_login "$IDP_A" "$PASSWORD_SECRET_KEY_A" "$result_a_1"
run_login "$IDP_B" "$PASSWORD_SECRET_KEY_B" "$result_b_1"
run_login "$IDP_A" "$PASSWORD_SECRET_KEY_A" "$result_a_2"
run_login "$IDP_B" "$PASSWORD_SECRET_KEY_B" "$result_b_2"

subject_a_1=$(jq -r '.subject' "$result_a_1")
subject_b_1=$(jq -r '.subject' "$result_b_1")
subject_a_2=$(jq -r '.subject' "$result_a_2")
subject_b_2=$(jq -r '.subject' "$result_b_2")

[[ -n "$subject_a_1" ]] || fail "provider A returned no subject"
[[ -n "$subject_b_1" ]] || fail "provider B returned no subject"
[[ "$subject_a_1" != "$subject_b_1" ]] || fail "the two companies resolved to one subject"
[[ "$subject_a_1" == "$subject_a_2" ]] || fail "provider A changed subject on repeat"
[[ "$subject_b_1" == "$subject_b_2" ]] || fail "provider B changed subject on repeat"

for result_file in "$result_a_1" "$result_b_1"; do
  jq -e '.profile.preferred_username == "alice"' "$result_file" >/dev/null ||
    fail "$result_file did not preserve preferred_username=alice"
done

jq -e --arg organization "$ORG_A" '(.organizations | length > 0) and all(.organizations[]?; .organization_id == $organization)' "$result_a_1" >/dev/null ||
  fail "provider A returned an unexpected organization"
jq -e --arg organization "$ORG_B" '(.organizations | length > 0) and all(.organizations[]?; .organization_id == $organization)' "$result_b_1" >/dev/null ||
  fail "provider B returned an unexpected organization"
jq -e --arg organization "$ORG_A" '(.subscriptions | length > 0) and all(.subscriptions[]?; .organization_id == $organization)' "$result_a_1" >/dev/null ||
  fail "provider A returned an unexpected subscription organization"
jq -e --arg organization "$ORG_B" '(.subscriptions | length > 0) and all(.subscriptions[]?; .organization_id == $organization)' "$result_b_1" >/dev/null ||
  fail "provider B returned an unexpected subscription organization"

printf 'identity isolation: passed\n'
printf '  provider A subject: %s\n' "$subject_a_1"
printf '  provider B subject: %s\n' "$subject_b_1"
