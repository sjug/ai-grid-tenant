#!/usr/bin/env bash
# Exercises check-read-alias.sh against a stub oc (no cluster): a ready hub (ExternalName), a ready remote
# site whose Secret has no dbname, a missing Service, no ready endpoint, a failed read, an unreadable kubeconfig,
# two sites in one run, and a remote replica that is stale (another systemID), reports no systemID, not streaming,
# unreachable by exec, or has no hub given; the hub's systemID is read once per run, only from the hub.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %s\n' "$1"; }; bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %s: %s\n' "$1" "${2:-}"; }
mkdir -p "$T/bin"; cat > "$T/bin/oc" <<'END_STUB'
#!/usr/bin/env bash
# Scenario from the kubeconfig's basename: hub | remote | remote2 | nosvc | noendpoint | readfail | stale | nostream | execfail
# | nosysid (maas-read has a primary but no systemID) | decoy (a site that also has a maas-db Cluster, another systemID).
# Every kubeconfig is a scenario file.
kc=""; args=("$@"); for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --kubeconfig ] && kc=$(basename "${args[$((i+1))]}"); done
cmd="$*"
case "$cmd" in
  *"config view"*) echo "site-$kc";;
  *"get svc maas-read-r"*"spec.type"*) [ "$kc" = nosvc ] && exit 1; [ "$kc" = hub ] && echo ExternalName || echo ClusterIP;;
  *"get svc maas-read-r"*"externalName"*) echo maas-db-ro.maas-db.svc.cluster.local;;
  *"get endpointslices"*) if [ "$kc" = noendpoint ]; then echo '{"items":[{"endpoints":[{"addresses":["10.0.0.1"],"conditions":{"ready":false}}]}]}'; else echo '{"items":[{"endpoints":[{"addresses":["10.0.0.1"],"conditions":{"ready":true}}]}]}'; fi;;
  *"get clusters.postgresql.cnpg.io maas-db "*) echo "$kc" >> "${HUB_LOOKUPS:-/dev/null}"; case "$kc" in hub) echo 7300000000000000001;; decoy) echo 7999999999999999999;; *) exit 1;; esac;;
  *"get clusters.postgresql.cnpg.io maas-read "*systemID*) case "$kc" in stale) echo 7100000000000000009;; nosysid) ;; *) echo 7300000000000000001;; esac;;
  *"get clusters.postgresql.cnpg.io maas-read "*currentPrimary*) echo maas-read-1;;
  *" exec "*pg_stat_wal_receiver*) [ "$kc" = execfail ] && exit 1; [ "$kc" = nostream ] || echo streaming;;
  *"get pods"*) echo maas-read-1;;
  *"get secret maas-db-app"*username*) printf 'YXBw';;   # app
  *"get secret maas-db-app"*dbname*) [ "$kc" = remote ] || printf 'bWFhcw==';; # maas; the remote copy has no dbname
  *"get secret maas-db-app"*password*) printf 'c2VjcmV0';;
  *" exec "*) pw=$(cat); [ "$pw" = secret ] || exit 1; [ "$kc" = readfail ] && exit 1; case "$cmd" in *" -d maas "*|*" maas"|*"maas-db.svc.cluster.local app maas"*) echo 1;; *) echo "wrong db in: $cmd" >&2; exit 1;; esac;;
  *) echo "unexpected: $cmd" >&2; exit 99;;
esac
END_STUB
chmod +x "$T/bin/oc"; for s in hub remote remote2 nosvc noendpoint readfail stale nostream execfail nosysid decoy; do echo x > "$T/$s"; done; touch "$T/unreadable"; chmod 000 "$T/unreadable"
run() { PATH="$T/bin:$PATH" "$HERE/../check-read-alias.sh" "$@" 2>&1; }
t() { # name want-exit want-substring args...
  local name=$1 wexit=$2 wsub=$3; shift 3; local out rc; out=$(run "$@") && rc=0 || rc=$?
  if [ "$rc" = "$wexit" ] && printf '%s' "$out" | grep -q -- "$wsub"; then ok "$name"; else bad "$name" "exit $rc: $out"; fi; }
t "ready hub through the ExternalName target" 0 "ready: site-hub (maas-db-ro, 1 ready endpoint(s), authenticated read ok)" "$T/hub"
t "ready remote site (no dbname in its Secret: default maas)" 0 "ready: site-remote (maas-read-r, 1 ready endpoint(s), replica of hub system 7300000000000000001, streaming, authenticated read ok)" "$T/hub" "$T/remote"
t "hub kubeconfig after the site still found" 0 "ready: site-remote (maas-read-r, 1" "$T/remote" "$T/hub"
t "stale replica: systemID differs from the hub's" 1 "site-stale: stale replica: maas-read systemID 7100000000000000009 != hub maas-db systemID 7300000000000000001; re-create maas-read" "$T/hub" "$T/stale"
t "replica has a primary but no systemID" 1 "site-nosysid: Cluster maas-read reports no systemID (needs CloudNativePG 1.27 or later)" "$T/hub" "$T/nosysid"
t "replica not streaming" 1 "site-nostream: maas-read (maas-read-1) WAL receiver status is not streaming (none)" "$T/hub" "$T/nostream"
t "hub found by its ExternalName, not by a maas-db Cluster" 0 "ready: site-decoy (maas-read-r, 1 ready endpoint(s), replica of hub system 7300000000000000001" "$T/decoy" "$T/hub"
t "remote site without the hub's kubeconfig" 1 "site-remote: cannot read the hub maas-db Cluster's systemID" "$T/remote"
t "psql cannot run in the replica's primary" 1 "site-execfail: cannot run psql in maas-read-1 to read its WAL receiver status" "$T/hub" "$T/execfail"
: > "$T/lookups"; out=$(HUB_LOOKUPS="$T/lookups" run "$T/remote" "$T/remote2" "$T/hub") || true
n=$(grep -c . "$T/lookups" || true)
# Only the hub, found by its ExternalName, is asked for maas-db: 1 lookup. A second lookup for remote2 would make 2.
if printf '%s' "$out" | grep -q "ready: site-remote2" && [ "$n" = 1 ]; then ok "hub systemID read once for two remote sites"; else bad "hub systemID read once for two remote sites" "lookups $n (want 1): $out"; fi
t "missing Service" 1 "Service maas-read-r is absent" "$T/nosvc"
t "no ready endpoint" 1 "has no ready endpoint" "$T/noendpoint"
t "failed authenticated read" 1 "authenticated read through maas-read-r.maas-db.svc.cluster.local failed" "$T/hub" "$T/readfail"
if [ "$(id -u)" != 0 ]; then t "unreadable kubeconfig" 1 "is not readable" "$T/unreadable"; fi
t "two sites, the second not ready, stops there" 1 "ready: site-hub" "$T/hub" "$T/noendpoint"
t "no argument: usage" 2 "check-read-alias.sh <hub kubeconfig> <site kubeconfig>..."
echo "check-read-alias tests: $((total-fails)) ok, $fails failed"; exit "$fails"
