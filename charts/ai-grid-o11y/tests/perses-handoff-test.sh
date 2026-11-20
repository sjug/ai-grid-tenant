#!/usr/bin/env bash
# Runs the Perses handoff script (templates/perses-handoff-hooks.yaml) in guard and untrack mode against a stub oc,
# under annotation and label tracking, and checks the two identities' RBAC. Needs helm and PyYAML; no cluster.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); CHART=$HERE/..; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/s"
helm template ai-grid-o11y "$CHART" -f "$CHART/../../values/hub/ai-grid-o11y/values.yaml" \
  --show-only templates/perses-handoff-hooks.yaml > "$T/hooks.yaml"
fails=0
python3 - "$T/hooks.yaml" "$T/handoff.sh" <<'PY' || fails=$((fails+1))
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = [d for d in docs if d["kind"] == "ConfigMap"]
assert len(cm) == 1
open(sys.argv[2], "w").write(cm[0]["data"]["handoff.sh"])
by = {}
for d in docs:
    by.setdefault(d["kind"], []).append(d)
def rules_for(sa):
    out = []
    for b in by.get("RoleBinding", []) + by.get("ClusterRoleBinding", []):
        if any(s["name"] == sa for s in b["subjects"]):
            role = [r for r in by.get(b["roleRef"]["kind"], []) if r["metadata"]["name"] == b["roleRef"]["name"]
                    and (b["kind"] == "ClusterRoleBinding" or r["metadata"].get("namespace") == b["metadata"]["namespace"])]
            assert len(role) == 1, (sa, b["metadata"]["name"])
            for rule in role[0]["rules"]:
                out.append((b["kind"], b["metadata"].get("namespace"), rule))
    return out
ok = True
def check(cond, msg):
    global ok
    print(("   ok   " if cond else "   FAIL ") + msg); ok = ok and cond
guard = rules_for("ai-grid-o11y-perses-guard")
untrack = rules_for("ai-grid-o11y-perses-untrack")
check(guard and all(set(r["verbs"]) == {"get"} for _, _, r in guard), "guard identity can only get")
check(all(r.get("resourceNames") for _, _, r in guard + untrack), "every rule names its objects")
patch = [(k, ns, r) for k, ns, r in untrack if "patch" in r["verbs"]]
check(patch and all(k == "RoleBinding" and ns == "redhat-ods-monitoring" for k, ns, _ in patch),
      "untrack identity patches only in redhat-ods-monitoring")
check(sorted(n for _, _, r in patch for n in r["resourceNames"]) ==
      ["cluster-prometheus-datasource", "dashboard-0-cluster-admin", "dashboard-1-model-admin"], "untrack patches only the three objects")
jobs = {j["metadata"]["annotations"]["argocd.argoproj.io/hook"]: j["spec"]["template"]["spec"]["serviceAccountName"] for j in by["Job"]}
check(jobs == {"PreSync": "ai-grid-o11y-perses-guard", "PostSync": "ai-grid-o11y-perses-untrack"}, "PreSync guards, PostSync untracks")
sys.exit(0 if ok else 1)
PY
# Stub state per object in $T/s/<kind>-<name>: "annotation|label|sync-options"; a missing file is an absent object.
# STUB_METHOD, STUB_LKEY: argocd-cm resourceTrackingMethod and instanceLabelKey. STUB_NO_API, STUB_API_RC, STUB_CM_RC, STUB_GET_RC, STUB_PATCH_RC.
cat > "$T/bin/oc" <<'END_STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "$1 $2 $3" = "-n openshift-gitops get" ]; then
  [ "$4 $5" = "configmap argocd-cm" ] || exit 9; [ "${STUB_CM_RC:-0}" -eq 0 ] || exit "$STUB_CM_RC"
  printf '%s|%s' "${STUB_METHOD:-}" "${STUB_LKEY:-}"; exit 0
fi
if [ "$1" = api-resources ]; then
  [ "${STUB_API_RC:-0}" -eq 0 ] || exit "$STUB_API_RC"
  [ -n "${STUB_NO_API:-}" ] || printf 'persesdatasources.perses.dev\npersesdashboards.perses.dev\n'; exit 0
