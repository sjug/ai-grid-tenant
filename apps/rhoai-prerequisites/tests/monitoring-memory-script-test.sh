#!/usr/bin/env bash
# Stub tests for set-monitoring-memory.sh against a fake kubectl that applies JSON Patch test operations like the
# API server and plays scripted watch streams (RHOAIENG-104114). Needs python3. No cluster is contacted.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../set-monitoring-memory.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/flags"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
is() {
  local what=$1
  shift
  if "$@" > /dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}

cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env python3
import copy
import json
import os
import sys
import time

root = os.environ["STUB_ROOT"]
flag = lambda name: os.path.exists(os.path.join(root, "flags", name))
open(os.path.join(root, "calls.log"), "a").write(" ".join(sys.argv[1:]) + "\n")
args = sys.argv[1:]
assert args[:2] == ["--kubeconfig", os.path.join(root, "kubeconfig")], "every call must name the site's kubeconfig"
args = args[2:]
watching = "--watch" in args
if not watching:
    assert args[0] == "--request-timeout=30s", "ordinary requests must be bounded"
    args = args[1:]
line = " ".join(args)


def count(name):
    path = os.path.join(root, "n-" + name)
    n = int(open(path).read()) + 1 if os.path.exists(path) else 1
    open(path, "w").write(str(n))
    return n


def seen(name):
    path = os.path.join(root, "n-" + name)
    return int(open(path).read()) if os.path.exists(path) else 0


def not_found(what):
    sys.stderr.write('Error from server (NotFound): %s not found\n' % what)
    sys.exit(1)


COLLECTOR, STACK = "data-science-collector", "data-science-monitoringstack"
SHIPPED = {COLLECTOR: ("256Mi", "256Mi"), STACK: ("256Mi", "512Mi")}
WANT = {COLLECTOR: ("2Gi", "6Gi"), STACK: ("1Gi", "2Gi")}
patched_once = seen("patch-" + COLLECTOR) + seen("patch-" + STACK) > 0


def monitoring():
    m = {"metadata": {"name": "default-monitoring", "uid": "mon-uid"}, "spec": {"namespace": "observability"}}
    if flag("monitoring-terminating") or (flag("monitoring-terminating-after-patch") and patched_once):
        m["metadata"]["deletionTimestamp"] = "2026-01-01T00:00:00Z"
    if flag("monitoring-replaced-after-patch") and patched_once: m["metadata"]["uid"] = "mon-new"
    if flag("namespace-changes-after-patch") and patched_once: m["spec"]["namespace"] = "elsewhere"
    if flag("monitoring-no-namespace"): del m["spec"]["namespace"]
    if flag("monitoring-no-uid"): del m["metadata"]["uid"]
    return m


def shipped(name):
    request, limit = SHIPPED[name]
    owner = {"kind": "Monitoring", "name": "default-monitoring", "uid": "mon-uid", "controller": True}
    obj = {"metadata": {"name": name, "namespace": "observability", "uid": "uid-" + name, "resourceVersion": "100",
                        "annotations": {"platform.opendatahub.io/type": "OpenDataHub"}, "ownerReferences": [owner]},
           "spec": {"replicas": 2, "resources": {"limits": {"cpu": 1, "memory": limit},
                                                 "requests": {"cpu": "100m", "memory": request}}}}
    meta = obj["metadata"]
    here = lambda f: flag(f) or (name == COLLECTOR and flag("collector-" + f)) or (name == STACK and flag("stack-" + f))
    if here("already-set"):
        meta["annotations"]["opendatahub.io/managed"] = "false"
        obj["spec"]["resources"]["requests"]["memory"], obj["spec"]["resources"]["limits"]["memory"] = WANT[name]
    if here("opted-out"): meta["annotations"]["opendatahub.io/managed"] = "false"
    if here("no-annotations"): del meta["annotations"]
    if here("terminating"): meta["deletionTimestamp"] = "2026-01-01T00:00:00Z"
    if here("no-owners"): del meta["ownerReferences"]
    if here("owner-other-kind"): owner["kind"] = "Deployment"
    if here("owner-other-uid"): owner["uid"] = "other"
    if here("owner-not-controller"): owner["controller"] = False
    if here("owner-no-controller-flag"): del owner["controller"]
    if here("two-controllers"): meta["ownerReferences"].append({"kind": "Other", "name": "x", "uid": "y", "controller": True})
    if here("plain-second-owner"): meta["ownerReferences"].insert(0, {"kind": "Other", "name": "x", "uid": "y"})
    if here("no-resources"): del obj["spec"]["resources"]
    if here("no-limits"): del obj["spec"]["resources"]["limits"]
    return obj


