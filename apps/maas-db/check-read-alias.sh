#!/usr/bin/env bash
# Readiness gate for the read-endpoint switch: on every given site, maas-read-r must exist, resolve to ready
# endpoints and answer an authenticated read, before maas-db-config is switched to it. Exits non-zero at the
# first site that is not ready. Needs oc.
#
#   apps/maas-db/check-read-alias.sh <kubeconfig>...        # the hub's and every ingress or combined site's
#
# A hub's maas-read-r is an ExternalName to maas-db-ro, so its target's endpoints are checked; a remote
# site's is CloudNativePG's -r Service of the replica cluster. The read runs psql inside a database pod of
# that site with the application user's credentials from the maas-db-app Secret (DBNAME, default maas, when
# that Secret has no dbname key).
set -euo pipefail
NS=${NAMESPACE:-maas-db}; HOST=maas-read-r.${NS}.svc.cluster.local
[ "$#" -ge 1 ] || { sed -n '2,9p' "$0" >&2; exit 2; }
die() { printf 'not ready: %s\n' "$*" >&2; exit 1; }
ready_endpoints() { # kubeconfig service -> count of ready addresses behind the Service
  local n; n=$(oc --kubeconfig "$1" -n "$NS" get endpointslices -l "kubernetes.io/service-name=$2" -o json 2>/dev/null \
    | python3 -c 'import json,sys; s=json.load(sys.stdin); print(sum(1 for e in s.get("items",[]) for ep in e.get("endpoints",[]) if ep.get("conditions",{}).get("ready") is True and ep.get("addresses")))') || die "$2: cannot list endpoints"
  printf '%s' "$n"; }
for kc in "$@"; do
  [ -r "$kc" ] || die "$kc is not readable"
  site=$(oc --kubeconfig "$kc" config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || basename "$kc")
  kind=$(oc --kubeconfig "$kc" -n "$NS" get svc maas-read-r -o jsonpath='{.spec.type}' 2>/dev/null) || die "$site: Service maas-read-r is absent"
  if [ "$kind" = ExternalName ]; then
    target=$(oc --kubeconfig "$kc" -n "$NS" get svc maas-read-r -o jsonpath='{.spec.externalName}'); svc=${target%%.*}
  else svc=maas-read-r; fi
  n=$(ready_endpoints "$kc" "$svc"); [ "$n" -ge 1 ] || die "$site: $svc has no ready endpoint"
  pod=$(oc --kubeconfig "$kc" -n "$NS" get pods -l cnpg.io/podRole=instance -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); [ -n "$pod" ] || die "$site: no database pod to run the read from"
  user=$(oc --kubeconfig "$kc" -n "$NS" get secret maas-db-app -o jsonpath='{.data.username}' | base64 -d)
  # The hub's CNPG-generated Secret carries dbname; a replica site's basic-auth copy does not.
  db=$(oc --kubeconfig "$kc" -n "$NS" get secret maas-db-app -o jsonpath='{.data.dbname}' | base64 -d); db=${db:-${DBNAME:-maas}}
  # The password goes to the pod on the exec's stdin, never onto a command line.
  oc --kubeconfig "$kc" -n "$NS" get secret maas-db-app -o jsonpath='{.data.password}' | base64 -d \
    | oc --kubeconfig "$kc" -n "$NS" exec -i "$pod" -c postgres -- sh -c 'PGPASSWORD=$(cat) psql -h "$1" -U "$2" -d "$3" -tAc "select 1" -w' sh "$HOST" "$user" "$db" 2>/dev/null | grep -qx 1 \
    || die "$site: authenticated read through $HOST failed"
  printf 'ready: %s (%s, %s ready endpoint(s), authenticated read ok)\n' "$site" "$svc" "$n"
done
