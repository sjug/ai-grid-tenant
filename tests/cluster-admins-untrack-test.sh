#!/usr/bin/env bash
# Runs the script of apps/gitops-config/manifests/cluster-admins-untrack.yaml against a stub oc (no cluster), and
# renders the cluster-config ApplicationSet's templatePatch for hub and managed-cluster inputs. Needs PyYAML and helm.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"
python3 - "$HERE/../apps/gitops-config/manifests/cluster-admins-untrack.yaml" "$T/job.sh" <<'PY'
import sys, yaml
jobs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Job"]
assert len(jobs) == 1, len(jobs)
c = jobs[0]["spec"]["template"]["spec"]["containers"][0]
assert c["command"][:2] == ["/bin/bash", "-c"], c["command"]
open(sys.argv[2], "w").write(c["command"][2])
PY
# The stub keeps the Group's tracking annotation in $STUB_STATE (empty: absent annotation; "-": no Group).
# A JSON patch applies only when its test value equals the state at that moment. STUB_TAKEOVER replaces the state
# just before the first patch (another owner); STUB_PATCH_RC forces a failed patch; STUB_GET_RC a failed read.
cat > "$T/bin/oc" <<'END_STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"; state=$(cat "$STUB_STATE")
case "$1" in
  patch)
    if [ -n "${STUB_TAKEOVER:-}" ] && [ ! -e "$STUB_STATE.taken" ]; then printf '%s' "$STUB_TAKEOVER" > "$STUB_STATE"; touch "$STUB_STATE.taken"; state=$STUB_TAKEOVER; fi
    [ "${STUB_PATCH_RC:-0}" -eq 0 ] || exit "$STUB_PATCH_RC"
    [ "$state" = "-" ] && exit 1
    # Exactly: patch group cluster-admins --type=json -p [test this Application's ID, remove that key].
    [ "$2 $3 $4 $5" = "group cluster-admins --type=json -p" ] || { echo "unexpected patch call: $*" >&2; exit 8; }
    printf '%s' "$6" | python3 -c '
import json, sys
ops = json.load(sys.stdin); key = "/metadata/annotations/argocd.argoproj.io~1tracking-id"
assert ops == [{"op": "test", "path": key, "value": sys.argv[1]}, {"op": "remove", "path": key}], ops' "$STUB_OURS" || exit 8
    [ "$state" = "$STUB_OURS" ] || exit 1
    : > "$STUB_STATE"; exit 0 ;;
  get)
    [ "${STUB_GET_RC:-0}" -eq 0 ] || exit "$STUB_GET_RC"
    [ "$state" = "-" ] || printf '%s' "$state"; exit 0 ;;
  *) echo "unexpected oc $*" >&2; exit 9 ;;
esac
END_STUB
chmod 700 "$T/bin/oc"; fails=0; total=0
OURS="gitops-config:user.openshift.io/Group:openshift-gitops/cluster-admins"
OTHER="other-app:user.openshift.io/Group:openshift-gitops/cluster-admins"
t() { # name expected_rc initial_state expected_final_state [ENV=VAL ...]
  local name=$1 want=$2 init=$3 final=$4; shift 4; local rc got; total=$((total+1))
  printf '%s' "$init" > "$T/state"; rm -f "$T/state.taken"; : > "$T/log"
  env -i PATH="$T/bin:/usr/bin:/bin" STUB_LOG="$T/log" STUB_STATE="$T/state" STUB_OURS="$OURS" "$@" bash "$T/job.sh" >/dev/null 2>&1 && rc=0 || rc=$?
  got=$(cat "$T/state")
  if [ "$rc" -eq "$want" ] && [ "$got" = "$final" ]; then printf '   ok   %-34s rc=%s\n' "$name" "$rc"
  else printf '   FAIL %-34s rc=%s state=%s, wanted rc=%s state=%s\n' "$name" "$rc" "$got" "$want" "$final"; fails=$((fails+1)); fi
}
t this-application-tracks-it 0 "$OURS" ""
t no-tracking-annotation 0 "" ""
t group-absent 0 "-" "-"
t another-owner-tracks-it 0 "$OTHER" "$OTHER"
t owner-changes-before-patch 0 "$OURS" "$OTHER" STUB_TAKEOVER="$OTHER"
t patch-rejected-still-ours 1 "$OURS" "$OURS" STUB_PATCH_RC=1
t patch-and-read-fail 1 "$OURS" "$OURS" STUB_PATCH_RC=1 STUB_GET_RC=1
# The templatePatch, rendered with Helm's Go template engine (the same Sprig functions as Argo CD).
python3 - "$HERE/../cluster-config/hub/00-applicationset.yaml" "$T/chart" <<'PY'
import os, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert "allowEmpty" not in d["spec"]["template"]["spec"]["syncPolicy"]["automated"], "allowEmpty must not be in the shared template"
os.makedirs(sys.argv[2] + "/templates")
open(sys.argv[2] + "/Chart.yaml", "w").write("apiVersion: v2\nname: patch\nversion: 0.0.0\n")
body = '{{- with dict "metadata" (dict "labels" .Values.labels) "name" .Values.name "server" .Values.server }}\n' + d["spec"]["templatePatch"] + "{{- end }}\n"
open(sys.argv[2] + "/templates/patch.yaml", "w").write(body)
PY
r() { # name labels(json) cluster-name server expected_allowEmpty
  local got; total=$((total+1))
  got=$(helm template x "$T/chart" --set-json "labels=$2" --set "name=$3" --set "server=$4" | python3 -c 'import sys,yaml; print(str(yaml.safe_load(sys.stdin)["spec"]["syncPolicy"]["automated"]["allowEmpty"]).lower())' 2>&1) || got="error: $got"
  if [ "$got" = "$5" ]; then printf '   ok   %-34s allowEmpty=%s\n' "$1" "$got"; else printf '   FAIL %-34s allowEmpty=%s wanted %s\n' "$1" "$got" "$5"; fails=$((fails+1)); fi
}
R=https://api.cluster.example:6443; L=https://kubernetes.default.svc
r hub-by-label '{"local-cluster":"true"}' local-cluster "$L" false
r hub-without-label '{}' local-cluster "$L" false
r renamed-hub-with-label '{"local-cluster":"true"}' my-hub "$L" false
r renamed-unlabelled-in-cluster-hub '{}' my-hub "$L" false
r managed-cluster '{}' spoke-1 "$R" true
r managed-cluster-label-false '{"local-cluster":"false"}' spoke-2 "$R" true
echo "cluster-admins-untrack tests: $((total-fails)) ok, $fails failed"; exit "$fails"