def load(name):
    path = os.path.join(root, "state-" + name + ".json")
    if os.path.exists(path):
        text = open(path).read()
        return json.loads(text) if text else None
    return shipped(name)


def save(name, obj):
    open(os.path.join(root, "state-" + name + ".json"), "w").write(json.dumps(obj) if obj else "")


def pointer(doc, path):
    parts = [p.replace("~1", "/").replace("~0", "~") for p in path.split("/")[1:]]
    for part in parts[:-1]:
        doc = doc[part]
    return doc, parts[-1]


def emit(kind, obj):
    sys.stdout.write(json.dumps({"type": kind, "object": obj}) + "\n")
    sys.stdout.flush()


if watching:
    assert args[:3] == ["-n", "observability", "get"] and args[4] == "--field-selector" and args[5].startswith("metadata.name=") \
        and args[6:] == ["--watch", "--output-watch-events", "-o", "json"], "a collection watch filtered by name expected: " + line
    name = args[5].split("=", 1)[1]
    assert (args[3], name) in (("opentelemetrycollectors.opentelemetry.io", COLLECTOR), ("monitoringstacks.monitoring.rhobs", STACK)), line
    mine = lambda f: flag(f) and name == COLLECTOR      # the scripted trouble is on the collector's stream
    if mine("watch-fails-at-start"): sys.stderr.write("Unable to connect\n"); sys.exit(1)
    base = shipped(name)
    target = copy.deepcopy(base)
    target["metadata"].update(resourceVersion="101", annotations=dict(base["metadata"].get("annotations") or {}, **{"opendatahub.io/managed": "false"}))
    target["spec"]["resources"]["requests"]["memory"], target["spec"]["resources"]["limits"]["memory"] = WANT[name]
    if mine("watch-first-not-added"): emit("MODIFIED", base)
    if mine("watch-other-name"):
        other = copy.deepcopy(base); other["metadata"]["name"] = "something-else"; emit("ADDED", other)
    emit("ADDED", target if flag("watch-baseline-at-target") else base)
    time.sleep(0.3)
    if mine("watch-bookmark"): emit("BOOKMARK", {"metadata": {"resourceVersion": "100"}})
    if not flag("watch-baseline-at-target") and not flag("watch-never-target") and not (name == STACK and flag("watch-stack-never-target")):
        emit("MODIFIED", target)
    time.sleep(0.2)
    back = copy.deepcopy(base); back["metadata"]["resourceVersion"] = "102"
    if mine("watch-revert") or mine("watch-revert-reapply"): emit("MODIFIED", back)
    if mine("watch-revert-reapply"):
        again = copy.deepcopy(target); again["metadata"]["resourceVersion"] = "103"; emit("MODIFIED", again)
    if mine("watch-deleted"): emit("DELETED", target)
    if mine("watch-uid-change"):
        other = copy.deepcopy(target); other["metadata"].update(uid="uid-other", resourceVersion="900"); emit("ADDED", other)
    if mine("watch-error"): emit("ERROR", {"kind": "Status", "status": "Failure", "reason": "Expired", "code": 410})
    if mine("watch-truncated"): sys.stdout.write('{"type": "MODIFIED", "object": {"metadata"'); sys.stdout.flush(); sys.exit(0)
    if mine("watch-ends-early") or (name == STACK and flag("watch-stack-ends-early")): sys.exit(0)
    time.sleep(60)
    sys.exit(0)
