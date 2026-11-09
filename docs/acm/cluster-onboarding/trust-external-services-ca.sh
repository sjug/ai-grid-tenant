#!/usr/bin/env bash
# Adds the CA that issued the external-services cluster's Keycloak Route certificate to this site's cluster trust, so
# Authorino (the RHOAI AI Grid profiles) can reach the home for OpenID discovery. Run with KUBECONFIG at the site.
#
#   HOME_KUBECONFIG=<home kubeconfig> KEYCLOAK_HOST=<home Keycloak Route host> REALM=<MaaS realm> \
#     docs/acm/cluster-onboarding/trust-external-services-ca.sh
#
# HOME_CA_FILE=<PEM of the issuer> replaces HOME_KUBECONFIG for a home with a replaced ingress certificate.
# Optional: AUTHORINO_NAMESPACE (kuadrant-system), TIMEOUT_SECONDS (900), POLL_SECONDS (20), WORKDIR.
# Stops at the first failure and writes nothing before every read has succeeded; merges the CA into the
# proxy trust bundle, waits (by fingerprint) until it is mounted, then verifies TLS to the home's discovery
# document with exactly that bundle.
set -euo pipefail
: "${KEYCLOAK_HOST:?set KEYCLOAK_HOST to the Keycloak Route host of the external-services cluster}"
: "${REALM:?set REALM to the MaaS realm}"
AUTHORINO_NAMESPACE=${AUTHORINO_NAMESPACE:-kuadrant-system}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-900}
POLL_SECONDS=${POLL_SECONDS:-20}
WORKDIR=${WORKDIR:-$(mktemp -d)}; mkdir -p "$WORKDIR"
oc() { command oc --request-timeout=30s "$@"; }
die() { echo "trust-external-services-ca: $*" >&2; exit 1; }

certs_ok() { # <file>: non-empty and parses as one or more PEM certificates
  [ -s "$1" ] || return 1
  [ "$(grep -c -- '-----BEGIN CERTIFICATE-----' "$1")" -gt 0 ] || return 1
  openssl crl2pkcs7 -nocrl -certfile "$1" 2>/dev/null | openssl pkcs7 -print_certs -noout >/dev/null 2>&1; }