fi
[ "$1 $2" = "-n redhat-ods-monitoring" ] || { echo "unexpected: $*" >&2; exit 9; }
verb=$3 kind=${4%.perses.dev} name=$5 f=$STUB_DIR/$kind-$name
lkey=${STUB_LKEY:-app.kubernetes.io/instance}
case $verb in
  get)
    [ "${STUB_GET_RC:-0}" -eq 0 ] || exit "$STUB_GET_RC"
    case "$*" in *"{.metadata.labels.${lkey//./\\.}}"*) ;; *) echo "label key not read: $*" >&2; exit 7;; esac
    [ -e "$f" ] && cat "$f"; exit 0 ;;
  patch)
    [ "${STUB_PATCH_RC:-0}" -eq 0 ] || exit "$STUB_PATCH_RC"
    [ "$6 $7" = "--type=json -p" ] || { echo "unexpected patch: $*" >&2; exit 8; }
    [ -e "$f" ] || exit 1
    IFS='|' read -r ann lbl opts < "$f"
    res=$(printf '%s' "$8" | python3 -c '
import json, sys
ops = json.load(sys.stdin); ann_path = "/metadata/annotations/argocd.argoproj.io~1tracking-id"
lbl_path = "/metadata/labels/" + sys.argv[3].replace("/", "~1")
if ops == [{"op": "test", "path": ann_path, "value": sys.argv[1]}, {"op": "remove", "path": ann_path}]: print("ann")
elif ops == [{"op": "test", "path": lbl_path, "value": "ai-grid-o11y"}, {"op": "remove", "path": lbl_path}]: print("lbl")
else: sys.exit(8)' "ai-grid-o11y:perses.dev/$kind:redhat-ods-monitoring/$name" x "$lkey") || exit 8
    if [ "$res" = ann ]; then [ "$ann" = "ai-grid-o11y:perses.dev/$kind:redhat-ods-monitoring/$name" ] || exit 1; ann=""
    else [ "$lbl" = ai-grid-o11y ] || exit 1; lbl=""; fi
    printf '%s|%s|%s' "$ann" "$lbl" "$opts" > "$f"; exit 0 ;;
  *) echo "unexpected oc $*" >&2; exit 9 ;;