if args[0] == "get" and "monitorings.services.platform.opendatahub.io" in args:
    if flag("monitoring-absent"): not_found("monitorings.services.platform.opendatahub.io \"default-monitoring\"")
    if flag("monitoring-unreadable") or (flag("monitoring-unreadable-after-patch") and patched_once): sys.stderr.write("timeout\n"); sys.exit(1)
    if flag("monitoring-partial"): print('{"metadata": {"uid"'); sys.exit(0)
    print(json.dumps(monitoring())); sys.exit(0)
if args[0] == "get":
    assert args[1:3] == ["-n", "observability"] and args[-2:] == ["-o", "json"], line
    resource, name = args[3], args[4]
    assert (resource, name) in (("opentelemetrycollectors.opentelemetry.io", COLLECTOR),
                                ("monitoringstacks.monitoring.rhobs", STACK)), line
    if flag("object-absent"): not_found(name)
    if flag("object-unreadable"): sys.stderr.write("timeout\n"); sys.exit(1)
    obj = load(name)
    if obj is None: not_found(name)
    print(json.dumps(obj)); sys.exit(0)
if args[:2] == ["-n", "observability"] and args[2] == "patch":
    resource, name = args[3], args[4]
    assert args[5] == "--type=json" and args[6] == "--patch-file" and args[8:] == ["-o", "json"], line
    patch = json.load(open(args[7]))
    n = count("patch-" + name)
    open(os.path.join(root, "patch-%s-%d.json" % (name, n)), "w").write(json.dumps(patch))
    obj = load(name)
    if (flag("changes-before-patch") and n == 1) or flag("changes-before-every-patch"):   # someone else wrote it after the read
        obj["metadata"]["resourceVersion"] = str(int(obj["metadata"]["resourceVersion"]) + 1); obj["spec"]["replicas"] = 3; save(name, obj)
    if flag("replaced-before-patch") and n == 1:       # a same-name object that the Monitoring does not control
        obj["metadata"].update(uid="uid-foreign", resourceVersion="500"); del obj["metadata"]["ownerReferences"]; save(name, obj)
    if flag("disappears-before-patch") and n == 1:
        save(name, None); obj = None
    if flag("patch-always-fails"): sys.stderr.write("Error from server (InternalError): try later\n"); sys.exit(1)
    if obj is None: not_found(name)
    new = copy.deepcopy(obj)
    for op in patch:
        parent, key = pointer(new, op["path"])
        if op["op"] == "test":
            if parent.get(key) != op["value"]:
                sys.stderr.write("The request is invalid: the server rejected our request due to an error in our request\n"); sys.exit(1)
        elif op["op"] == "add":
            parent[key] = op["value"]
        else:
            raise AssertionError("unexpected operation " + op["op"])
    if flag("patch-drops-cpu"): del new["spec"]["resources"]["limits"]["cpu"]
    if flag("patch-drops-owner"): del new["metadata"]["ownerReferences"]
    new["metadata"]["resourceVersion"] = str(int(obj["metadata"]["resourceVersion"]) + 1)
    save(name, new)
    if flag("patch-answer-lost-then-revert"):          # stored, the answer lost, and the module puts its values back
        back = copy.deepcopy(obj); back["metadata"]["resourceVersion"] = str(int(new["metadata"]["resourceVersion"]) + 1); save(name, back)
    if flag("patch-answer-lost") or flag("patch-answer-lost-then-revert"):
        sys.stderr.write("Unable to connect to the server: net/http: timeout awaiting response headers\n"); sys.exit(1)
    print(json.dumps(new))
    if flag("revert-after-patch"):                     # the module puts its own values back at once
        back = copy.deepcopy(obj); back["metadata"]["resourceVersion"] = str(int(new["metadata"]["resourceVersion"]) + 1); save(name, back)
    sys.exit(0)
sys.stderr.write("unexpected kubectl %s\n" % line)
sys.exit(3)
STUB
chmod +x "$work/bin/kubectl"
: > "$work/kubeconfig"

