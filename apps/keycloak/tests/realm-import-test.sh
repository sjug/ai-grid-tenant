#!/usr/bin/env bash
# Renders every Keycloak overlay and checks the realm import contract
# (realm-import-test.py), then runs the rendered init container script: every
# realm goes to the create-only import, and the sync hook renders saas with only
# the values it is given.
# Needs kubectl and PyYAML.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

python3 "$HERE/realm-import-test.py" "$TMP_DIR"

bash -n "$HERE/../base/manifests/scripts/render-realm.sh"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$HERE/../base/manifests/scripts/sync-saas-realm.py"
for overlay in core default direct; do
  bash -n "$TMP_DIR/$overlay/init.sh"
  bash -n "$TMP_DIR/$overlay/start.sh"
done
bash -n "$TMP_DIR/core/job.sh"
bash -n "$TMP_DIR/default/job.sh"

all_placeholders=(
  KEYCLOAK_CLIENT_ID KEYCLOAK_HOME_URL KEYCLOAK_PUBLIC_URL KEYCLOAK_REDIRECT_URI
  KEYCLOAK_CLIENT_SECRET KEYCLOAK_REDIRECT_URIS_CLIENT_SECRET KEYCLOAK_REALM_SYNC_CLIENT_SECRET
  GRID_TENANT_1_BROKER_CLIENT_SECRET GRID_TENANT_2_BROKER_CLIENT_SECRET
  GRID_TENANT_1_TEST_USER_PASSWORD GRID_TENANT_2_TEST_USER_PASSWORD KEYCLOAK_SIGNING_KEYSTORE_PASSWORD
)

check_rendered() {
  local file
  for file in "$@"; do
    python3 -m json.tool "$file" >/dev/null
    if grep -q '\${[A-Z0-9_]*}' "$file"; then
      echo "unrendered placeholder in $file" >&2
      exit 1
    fi
  done
}

# The init container, with every value it gets from the Deployment.
for overlay in core default; do
  (
    for name in "${all_placeholders[@]}"; do
      export "$name=test-$name"
    done
    bash "$TMP_DIR/$overlay/init.sh"
  )
  import_dir=$TMP_DIR/$overlay/opt/keycloak/data/import
  [[ "$(ls -A "$import_dir")" == "create-only" ]]
  check_rendered "$import_dir"/create-only/*.json
  grep -q '"secret": "test-KEYCLOAK_REALM_SYNC_CLIENT_SECRET"' "$import_dir/create-only/saas-realm.json"
done
[[ "$(cd "$TMP_DIR/core/opt/keycloak/data/import/create-only" && ls | tr '\n' ' ')" == "saas-realm.json " ]]
[[ "$(cd "$TMP_DIR/default/opt/keycloak/data/import/create-only" && ls | tr '\n' ' ')" == \
  "grid-tenant-1-idp-realm.json grid-tenant-2-idp-realm.json saas-realm.json " ]]

# The sync hook's render, with only the values its Job gets: it renders saas,
# and fails when one of them is missing.
render_with() {
  local overlay=$1 skip=${2:-} name
  local -a values=()
  while IFS= read -r name; do
    [[ "$name" == "$skip" ]] || values+=("$name=test-$name")
  done < "$TMP_DIR/$overlay/sync-env"
  env -i PATH="$PATH" "${values[@]}" bash "$HERE/../base/manifests/scripts/render-realm.sh" \
    < "$TMP_DIR/$overlay/opt/keycloak/realm-import-source/saas-realm.json"
}
for overlay in core default; do
  render_with "$overlay" > "$TMP_DIR/$overlay/sync-rendered.json"
  check_rendered "$TMP_DIR/$overlay/sync-rendered.json"
  cmp -s "$TMP_DIR/$overlay/sync-rendered.json" "$TMP_DIR/$overlay/opt/keycloak/data/import/create-only/saas-realm.json"
  while IFS= read -r name; do
    if render_with "$overlay" "$name" >/dev/null 2>"$TMP_DIR/render.err"; then
      echo "render-realm.sh rendered $overlay's saas realm without $name" >&2
      exit 1
    fi
    grep -q "\${$name}" "$TMP_DIR/render.err"
  done < "$TMP_DIR/$overlay/sync-env"
done

echo "keycloak realm import tests: 1 ok, 0 failed"