esac
END_STUB
chmod 700 "$T/bin/oc"
OBJS="PersesDatasource-cluster-prometheus-datasource PersesDashboard-dashboard-0-cluster-admin PersesDashboard-dashboard-1-model-admin"
ours() { echo "ai-grid-o11y:perses.dev/${1%%-*}:redhat-ods-monitoring/${1#*-}"; }
seed() { # how(ann|lbl|both|foreign-ann-our-lbl|other|none|absent) sync-options
  rm -f "$T"/s/*; for o in $OBJS; do case $1 in
    ann) printf '%s||%s' "$(ours "$o")" "$2";; lbl) printf '|ai-grid-o11y|%s' "$2";; both) printf '%s|ai-grid-o11y|%s' "$(ours "$o")" "$2";;
    foreign-ann-our-lbl) printf 'other-app:x|ai-grid-o11y|%s' "$2";;
    other) printf 'other-app:x|other-app|%s' "$2";; none) printf '||%s' "$2";; absent) continue;; esac > "$T/s/$o"; done
  snapshot=$(cat "$T"/s/* 2>/dev/null || true)
}
count() { # field(ann|lbl): objects whose field points at this Application
  local n=0 a l; for o in $OBJS; do [ -e "$T/s/$o" ] || continue; IFS='|' read -r a l _ < "$T/s/$o"
  if [ "$1" = ann ]; then [ "$a" = "$(ours "$o")" ] && n=$((n+1)); else [ "$l" = ai-grid-o11y ] && n=$((n+1)); fi; done; echo $n; }
t() { # name mode want_rc want_ann want_lbl [ENV=VAL ...]
  local name=$1 mode=$2 want=$3 wa=$4 wl=$5; shift 5; local rc; : > "$T/log"
  env -i PATH="$T/bin:/usr/bin:/bin" STUB_LOG="$T/log" STUB_DIR="$T/s" "$@" bash "$T/handoff.sh" "$mode" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ] && [ "$(count ann)" = "$wa" ] && [ "$(count lbl)" = "$wl" ]; then printf '   ok   %-60s rc=%s\n' "$name" "$rc"
  else printf '   FAIL %-60s rc=%s ann=%s lbl=%s, wanted rc=%s ann=%s lbl=%s\n' "$name" "$rc" "$(count ann)" "$(count lbl)" "$want" "$wa" "$wl"; fails=$((fails+1)); fi
}
unchanged() { if [ "$(cat "$T"/s/* 2>/dev/null || true)" = "$snapshot" ]; then printf '   ok   %-60s\n' "$1"; else printf '   FAIL %-60s\n' "$1"; fails=$((fails+1)); fi; }
P="Prune=false,Delete=false"; L=STUB_METHOD=label
# Annotation tracking (Argo CD 3 default, also when the key is unset).
seed ann "$P";   t "annotation: tracked and protected" guard 0 3 0
seed ann "Delete=false,Prune=false"; t "annotation: protection in either order" guard 0 3 0
seed ann "";     t "annotation: tracked without protection stops" guard 1 3 0
seed ann "Prune=false"; t "annotation: Prune=false alone stops" guard 1 3 0
seed ann "";     t "annotation+label: tracked without protection stops" guard 1 3 0 STUB_METHOD=annotation+label
seed foreign-ann-our-lbl ""; t "annotation: matching label alone is not ours (guard)" guard 0 0 3
seed foreign-ann-our-lbl ""; t "annotation: matching label alone is not ours (untrack)" untrack 0 0 3; unchanged "annotation: foreign annotation and label both survive"
seed ann "$P";   t "untrack annotation: removes the tracking annotation" untrack 0 0 0
seed both "$P";  t "untrack annotation: keeps the instance label" untrack 0 0 3
# Label tracking.
seed lbl "$P";   t "label: tracked and protected" guard 0 0 3 $L
seed lbl "";     t "label: tracked without protection stops" guard 1 0 3 $L
seed lbl "";     t "label: custom label key, unprotected, stops" guard 1 0 3 $L STUB_LKEY=example.com/app
seed ann "";     t "label: annotation alone is not ours" guard 0 3 0 $L
seed lbl "$P";   t "untrack label: removes the instance label" untrack 0 0 0 $L
seed lbl "$P";   t "untrack label: custom label key" untrack 0 0 0 $L STUB_LKEY=example.com/app
seed both "$P";  t "untrack label: keeps the annotation" untrack 0 3 0 $L
# Either method.
seed ann "";     t "unsupported tracking method fails" guard 1 3 0 STUB_METHOD=bogus
seed other "";   t "another owner is ignored" guard 0 0 0
seed absent "";  t "fresh install, objects absent" guard 0 0 0
seed absent "";  t "perses.dev not installed" guard 0 0 0 STUB_NO_API=1
seed ann "$P";   t "API discovery fails" guard 1 3 0 STUB_API_RC=1
seed ann "$P";   t "argocd-cm unreadable" guard 1 3 0 STUB_CM_RC=1
seed ann "$P";   t "object read fails" guard 1 3 0 STUB_GET_RC=1
seed none "$P";  t "untrack: already untracked" untrack 0 0 0
seed other "";   t "untrack: another owner is left alone" untrack 0 0 0; unchanged "untrack: another owner's object unchanged"
seed absent "";  t "untrack: objects absent" untrack 0 0 0
seed ann "$P";   t "untrack: rejected patch fails" untrack 1 3 0 STUB_PATCH_RC=1
seed ann "$P";   t "untrack: read after a successful patch fails" untrack 1 2 0 STUB_GET_RC=1
echo "perses handoff tests: $fails failed"
exit $(( fails > 0 ))