fingerprints() { # <file>: sorted SHA-256 fingerprints, one per certificate; fails on any parse error or an empty set
  local d n=0 f; d=$(mktemp -d "$WORKDIR/fp.XXXXXX") || return 1
  awk -v d="$d" '/-----BEGIN CERTIFICATE-----/{n++} n>0 {print > (d "/" n ".pem")}' "$1" || { rm -rf "$d"; return 1; }
  for f in "$d"/*.pem; do
    [ -e "$f" ] || break
    openssl x509 -in "$f" -noout -fingerprint -sha256 >> "$d/fps" 2>/dev/null || { rm -rf "$d"; return 1; }
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || { rm -rf "$d"; return 1; }
  sort -u "$d/fps" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

read_bundle() { # <configmap>: prints its ca-bundle.crt; prints nothing when NotFound; fails on any other error
  local out rc=0
  out=$(oc -n openshift-config get configmap "$1" -o jsonpath='{.data.ca-bundle\.crt}' 2>"$WORKDIR/read.err") || rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
  if grep -q -i 'NotFound' "$WORKDIR/read.err"; then return 0; fi
  cat "$WORKDIR/read.err" >&2; return "$rc"; }

# 1. the ConfigMaps the trust patch mounts
oc -n "$AUTHORINO_NAMESPACE" get configmap odh-trusted-ca-bundle openshift-service-ca.crt >/dev/null \
  || die "odh-trusted-ca-bundle and openshift-service-ca.crt must both exist in $AUTHORINO_NAMESPACE before the trust patch can mount them"

# 2. the issuing CA
if [ -n "${HOME_CA_FILE:-}" ]; then
  cp "$HOME_CA_FILE" "$WORKDIR/home-ca.crt"
else
  : "${HOME_KUBECONFIG:?set HOME_KUBECONFIG (or HOME_CA_FILE for a replaced ingress certificate)}"
  oc --kubeconfig "$HOME_KUBECONFIG" -n openshift-ingress-operator get secret router-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORKDIR/home-ca.crt"
fi
certs_ok "$WORKDIR/home-ca.crt" || die "the home CA input is not a PEM certificate bundle"
echo "home CA: $(openssl x509 -in "$WORKDIR/home-ca.crt" -noout -subject -fingerprint -sha256 | tr '\n' ' ')"

# 3. what the site already trusts
name=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}')
existing=$(read_bundle custom-ca)
if [ -n "$name" ] && [ "$name" != custom-ca ] && [ -n "$existing" ]; then
  die "proxy/cluster trusts $name and a separate custom-ca ConfigMap exists; merge them by hand before continuing"
fi
: > "$WORKDIR/bundle.crt"
if [ -n "$name" ]; then read_bundle "$name" > "$WORKDIR/bundle.crt"; else printf '%s' "$existing" > "$WORKDIR/bundle.crt"; fi
if [ -s "$WORKDIR/bundle.crt" ]; then
  certs_ok "$WORKDIR/bundle.crt" || die "the existing bundle ${name:-custom-ca} is not a PEM certificate bundle; fix it before continuing"
  printf '\n' >> "$WORKDIR/bundle.crt"
fi
cat "$WORKDIR/home-ca.crt" >> "$WORKDIR/bundle.crt"
certs_ok "$WORKDIR/bundle.crt" || die "the merged bundle does not parse"
fingerprints "$WORKDIR/bundle.crt" > "$WORKDIR/expected.txt" || die "cannot fingerprint the merged bundle"
[ -s "$WORKDIR/expected.txt" ] || die "the merged bundle yielded no fingerprints"
echo "merged bundle: $(wc -l < "$WORKDIR/expected.txt") certificate(s)"

# 4. write
oc -n openshift-config create configmap custom-ca --from-file=ca-bundle.crt="$WORKDIR/bundle.crt" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc patch proxy/cluster --type merge -p '{"spec":{"trustedCA":{"name":"custom-ca"}}}' >/dev/null

# 5. propagation into the mounted bundle
deadline=$((SECONDS + TIMEOUT_SECONDS))
while :; do
  remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || die "not every certificate of the merged bundle reached odh-trusted-ca-bundle within ${TIMEOUT_SECONDS}s"
  rt=30; if [ "$rt" -gt "$remaining" ]; then rt=$remaining; fi
  if command oc --request-timeout="${rt}s" -n "$AUTHORINO_NAMESPACE" get configmap odh-trusted-ca-bundle -o jsonpath='{.data.ca-bundle\.crt}' > "$WORKDIR/site-bundle.crt" 2>/dev/null \
     && [ -s "$WORKDIR/site-bundle.crt" ]; then
    fingerprints "$WORKDIR/site-bundle.crt" > "$WORKDIR/actual.txt" || die "the mounted odh-trusted-ca-bundle does not parse as PEM certificates"
    missing=$(comm -23 "$WORKDIR/expected.txt" "$WORKDIR/actual.txt") || die "could not compare the expected and mounted fingerprint sets"
    if [ -z "$missing" ] && [ "$SECONDS" -lt "$deadline" ]; then break; fi
  fi
  remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || die "not every certificate of the merged bundle reached odh-trusted-ca-bundle within ${TIMEOUT_SECONDS}s"
  s=$POLL_SECONDS; if [ "$s" -gt "$remaining" ]; then s=$remaining; fi; sleep "$s"
done
echo "propagated: every certificate of the merged bundle is in $AUTHORINO_NAMESPACE/odh-trusted-ca-bundle"

# 6. a verified TLS connection to the home with exactly that bundle
curl --silent --show-error --fail --max-time 30 --cacert "$WORKDIR/site-bundle.crt" \
  "https://${KEYCLOAK_HOST}/realms/${REALM}/.well-known/openid-configuration" > /dev/null \
  || die "TLS verification of https://${KEYCLOAK_HOST}/realms/${REALM}/.well-known/openid-configuration with the propagated bundle failed"
echo "verified: the home's discovery document is reachable with the propagated bundle; the site may now take the role"