flags() {
  rm -f "$work"/flags/*
  local f
  for f in "$@"; do : > "$work/flags/$f"; done
}
run() {
  rm -f "$work"/state-*.json "$work"/n-* "$work"/patch-*.json "$work/record" "$work/ready"
  : > "$work/calls.log"
  rc=0
  local started=$SECONDS
  PATH="$work/bin:$PATH" STUB_ROOT="$work" KUBECONFIG="$work/kubeconfig" MONITORING_UID="${SITE_UID:-mon-uid}" \
    RECORD_FILE="${RECORD:-$work/record}" READY_FILE="$work/ready" bash "$script" "$@" > "$work/out" 2>&1 || rc=$?
  took=$((SECONDS - started))
}
patches() { grep -c ' patch ' "$work/calls.log" || true; }
field() { python3 -I -c 'import json, sys; o = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
records() { python3 -I -c 'import json, sys; print([eval(sys.argv[2]) for r in map(json.loads, open(sys.argv[1]))])' "$work/record" "$1"; }
C=data-science-collector
S=data-science-monitoringstack

flags; run check
is "check on the shipped objects exits 0" [ "$rc" = 0 ]
is "  it reports both patches" [ "$(grep -c '^would patch: observability/' "$work/out")" = 2 ]
is "  with the values" grep -q "$C (uid uid-$C) from 256Mi/256Mi/None to 2Gi/6Gi/false" "$work/out"
is "  sends no patch" [ "$(patches)" = 0 ]
is "  and writes no record" [ ! -e "$work/record" ]

flags; run apply
is "apply on the shipped objects exits 0" [ "$rc" = 0 ]
is "  one patch per object" [ "$(patches)" = 2 ]
is "  both acknowledged and read back" [ "$(grep -c 'patched (acknowledged at resourceVersion 101) and read back with its Monitoring' "$work/out")" = 2 ]
is "  the patch tests the UID and resourceVersion first" [ "$(field "$work/patch-$C-1.json" '[(p["op"], p["path"], p["value"]) for p in o[:2]]')" = "[('test', '/metadata/uid', 'uid-$C'), ('test', '/metadata/resourceVersion', '100')]" ]
is "  then adds the annotation and the two memory values, and nothing else" [ "$(field "$work/patch-$C-1.json" '[(p["op"], p["path"], p["value"]) for p in o[2:]]')" = "[('add', '/metadata/annotations/opendatahub.io~1managed', 'false'), ('add', '/spec/resources/requests/memory', '2Gi'), ('add', '/spec/resources/limits/memory', '6Gi')]" ]
is "  the stack gets its own values" [ "$(field "$work/patch-$S-1.json" '[p["value"] for p in o[3:]]')" = "['1Gi', '2Gi']" ]
is "  CPU, replicas and owner are untouched" [ "$(field "$work/state-$C.json" '(o["spec"]["resources"]["limits"]["cpu"], o["spec"]["resources"]["requests"]["cpu"], o["spec"]["replicas"], o["metadata"]["ownerReferences"][0]["uid"])')" = "(1, '100m', 2, 'mon-uid')" ]
is "  only get and patch were called" [ "$(grep -c -v -E '^--kubeconfig [^ ]+ --request-timeout=30s (get |-n observability patch )' "$work/calls.log" || true)" = 0 ]
is "  the record has, per object, what it was before the write and then the outcome" [ "$(records '(r["stage"], r["name"], r["uid"], r["resourceVersion"], r["before"]["request"], r["before"]["limit"], r["before"]["annotationPresent"], r["monitoringUID"])')" = "[('before', '$C', 'uid-$C', '100', '256Mi', '256Mi', False, 'mon-uid'), ('outcome', '$C', 'uid-$C', '100', '256Mi', '256Mi', False, 'mon-uid'), ('before', '$S', 'uid-$S', '100', '256Mi', '512Mi', False, 'mon-uid'), ('outcome', '$S', 'uid-$S', '100', '256Mi', '512Mi', False, 'mon-uid')]" ]
is "  with the acknowledged resourceVersion in the outcome" [ "$(records '(r["outcome"], r.get("acknowledgedResourceVersion"))')" = "[('patch attempt 1', None), ('patched by this run', '101'), ('patch attempt 1', None), ('patched by this run', '101')]" ]

flags already-set; run apply
is "apply on objects that are already set exits 0" [ "$rc" = 0 ]
is "  says so twice" [ "$(grep -c 'already has' "$work/out")" = 2 ]
is "  sends no patch" [ "$(patches)" = 0 ]
is "  and records that this run changed nothing" [ "$(records '(r["stage"], r["before"]["annotation"], r["outcome"])')" = "[('outcome', 'false', 'already as wanted; not changed by this run'), ('outcome', 'false', 'already as wanted; not changed by this run')]" ]

flags collector-already-set; run apply
is "apply patches only the object that differs" [ "$rc" = 0 ]
is "  one patch, for the stack" [ "$(patches)" = 1 ] && is "  (the stack's)" [ -e "$work/patch-$S-1.json" ]

flags opted-out; run apply
is "an object that already carried the opt-out gets the memory" [ "$rc" = 0 ]
is "  and the record keeps that the annotation was there before, with its value" [ "$(records '(r["stage"], r["before"]["annotationPresent"], r["before"]["annotation"], r["before"]["limit"])')" = "[('before', True, 'false', '256Mi'), ('outcome', True, 'false', '256Mi'), ('before', True, 'false', '512Mi'), ('outcome', True, 'false', '512Mi')]" ]

flags no-annotations; run apply
is "apply on an object without annotations exits 0" [ "$rc" = 0 ]
is "  and adds the annotations map" [ "$(field "$work/patch-$C-1.json" '(o[2]["path"], o[2]["value"])')" = "('/metadata/annotations', {'opendatahub.io/managed': 'false'})" ]

flags plain-second-owner; run apply
is "a second, plain owner does not hide the controlling Monitoring" [ "$rc" = 0 ]
is "  both patched" [ "$(patches)" = 2 ]

flags patch-answer-lost; run apply
is "a patch that was stored although its answer was lost is recognised" [ "$rc" = 0 ]
is "  it is not sent twice" [ "$(patches)" = 2 ]
is "  and the record says that the state is verified but the writer is not established" [ "$(records 'r["outcome"]')" = "['patch attempt 1', 'as wanted after a patch without an answer: the state is verified, the writer is not established; read back at resourceVersion 101', 'patch attempt 1', 'as wanted after a patch without an answer: the state is verified, the writer is not established; read back at resourceVersion 101']" ]

flags patch-answer-lost-then-revert; run apply
is "a stored patch whose answer was lost and that was reverted stops the run" [ "$rc" = 1 ]
is "  one patch attempt, and no write to the second object" [ "$(patches)" = 1 ] && is "  (none for the stack)" [ ! -e "$work/patch-$S-1.json" ]
is "  it says that it has no answer and does not write again" grep -q "the patch has no answer and the object is not the intended result (now 256Mi/256Mi/None at resourceVersion 102); not written again" "$work/out"
is "  and the record keeps the attempt as unresolved" [ "$(records '(r["stage"], r["outcome"][:10])')" = "[('before', 'patch atte'), ('outcome', 'unresolved')]" ]

for case in "monitoring-absent|there is no Monitoring default-monitoring" "monitoring-unreadable|the Monitoring could not be read" \
            "monitoring-partial|the Monitoring could not be read" "monitoring-terminating|the Monitoring is terminating" \
            "monitoring-no-namespace|the Monitoring names no namespace" "monitoring-no-uid|this is not the intended site" \
            "object-absent|is absent; this script never creates it" "object-unreadable|could not be read" \
            "terminating|the object is terminating" "no-owners|the site's Monitoring does not control the object" \
            "owner-other-kind|the site's Monitoring does not control the object" "owner-other-uid|the site's Monitoring does not control the object" \
            "owner-not-controller|the site's Monitoring does not control the object" "owner-no-controller-flag|the site's Monitoring does not control the object" \
            "two-controllers|the site's Monitoring does not control the object" "no-resources|no resource requests and limits to patch" \
            "no-limits|no resource requests and limits to patch"; do
  for mode in check apply; do
    flags "${case%%|*}"; run "$mode"
    is "$mode refuses with ${case%%|*}" [ "$rc" = 1 ]
    is "  with the reason, at the first object" [ "$(grep -c "^refused: .*${case#*|}" "$work/out")" = 1 ]
    is "  sends no patch" [ "$(patches)" = 0 ]
    is "  and writes no record" [ ! -e "$work/record" ]
  done
done

for mode in check apply; do
  flags; SITE_UID=another-site run "$mode"
  is "$mode refuses a site whose Monitoring has another UID" [ "$rc" = 1 ]
  is "  with the reason" grep -q "refused: this is not the intended site: its Monitoring has UID mon-uid" "$work/out"
  is "  and sends no patch" [ "$(patches)" = 0 ]
done

flags stack-no-owners; run apply
is "a refusal at the second object fails the run" [ "$rc" = 1 ]
is "  after the first was patched and recorded" [ "$(patches)" = 1 ] && is "  (its two record lines)" [ "$(records '(r["name"], r["stage"])')" = "[('$C', 'before'), ('$C', 'outcome')]" ]
flags collector-no-owners; run apply
is "a refusal at the first object stops before the second" [ "$rc" = 1 ]
is "  no patch at all" [ "$(patches)" = 0 ]
is "  and it says that nothing further was written" grep -q "^stopped: nothing further was written" "$work/out"

flags changes-before-patch; run apply
is "an object that changed after the read is read and patched again" [ "$rc" = 0 ]
is "  two patches per object" [ "$(patches)" = 4 ]
is "  the first tested the old resourceVersion" [ "$(field "$work/patch-$C-1.json" 'o[1]["value"]')" = 100 ]
is "  the second the new one" [ "$(field "$work/patch-$C-2.json" 'o[1]["value"]')" = 101 ]
is "  the other writer's change survived" [ "$(field "$work/state-$C.json" 'o["spec"]["replicas"]')" = 3 ]
is "  and both attempts are in the record with the version they tested" [ "$(records '(r["name"], r["stage"], r["resourceVersion"])' | grep -o "'$C', 'before', '10[01]'" | tr '\n' ' ')" = "'$C', 'before', '100' '$C', 'before', '101' " ]

flags changes-before-every-patch; run apply
is "an object that keeps changing fails after three patches" [ "$rc" = 1 ]
is "  three patches for the first object and none for the second" [ "$(patches)" = 3 ] && is "  (none for the stack)" [ ! -e "$work/patch-$S-1.json" ]
is "  it says so" grep -q "three patches met a changed object" "$work/out"
is "  and the record ends with the unresolved outcome" [ "$(records 'r["outcome"][:10]' | grep -c "unresolved")" = 1 ]

flags replaced-before-patch; run apply
is "a same-name replacement that the Monitoring does not control is refused" [ "$rc" = 1 ]
is "  after one rejected patch, and the second object is not touched" [ "$(patches)" = 1 ]
is "  with the reason" grep -q "^refused: .*the site's Monitoring does not control the object" "$work/out"
is "  the record keeps the attempt and that it is unresolved" [ "$(records '(r["stage"], r["outcome"][:10])')" = "[('before', 'patch atte'), ('outcome', 'unresolved')]" ]
is "  and the replacement is untouched" [ "$(field "$work/state-$C.json" '(o["metadata"]["uid"], o["metadata"]["resourceVersion"], o["metadata"]["annotations"].get("opendatahub.io/managed"), o["spec"]["resources"]["limits"]["memory"])')" = "('uid-foreign', '500', None, '256Mi')" ]

flags disappears-before-patch; run apply
is "an object that disappears before the patch is not recreated" [ "$rc" = 1 ]
is "  after one rejected patch" [ "$(patches)" = 1 ]
is "  it is reported absent" grep -q 'is absent; this script never creates it' "$work/out"
is "  and stays absent" [ ! -s "$work/state-$C.json" ]

flags patch-always-fails; run apply
is "a patch that gets a server error and is not in place is not repeated" [ "$rc" = 1 ]
is "  one patch, none for the second object" [ "$(patches)" = 1 ] && is "  (none for the stack)" [ ! -e "$work/patch-$S-1.json" ]
is "  and it says so" grep -q 'the patch has no answer and the object is not the intended result' "$work/out"

flags revert-after-patch; run apply
is "an acknowledged patch that is reverted at once stops the run" [ "$rc" = 1 ]
is "  it is not written again, and the second object gets no write" [ "$(patches)" = 1 ]
is "  it says so" grep -q "the acknowledged patch is not in place (now 256Mi/256Mi/None at resourceVersion 102); not written again" "$work/out"
is "  and the record keeps the before-state and the unresolved outcome" [ "$(records '(r["stage"], r["before"]["limit"], r["outcome"][:10])')" = "[('before', '256Mi', 'patch atte'), ('outcome', '256Mi', 'unresolved')]" ]

flags namespace-changes-after-patch; run apply
is "a Monitoring that names another namespace after the patch stops the run" [ "$rc" = 1 ]
is "  with the reason" grep -q "refused: the Monitoring now names namespace elsewhere, not observability" "$work/out"
is "  and nothing more is written" [ "$(patches)" = 1 ]

flags monitoring-unreadable-after-patch; run apply
is "an accepted patch followed by a failed read fails the run" [ "$rc" = 1 ]
is "  the record still has what the object was before that write" [ "$(records '(r["stage"], r["uid"], r["resourceVersion"], r["before"]["request"], r["before"]["limit"], r["before"]["annotationPresent"])' | grep -c "('before', 'uid-$C', '100', '256Mi', '256Mi', False)")" = 1 ]
is "  and that it is unresolved" [ "$(records 'r["outcome"][:10]' | grep -c unresolved)" = 1 ]
is "  the second object gets no write" [ "$(patches)" = 1 ]

flags; RECORD="$work/no-such-directory/record" run apply
is "a record that cannot be written prevents the patch" [ "$rc" = 1 ]
is "  no patch was sent" [ "$(patches)" = 0 ]
is "  and it says so" grep -q "could not be written; nothing was patched" "$work/out"

for case in "patch-drops-cpu" "patch-drops-owner"; do
  flags "$case"; run apply
  is "a stored result that is more than the patch ($case) fails" [ "$rc" = 1 ]
  is "  it says so" grep -q "the acknowledged patch is not in place\|does not control the object" "$work/out"
  is "  and the second object gets no write" [ "$(patches)" = 1 ]
done

for case in "monitoring-replaced-after-patch|this is not the intended site" "monitoring-terminating-after-patch|the Monitoring is terminating"; do
  flags "${case%%|*}"; run apply
  is "a Monitoring that changed while the object was patched (${case%%|*}) fails the run" [ "$rc" = 1 ]
  is "  with the reason" grep -q "refused: ${case#*|}" "$work/out"
  is "  and the second object gets no write" [ "$(patches)" = 1 ]
done

flags; run watch 3
is "watch passes when both objects reach and keep the wanted values" [ "$rc" = 0 ]
is "  it reported READY after both baselines" grep -q "READY: both baselines are in ($C=uid-$C@100 $S=uid-$S@100)" "$work/out"
is "  wrote the ready file with both UIDs and baseline versions" [ "$(cat "$work/ready")" = "$C=uid-$C@100 $S=uid-$S@100" ]
is "  printed each event with UID, resourceVersion and values" grep -q "$C MODIFIED uid=uid-$C rv=101 gen=None 2Gi/6Gi/false" "$work/out"
is "  ran for the asked time" [ "$took" -ge 3 ]
flags watch-baseline-at-target; run watch 2
is "watch passes on objects that are already at the wanted values" [ "$rc" = 0 ]
flags watch-bookmark; run watch 2
is "watch ignores a bookmark" [ "$rc" = 0 ]
flags watch-never-target; run watch 2
is "watch fails when the wanted values never appear" [ "$rc" = 1 ]
is "  and names both objects" grep -q "WATCH FAILED: the wanted values were never seen on: $C, $S" "$work/out"
flags watch-stack-never-target; run watch 2
is "watch fails when one object never shows the wanted values" [ "$rc" = 1 ]
is "  and names it" grep -q "WATCH FAILED: the wanted values were never seen on: $S" "$work/out"
for case in "watch-revert|REVERTED to 256Mi/256Mi/None" "watch-revert-reapply|REVERTED to 256Mi/256Mi/None" "watch-deleted|a DELETED event" \
            "watch-uid-change|another object under the name (uid uid-other)" "watch-error|a ERROR event" \
            "watch-ends-early|the stream ended early (kubectl exit 0)" "watch-truncated|the stream ended early with truncated data" \
            "watch-fails-at-start|the stream ended early (kubectl exit 1)" "watch-first-not-added|the first event is not the baseline" \
            "watch-other-name|an event for something-else"; do
  flags "${case%%|*}"; run watch 20
  is "watch fails on ${case%%|*}" [ "$rc" = 1 ]
  is "  with the reason" grep -qF "WATCH FAILED: $C: ${case#*|}" "$work/out"
  is "  at once, not at the end of the window" [ "$took" -lt 10 ]
done
flags watch-stack-ends-early; run watch 20
is "watch fails at once when the second stream ends early" [ "$rc" = 1 ] && is "  (promptly)" [ "$took" -lt 10 ]
is "  and names that stream" grep -qF "WATCH FAILED: $S: the stream ended early" "$work/out"
flags watch-fails-at-start; run watch 20
is "no ready file without both baselines" [ ! -e "$work/ready" ]
flags; SITE_UID=another-site run watch 2
is "watch refuses another site" [ "$rc" = 1 ] && is "  (with the reason)" grep -q "this is not the intended site" "$work/out"

flags; run
is "no argument prints the usage and exits 2" [ "$rc" = 2 ]
is "  without a kubectl call" [ ! -s "$work/calls.log" ]
flags; run apply now
is "an extra argument exits 2" [ "$rc" = 2 ]
flags; run delete
is "an unknown action exits 2" [ "$rc" = 2 ]
flags; run watch 0
is "watch with a zero duration exits 2" [ "$rc" = 2 ]
quiet() {
  : > "$work/calls.log"
  rc=0
  PATH="$work/bin:$PATH" STUB_ROOT="$work" env "$@" bash "$script" apply > "$work/out" 2>&1 || rc=$?
}
quiet -u KUBECONFIG MONITORING_UID=mon-uid RECORD_FILE="$work/record"
is "apply without KUBECONFIG exits 1" [ "$rc" = 1 ] && is "  (before any request)" [ ! -s "$work/calls.log" ]
quiet KUBECONFIG="$work/missing" MONITORING_UID=mon-uid RECORD_FILE="$work/record"
is "apply with a kubeconfig that is not a file exits 1" [ "$rc" = 1 ] && is "  (before any request)" [ ! -s "$work/calls.log" ]
quiet KUBECONFIG="$work/kubeconfig:$work/kubeconfig" MONITORING_UID=mon-uid RECORD_FILE="$work/record"
is "apply with a kubeconfig list exits 1" [ "$rc" = 1 ]
quiet -u MONITORING_UID KUBECONFIG="$work/kubeconfig" RECORD_FILE="$work/record"
is "apply without MONITORING_UID exits 1" [ "$rc" = 1 ] && is "  (before any request)" [ ! -s "$work/calls.log" ]
quiet -u RECORD_FILE KUBECONFIG="$work/kubeconfig" MONITORING_UID=mon-uid
is "apply without RECORD_FILE exits 1" [ "$rc" = 1 ] && is "  (before any request)" [ ! -s "$work/calls.log" ]

echo "passed $pass, failed $fail"
[[ $fail == 0 ]]
