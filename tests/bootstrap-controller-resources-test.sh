#!/usr/bin/env bash
# Runs bootstrap.sh against a stub oc (no cluster) and checks that it sets the Argo CD application
# controller's resources from apps/gitops-config/manifests/argocd.yaml after the instance is Available,
# waits for the controller's StatefulSet to roll out with them, and only then applies the root ApplicationSet. The manifest is read with the real oc when one is on
# PATH (oc label --local needs no cluster); otherwise the stub returns canned JSON.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT="$HERE/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"
REAL_OC=$(command -v oc || true)
manifest="$ROOT/apps/gitops-config/manifests/argocd.yaml"
# The controller's memory request and limit, read from the manifest without oc.
read_mem() { awk -v k="$1" '/^  controller:/{c=1;next} c&&/^  [a-z]/{c=0} c&&$1==k":"{f=1;next} f&&$1=="memory:"{print $2;exit}' "$manifest"; }
req=$(read_mem requests); lim=$(read_mem limits)
[ -n "$req" ] && [ -n "$lim" ] || { echo "controller memory not found in $manifest" >&2; exit 1; }

cat > "$T/bin/oc" <<'END_STUB'
#!/usr/bin/env bash
# Logs each call; answers the Argo CD phase wait; STUB_PATCH_RC fails the controller patch;
# STUB_STS_LIMIT is the controller StatefulSet's memory limit; STUB_ROLLOUT_RC fails its rollout status.
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *"get argocd openshift-gitops"*) printf Available ;;
  *"get statefulset openshift-gitops-application-controller"*) printf '%s' "${STUB_STS_LIMIT:-}" ;;
  *"rollout status statefulset/openshift-gitops-application-controller"*) exit "${STUB_ROLLOUT_RC:-0}" ;;
  "label --local"*"limits.memory"*)
    if [ -n "${REAL_OC:-}" ]; then exec "$REAL_OC" "$@"; fi
    grep -q 'controller:' "$4" && printf '%s' "${STUB_LIMIT:-}" ;;
  "label --local"*)
    if [ -n "${REAL_OC:-}" ]; then exec "$REAL_OC" "$@"; fi
    grep -q 'controller:' "$4" && printf '%s' "${STUB_RESOURCES:-}" ;;
  "patch argocd openshift-gitops"*) exit "${STUB_PATCH_RC:-0}" ;;
esac
exit 0
END_STUB
chmod 700 "$T/bin/oc"; fails=0; total=0

# setup <dir> <argocd.yaml source>: a copy of bootstrap.sh with the given gitops-config manifest and a
# stub create-hub-secret.sh.
setup() {
  mkdir -p "$1/apps/gitops-config/manifests" "$1/apps/rhoai-prerequisites"
  cp "$ROOT/bootstrap.sh" "$1/"; cp "$2" "$1/apps/gitops-config/manifests/argocd.yaml"
  printf '#!/usr/bin/env bash\necho create-hub-secret >> "$STUB_LOG"\n' > "$1/apps/rhoai-prerequisites/create-hub-secret.sh"
}
run() { # dir log [ENV=VAL ...]
  local dir=$1 log=$2; shift 2; : > "$log"
  (cd "$dir" && env -i PATH="$T/bin:/usr/bin:/bin" REAL_OC="$REAL_OC" STUB_LOG="$log" \
    STUB_RESOURCES="{\"limits\":{\"memory\":\"$lim\"},\"requests\":{\"memory\":\"$req\"}}" \
    STUB_LIMIT="$lim" STUB_STS_LIMIT="$lim" \
    "$@" bash bootstrap.sh >/dev/null 2>&1)
}
line_of() { grep -n -m1 -e "$2" "$1" | cut -d: -f1; }
check() { # name condition...
  local name=$1; shift; total=$((total+1))
  if "$@"; then printf '   ok   %s\n' "$name"; else printf '   FAIL %s\n' "$name"; fails=$((fails+1)); fi
}
ordered() { # log root
  local ready patch wait root
  ready=$(line_of "$1" 'get argocd openshift-gitops'); patch=$(line_of "$1" '^patch argocd openshift-gitops')
  wait=$(line_of "$1" 'rollout status statefulset/openshift-gitops-application-controller')
  root=$(line_of "$1" "^apply -f $2\$")
  [ -n "$ready" ] && [ -n "$patch" ] && [ -n "$wait" ] && [ -n "$root" ] &&
    [ "$ready" -lt "$patch" ] && [ "$patch" -lt "$wait" ] && [ "$wait" -lt "$root" ]
}
payload_ok() { # log
  local p; p=$(grep -m1 '^patch argocd openshift-gitops' "$1")
  [[ "$p" == *"--type merge -p "* ]] && [[ "$p" == *'"requests":{"memory":"'"$req"'"}'* ]] &&
    [[ "$p" == *'"limits":{"memory":"'"$lim"'"}'* ]] && [[ "$p" == *'{"spec":{"controller":{"resources":{'* ]]
}
no_root() { ! grep -q 'applicationset.yaml' "$1"; }

