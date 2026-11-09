#!/usr/bin/env bash
# Runs the nightly-refresh Job's embedded script (extracted from the rendered chart) against stub oc and sleep
# (no cluster). Needs helm and PyYAML.
# shellcheck disable=SC2001  # sed indents the captured output for readability
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); CHART="$HERE/.."; VALUES="$HERE/../../nightly.yaml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"
helm template catalog "$CHART" -f "$VALUES" > "$T/rendered.yaml"
python3 -c 'import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "Job":
        c = d["spec"]["template"]["spec"]["containers"][0]; cmd = c.get("command", []) + c.get("args", [])
        assert cmd[:2] == ["/bin/bash", "-c"], cmd[:2]; open(sys.argv[2], "w").write(cmd[2]); break
else: raise SystemExit("no Job rendered")' "$T/rendered.yaml" "$T/job.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
cat > "$T/bin/oc" <<'END_OC'
#!/usr/bin/env bash
# Scenario knobs: STUB_SOURCE (spec.source|sourceNamespace), STUB_CHANNELS (channel|csv|image lines),
# STUB_INSTALLED (image installed before the run; empty = fresh), STUB_READY_AFTER (OLM reports the desired CSV
# current after this many state reads; -1 = never), STUB_ROLLOUT_AFTER (Deployments Available after this many
# reads; -1 = never). Counters live in $STUB_STATE.
args="$*"; S="$STUB_STATE"
count() { local f="$S/$1" n; n=$(cat "$f" 2>/dev/null || echo 0); echo $((n+1)) > "$f"; echo "$n"; }
case "$args" in
  *"get subscription.operators.coreos.com"*"{.spec.source}"*) printf '%s' "$STUB_SOURCE" ;;
  *"get subscription.operators.coreos.com"*"jsonpath={.spec}"*) printf '{"channel":"stable-3.6","name":"rhods-operator","source":"rhoai-catalog-dev"}' ;;
  *"get subscription.operators.coreos.com"*"jsonpath={.metadata.labels}"*) printf '' ;;
  *"get subscription.operators.coreos.com"*"jsonpath={.metadata.annotations}"*) printf '{"argocd.argoproj.io/tracking-id":"app:operators.coreos.com/Subscription:redhat-ods-operator/rhods-operator"}' ;;
  *"create -f -"*) m=$(cat); grep -q deleted-csv "$S/deletes" 2>/dev/null || { echo "create before delete" >&2; exit 1; }
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["kind"]=="Subscription" and d["spec"]["source"] and d["metadata"]["labels"]=={} and "argocd.argoproj.io/tracking-id" in d["metadata"]["annotations"]' "$m" || exit 1
    echo created-sub >> "$S/deletes" ;;
  *"get packagemanifests"*) printf '%b' "$STUB_CHANNELS" ;;
  *"delete subscription.operators.coreos.com"*) echo deleted-sub >> "$S/deletes" ;;
  *"delete csv"*) echo deleted-csv >> "$S/deletes" ;;
  *"get subscription.operators.coreos.com"*"{.status.state}"*) n=$(count state); if [[ "$STUB_READY_AFTER" -ge 0 && "$n" -ge "$STUB_READY_AFTER" ]]; then printf 'AtLatestKnown'; else printf 'UpgradePending'; fi ;;
  *"get subscription.operators.coreos.com"*"{.status.currentCSV}"*) n=$(cat "$S/state" 2>/dev/null || echo 0); if [[ "$STUB_READY_AFTER" -ge 0 && "$n" -gt "$STUB_READY_AFTER" ]]; then printf 'rhods-operator.3.6.0'; else printf 'rhods-operator.3.5.0'; fi ;;
  *"get csv rhods-operator.3.6.0"*"containerImage"*) n=$(cat "$S/state" 2>/dev/null || echo 0); if [[ -e "$S/deletes" || -z "$STUB_INSTALLED" ]]; then if [[ "$STUB_READY_AFTER" -ge 0 && "$n" -gt "$STUB_READY_AFTER" ]]; then printf 'quay.io/x/op@sha256:new'; fi; else printf '%s' "$STUB_INSTALLED"; fi ;;
  *"get csv"*"containerImage"*) printf 'quay.io/x/op@sha256:old' ;;
  *"get csv"*"deployments"*) printf 'rhods-operator\n' ;;
  *"get deployment"*"{.metadata.generation}"*) printf '2' ;;
  *"get deployment"*"{.status.observedGeneration}"*) n=$(count rollout); if [[ "$STUB_ROLLOUT_AFTER" -ge 0 && "$n" -ge "$STUB_ROLLOUT_AFTER" ]]; then printf '2'; else printf '1'; fi ;;
  *"get deployment"*"Available"*) n=$(cat "$S/rollout" 2>/dev/null || echo 0); if [[ "$STUB_ROLLOUT_AFTER" -ge 0 && "$n" -gt "$STUB_ROLLOUT_AFTER" ]]; then printf 'True'; else printf 'False'; fi ;;
  *) exit 0 ;;
