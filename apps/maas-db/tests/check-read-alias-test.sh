#!/usr/bin/env bash
# Exercises check-read-alias.sh against a stub oc (no cluster): a ready hub (ExternalName), a ready remote
# site whose Secret has no dbname, a missing Service, no ready endpoint, a failed read, an unreadable kubeconfig,
# and two sites in one run.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %s\n' "$1"; }; bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %s: %s\n' "$1" "${2:-}"; }
mkdir -p "$T/bin"; cat > "$T/bin/oc" <<'END_STUB'
#!/usr/bin/env bash
# Scenario from the kubeconfig's basename: hub | remote | nosvc | noendpoint | readfail. Every kubeconfig is a scenario file.
kc=""; args=("$@"); for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --kubeconfig ] && kc=$(basename "${args[$((i+1))]}"); done
cmd="$*"
case "$cmd" in
  *"config view"*) echo "site-$kc";;
  *"get svc maas-read-r"*"spec.type"*) [ "$kc" = nosvc ] && exit 1; [ "$kc" = hub ] && echo ExternalName || echo ClusterIP;;
  *"get svc maas-read-r"*"externalName"*) echo maas-db-ro.maas-db.svc.cluster.local;;
  *"get endpointslices"*) if [ "$kc" = noendpoint ]; then echo '{"items":[{"endpoints":[{"addresses":["10.0.0.1"],"conditions":{"ready":false}}]}]}'; else echo '{"items":[{"endpoints":[{"addresses":["10.0.0.1"],"conditions":{"ready":true}}]}]}'; fi;;
  *"get pods"*) echo maas-read-1;;
  *"get secret maas-db-app"*username*) printf 'YXBw';;   # app
  *"get secret maas-db-app"*dbname*) [ "$kc" = remote ] || printf 'bWFhcw==';; # maas; the remote copy has no dbname
  *"get secret maas-db-app"*password*) printf 'c2VjcmV0';;
  *" exec "*) pw=$(cat); [ "$pw" = secret ] || exit 1; [ "$kc" = readfail ] && exit 1; case "$cmd" in *" -d maas "*|*" maas"|*"maas-db.svc.cluster.local app maas"*) echo 1;; *) echo "wrong db in: $cmd" >&2; exit 1;; esac;;
  *) echo "unexpected: $cmd" >&2; exit 99;;
esac
END_STUB
chmod +x "$T/bin/oc"; for s in hub remote nosvc noendpoint readfail; do echo x > "$T/$s"; done; touch "$T/unreadable"; chmod 000 "$T/unreadable"
run() { PATH="$T/bin:$PATH" "$HERE/../check-read-alias.sh" "$@" 2>&1; }
t() { # name want-exit want-substring args...
  local name=$1 wexit=$2 wsub=$3; shift 3; local out rc; out=$(run "$@") && rc=0 || rc=$?
  if [ "$rc" = "$wexit" ] && printf '%s' "$out" | grep -q -- "$wsub"; then ok "$name"; else bad "$name" "exit $rc: $out"; fi; }
t "ready hub through the ExternalName target" 0 "ready: site-hub (maas-db-ro, 1 ready endpoint(s), authenticated read ok)" "$T/hub"
t "ready remote site (no dbname in its Secret: default maas)" 0 "ready: site-remote (maas-read-r, 1" "$T/remote"
t "missing Service" 1 "Service maas-read-r is absent" "$T/nosvc"
t "no ready endpoint" 1 "has no ready endpoint" "$T/noendpoint"
t "failed authenticated read" 1 "authenticated read through maas-read-r.maas-db.svc.cluster.local failed" "$T/readfail"
if [ "$(id -u)" != 0 ]; then t "unreadable kubeconfig" 1 "is not readable" "$T/unreadable"; fi
t "two sites, the second not ready, stops there" 1 "ready: site-hub" "$T/hub" "$T/noendpoint"
t "no argument: usage" 2 "check-read-alias.sh <kubeconfig>"
echo "check-read-alias tests: $((total-fails)) ok, $fails failed"; exit "$fails"
