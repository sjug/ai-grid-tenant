#!/usr/bin/env bash
# Renders a realm import file from stdin to stdout, replacing each ${NAME}
# placeholder below with the environment variable NAME. A placeholder the file
# holds needs its variable set; one it doesn't hold needs nothing, so a caller
# passes only the values its file uses. The Keycloak Deployment's
# render-realm-import init container and the keycloak-saas-realm-sync hook both
# use it, so they render the same realm.
set -Eeuo pipefail

placeholders=(
  KEYCLOAK_CLIENT_ID
  KEYCLOAK_HOME_URL
  KEYCLOAK_PUBLIC_URL
  KEYCLOAK_REDIRECT_URI
  KEYCLOAK_CLIENT_SECRET
  KEYCLOAK_REDIRECT_URIS_CLIENT_SECRET
  KEYCLOAK_REALM_SYNC_CLIENT_SECRET
  GRID_TENANT_1_BROKER_CLIENT_SECRET
  GRID_TENANT_2_BROKER_CLIENT_SECRET
  GRID_TENANT_1_TEST_USER_PASSWORD
  GRID_TENANT_2_TEST_USER_PASSWORD
  KEYCLOAK_SIGNING_KEYSTORE_PASSWORD
)

while IFS= read -r line || [[ -n "$line" ]]; do
  for name in "${placeholders[@]}"; do
    placeholder="\${$name}"
    [[ "$line" == *"$placeholder"* ]] || continue
    if [[ -z "${!name+set}" ]]; then
      echo "render-realm.sh: the file holds $placeholder, but $name is not set" >&2
      exit 1
    fi
    line=${line//"$placeholder"/"${!name}"}
  done
  printf '%s\n' "$line"
done