esac
END_OC
chmod 700 "$T/bin/oc" "$T/bin/sleep"; fails=0; total=0
t() { # name expected_rc expected_deletes [ENV=VAL ...]
  local name=$1 want=$2 wantdel=$3; shift 3; local rc out dels; total=$((total+1)); rm -rf "$T/state"; mkdir -p "$T/state"
  out=$(cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" STUB_STATE="$T/state" STUB_SOURCE='rhoai-catalog-dev|openshift-marketplace' \
        STUB_CHANNELS='stable-3.6|rhods-operator.3.6.0|quay.io/x/op@sha256:new\n' STUB_INSTALLED='quay.io/x/op@sha256:old' STUB_READY_AFTER=2 STUB_ROLLOUT_AFTER=2 \
        PACKAGE=rhods-operator CHANNEL=stable-3.6 CATALOG_NAMESPACE=openshift-marketplace SUBSCRIPTION_NAMESPACE=redhat-ods-operator SUBSCRIPTION_NAME=rhods-operator \
        CATALOG_SETTLE_SECONDS=0 WAIT_TIMEOUT_SECONDS=2 OPERATOR_ROLLOUT_TIMEOUT_SECONDS=2 "$@" bash job.sh 2>&1) && rc=0 || rc=$?
  dels=$({ [[ -e "$T/state/deletes" ]] && sort "$T/state/deletes" || true; } | uniq -c | awk '{printf "%s=%s ", $2, $1}')
  if [[ $rc -eq $want && "${dels:-none }" == "$wantdel " ]]; then printf '   ok   %-36s rc=%s deletes=%s\n' "$name" "$rc" "${dels:-none}"
  else printf '   FAIL %-36s rc=%s wanted %s deletes=%s wanted %s\n%s\n' "$name" "$rc" "$want" "${dels:-none}" "$wantdel" "$(sed 's/^/        /' <<<"$out" | tail -n 8)"; fails=$((fails+1)); fi
}
t already-current-no-refresh 0 "none" STUB_INSTALLED='quay.io/x/op@sha256:new'
t refresh-completes-after-polls 0 "created-sub=1 deleted-csv=1 deleted-sub=1"
t fresh-install-waits-no-delete 0 "none" STUB_INSTALLED=
t olm-never-refreshes 1 "created-sub=1 deleted-csv=1 deleted-sub=1" STUB_READY_AFTER=-1
t deployments-never-roll-out 1 "created-sub=1 deleted-csv=1 deleted-sub=1" STUB_ROLLOUT_AFTER=-1
t subscription-without-source 1 "none" STUB_SOURCE='|'
t channel-not-in-catalog 1 "none" STUB_CHANNELS='fast|rhods-operator.3.7.0|quay.io/x/op@sha256:other\n'
echo "refresh-job tests: $((total-fails)) ok, $fails failed"; exit "$fails"
