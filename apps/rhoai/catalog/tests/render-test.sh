#!/usr/bin/env bash
# Renders the catalog chart and checks the nightly-refresh Job's derived deadline and input-hashed name. Needs helm, PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); CHART="$HERE/.."; VALUES="$HERE/../../nightly.yaml"; fails=0; total=0
render() { helm template catalog "$CHART" -f "$VALUES" "$@"; }
field() { # <field> [--set ...]: value of the Job's field, or "RENDER-FAILED"
  local f=$1; shift; local out
  if ! out=$(render "$@" 2>/dev/null); then echo RENDER-FAILED; return 0; fi
  awk -v f="$f" '/^kind: Job$/{j=1} j && $1 == f":"{print $2; exit}' <<<"$out"; }
t() { local name=$1 want=$2 f=$3; shift 3; local got; total=$((total+1)); got=$(field "$f" "$@")
  if [ "$got" = "$want" ]; then printf '   ok   %-44s %s\n' "$name" "$got"; else printf '   FAIL %-44s got %s wanted %s\n' "$name" "$got" "$want"; fails=$((fails+1)); fi; }
[ "$(field kind)" != RENDER-FAILED ] || { echo "   FAIL chart does not render with the default values" >&2; exit 1; }
t deadline-derived-from-defaults 1380 activeDeadlineSeconds
t deadline-derived-with-short-settle 1215 activeDeadlineSeconds --set refresh.catalogSettleSeconds=15
t deadline-derived-with-longer-waits 2100 activeDeadlineSeconds --set refresh.waitTimeoutSeconds=1200 --set refresh.operatorRolloutTimeoutSeconds=420
t deadline-explicit-override-wins 2000 activeDeadlineSeconds --set refresh.activeDeadlineSeconds=2000
base=$(field name); same=$(field name); settle=$(field name --set refresh.catalogSettleSeconds=15); image=$(field name --set refresh.image=registry.example.com/cli:other)
subname=$(field name --set refresh.subscriptionName=other-operator); res=$(field name --set refresh.resources.limits.memory=256Mi)
total=$((total+5))
if [ "$base" != RENDER-FAILED ] && [ "$base" = "$same" ]; then printf '   ok   %-44s %s\n' name-stable-for-identical-inputs "$base"; else printf '   FAIL %-44s %s vs %s\n' name-stable-for-identical-inputs "$base" "$same"; fails=$((fails+1)); fi
if [ "$base" != "$settle" ] && [ "$settle" != RENDER-FAILED ]; then printf '   ok   %-44s %s\n' name-changes-with-settle-time "$settle"; else printf '   FAIL %-44s %s\n' name-changes-with-settle-time "$settle"; fails=$((fails+1)); fi
if [ "$base" != "$image" ] && [ "$image" != RENDER-FAILED ]; then printf '   ok   %-44s %s\n' name-changes-with-job-image "$image"; else printf '   FAIL %-44s %s\n' name-changes-with-job-image "$image"; fails=$((fails+1)); fi
if [ "$base" != "$subname" ] && [ "$subname" != RENDER-FAILED ]; then printf '   ok   %-44s %s\n' name-changes-with-subscription-name "$subname"; else printf '   FAIL %-44s %s\n' name-changes-with-subscription-name "$subname"; fails=$((fails+1)); fi
if [ "$base" != "$res" ] && [ "$res" != RENDER-FAILED ]; then printf '   ok   %-44s %s\n' name-changes-with-resources "$res"; else printf '   FAIL %-44s %s\n' name-changes-with-resources "$res"; fails=$((fails+1)); fi
echo "catalog render tests: $((total-fails)) ok, $fails failed"; exit "$fails"