[ -n "$REAL_OC" ] && echo "   reading argocd.yaml with $REAL_OC" || echo "   no oc on PATH: canned resources (read not exercised)"

setup "$T/default" "$manifest"
run "$T/default" "$T/default.log" && rc=0 || rc=$?
check "default: bootstrap succeeds" [ "$rc" -eq 0 ]
check "default: Available, then patch, then rollout wait, then root" ordered "$T/default.log" bootstrap/applicationset.yaml
check "default: patch carries argocd.yaml's requests $req, limits $lim" payload_ok "$T/default.log"

setup "$T/hub" "$manifest"
run "$T/hub" "$T/hub.log" BOOTSTRAP_PROFILE=dedicated-hub && rc=0 || rc=$?
check "dedicated-hub: bootstrap succeeds" [ "$rc" -eq 0 ]
check "dedicated-hub: Available, then patch, then rollout wait, then root" ordered "$T/hub.log" bootstrap/dedicated-hub/applicationset.yaml
check "dedicated-hub: patch carries argocd.yaml's values" payload_ok "$T/hub.log"

printf 'apiVersion: argoproj.io/v1beta1\nkind: ArgoCD\nmetadata:\n  name: openshift-gitops\nspec: {}\n' > "$T/empty.yaml"
setup "$T/empty" "$T/empty.yaml"
run "$T/empty" "$T/empty.log" && rc=0 || rc=$?
check "no controller resources: bootstrap fails" [ "$rc" -ne 0 ]
check "no controller resources: no patch, no root" bash -c "! grep -q '^patch argocd' '$T/empty.log' && ! grep -q applicationset.yaml '$T/empty.log'"

setup "$T/patchfail" "$manifest"
run "$T/patchfail" "$T/patchfail.log" STUB_PATCH_RC=1 && rc=0 || rc=$?
check "patch fails: bootstrap fails" [ "$rc" -ne 0 ]
check "patch fails: root not applied" no_root "$T/patchfail.log"

setup "$T/stale" "$manifest"
run "$T/stale" "$T/stale.log" STUB_STS_LIMIT=1Gi ARGOCD_CONTROLLER_TIMEOUT_SECONDS=2 ARGOCD_POLL_SECONDS=1 && rc=0 || rc=$?
check "controller never gets the limit: bootstrap fails" [ "$rc" -ne 0 ]
check "controller never gets the limit: root not applied" no_root "$T/stale.log"

setup "$T/rolloutfail" "$manifest"
run "$T/rolloutfail" "$T/rolloutfail.log" STUB_ROLLOUT_RC=1 && rc=0 || rc=$?
check "rollout wait fails: bootstrap fails" [ "$rc" -ne 0 ]
check "rollout wait fails: root not applied" no_root "$T/rolloutfail.log"

echo "bootstrap-controller-resources tests: $((total-fails)) ok, $fails failed"; exit "$fails"
