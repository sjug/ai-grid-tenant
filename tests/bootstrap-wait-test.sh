#!/usr/bin/env bash
# Exercises bootstrap.sh's wait_for_argocd against a stub oc (no cluster).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"
sed -n '/^wait_for_argocd() {/,/^}/p' "$HERE/../bootstrap.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { echo "wait_for_argocd not found in bootstrap.sh" >&2; exit 1; }
cat > "$T/bin/oc" <<'END_STUB'
#!/usr/bin/env bash
# STUB_PHASES: phases returned on successive calls (the last repeats); STUB_RC: exit status after printing;
# STUB_DELAY: seconds each call takes.
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_COUNTER"
[ "${STUB_DELAY:-0}" -gt 0 ] && sleep "$STUB_DELAY"
set -- $STUB_PHASES; i=$n; [ "$i" -ge $# ] && i=$(( $# - 1 )); shift "$i"; printf '%s' "$1"; exit "${STUB_RC:-0}"
END_STUB
chmod 700 "$T/bin/oc"; fails=0; total=0
t() { # name expected_rc phases timeout [ENV=VAL ...]
  local name=$1 want=$2 phases=$3 timeout=$4; shift 4; local rc; total=$((total+1)); : > "$T/counter"
  (cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" STUB_PHASES="$phases" STUB_COUNTER="$T/counter" ARGOCD_READY_TIMEOUT_SECONDS="$timeout" ARGOCD_POLL_SECONDS=0 "$@" bash -c "source fn.sh; wait_for_argocd" >/dev/null 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ]; then printf '   ok   %-36s rc=%s polls=%s\n' "$name" "$rc" "$(cat "$T/counter")"; else printf '   FAIL %-36s rc=%s wanted %s\n' "$name" "$rc" "$want"; fails=$((fails+1)); fi
}
t available-at-once 0 "Available" 5
t available-after-three-polls 0 "Pending Pending Pending Available" 5
t never-available-times-out 1 "Pending" 1
t timeout-zero-fails-fast 1 "Available" 0
t available-but-command-failed 1 "Available" 5 STUB_RC=1
t available-only-after-deadline 1 "Available" 1 STUB_DELAY=2
echo "bootstrap-wait tests: $((total-fails)) ok, $fails failed"; exit "$fails"
