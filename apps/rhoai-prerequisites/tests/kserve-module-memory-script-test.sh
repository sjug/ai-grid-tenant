#!/usr/bin/env bash
# Stub tests for set-kserve-module-memory.sh against a fake kubectl that applies JSON Patch test operations like the API
# server and rolls the Deployment's pods a few reads after a patch (RHOAIENG-103335). Needs python3. No cluster is contacted.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../set-kserve-module-memory.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env python3
import json
import os
import sys

root = os.environ["STUB_ROOT"]
flag = lambda name: os.path.exists(os.path.join(root, name))
open(os.path.join(root, "calls.log"), "a").write(" ".join(sys.argv[1:]) + "\n")
if sys.stdin.read() != "":
    open(os.path.join(root, "stdin-read"), "w").write("x")
args = sys.argv[1:]
assert args[:2] == ["--kubeconfig", os.path.join(root, "kubeconfig")], "every call must name the site's kubeconfig"
assert args[2] == "--request-timeout=30s", "every request must be bounded"
args = args[3:]
path = os.path.join(root, "deployment.json")


def count(name):
    p = os.path.join(root, "n-" + name)
    n = int(open(p).read()) + 1 if os.path.exists(p) else 1
    open(p, "w").write(str(n))
    return n


def manager(d):
    return [c for c in d["spec"]["template"]["spec"]["containers"] if c["name"] == "manager"][0]


if args[0] == "get" and "deployment" in args:
    if not os.path.exists(path):
        sys.stderr.write('Error from server (NotFound): deployments.apps "kserve-module-controller-manager" not found\n')
        sys.exit(1)
    d = json.load(open(path))
    if flag("patched"):
        n = count("deployment-reads")
        if flag("reverted") and n >= 2:
            manager(d)["resources"]["limits"]["memory"] = "1Gi"
        if flag("reordered") and n >= 2:
            m = manager(d)
            m["resources"]["limits"]["memory"] = "1Gi"
            d["spec"]["template"]["spec"]["containers"] = [{"name": "sidecar", "resources": {"limits": {"memory": "2Gi"}}}, m]
        if flag("never-rolls") or n < 2:
            d["status"]["updatedReplicas"] = 0
        if flag("slow-after-roll") and n >= 2:
            import time
            time.sleep(3)
    print(json.dumps(d))
    sys.exit(0)
if args[0] == "get" and "pods" in args:
    patched = flag("patched")
    n = count("pod-reads") if patched else 0
    if flag("timeout-once") and n == 1:
        sys.exit(124)
    new = patched and n >= 2 and not flag("never-rolls")
    restarts = 1 if (flag("restarts") and n >= 4) else 0
    pod = {"metadata": {"name": "kmc-new" if new else "kmc-old", "uid": "pod-new" if new else "pod-old"},
           "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                      "containerStatuses": [{"name": "manager", "restartCount": restarts if new else 5}]}}
    print(json.dumps({"items": [pod]}))
    sys.exit(0)
if args[0] == "-n" and args[2] == "patch":
    open(os.path.join(root, "n-patches"), "a").write("x")
    d = json.load(open(path))
    if flag("raced"):
        d["metadata"]["resourceVersion"] = "999"
    ops = json.load(open([a.split("=", 1)[1] for a in args if a.startswith("--patch-file=")][0]))
    for op in ops:
        target = d
        parts = op["path"].strip("/").split("/")
        for part in parts[:-1]:
            target = target[int(part)] if isinstance(target, list) else target[part]
        last = parts[-1]
        value = target[int(last)] if isinstance(target, list) else target.get(last)
        if op["op"] == "test" and value != op["value"]:
            sys.stderr.write("The request is invalid: the server rejected our request due to an error in our request\n")
            sys.exit(1)
    i = [n for n, c in enumerate(d["spec"]["template"]["spec"]["containers"]) if c["name"] == "manager"][0]
    expected = [{"op": "test", "path": "/metadata/uid", "value": "dep-uid"},
                {"op": "test", "path": "/metadata/resourceVersion", "value": "100"},
                {"op": "test", "path": "/spec/template/spec/containers/%d/name" % i, "value": "manager"},
                {"op": "test", "path": "/spec/template/spec/containers/%d/resources/limits/memory" % i, "value": "1Gi"},
                {"op": "replace", "path": "/spec/template/spec/containers/%d/resources/limits/memory" % i, "value": "2Gi"}]
    if ops != expected:
        open(os.path.join(root, "unexpected-patch"), "w").write(json.dumps(ops))
        sys.exit(4)
    d["spec"]["template"]["spec"]["containers"][i]["resources"]["limits"]["memory"] = "2Gi"
    d["metadata"]["generation"] += 1
    d["status"]["observedGeneration"] = d["metadata"]["generation"]
    json.dump(d, open(path, "w"))
    open(os.path.join(root, "patched"), "w").write("x")
    print("deployment.apps/kserve-module-controller-manager patched")
    sys.exit(0)
sys.exit(3)
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH" STUB_ROOT="$work" KUBECONFIG="$work/kubeconfig" PLATFORM_UID=platform-uid POLL=0.05 STABLE=1 WAIT=5
touch "$work/kubeconfig"

reset() {
  find "$work" -maxdepth 1 -type f ! -name kubeconfig -delete
  python3 - "$work/deployment.json" "$@" <<'PY'
import json
import sys

d = {"metadata": {"name": "kserve-module-controller-manager", "namespace": "redhat-ods-applications", "uid": "dep-uid",
                  "resourceVersion": "100", "generation": 9, "annotations": {},
                  "ownerReferences": [{"apiVersion": "config.opendatahub.io/v1alpha2", "kind": "Platform",
                                       "name": "default", "uid": "platform-uid", "controller": True}]},
     "spec": {"replicas": 1, "selector": {"matchLabels": {"control-plane": "kserve-module-controller-manager"}},
              "template": {"spec": {"containers": [{"name": "manager", "resources": {
                  "limits": {"cpu": "500m", "memory": "1Gi"}, "requests": {"cpu": "100m", "memory": "256Mi"}}}]}}},
     "status": {"observedGeneration": 9, "replicas": 1, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1}}
for change in sys.argv[2:]:
    if change == "limit-2Gi": d["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["memory"] = "2Gi"
    if change == "limit-other": d["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["memory"] = "1536Mi"
    if change == "managed": d["metadata"]["annotations"]["opendatahub.io/managed"] = "true"
    if change == "foreign": d["metadata"]["ownerReferences"][0]["uid"] = "other"
    if change == "terminating": d["metadata"]["deletionTimestamp"] = "2026-01-01T00:00:00Z"
    if change == "two-managers": d["spec"]["template"]["spec"]["containers"].append({"name": "manager"})
    if change == "manager-second": d["spec"]["template"]["spec"]["containers"].insert(0, {"name": "sidecar", "resources": {"limits": {"memory": "64Mi"}}})
json.dump(d, open(sys.argv[1], "w"))
PY
}
run() { "$script" "$@" > "$work/out" 2> "$work/err"; echo $?; }
patches() { [ -e "$work/n-patches" ] && wc -c < "$work/n-patches" | tr -d ' ' || echo 0; }
limit() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["memory"])' "$work/deployment.json"; }

reset; rc=$(run check)
[ "$rc" = 0 ] && grep -q "memory limit 1Gi -> 2Gi" "$work/out" && [ "$(patches)" = 0 ] && ok "check reports the change and patches nothing" || bad "check rc=$rc $(cat "$work/err")"

reset; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 0 ] && [ "$(limit)" = 2Gi ] && grep -q "done: the manager memory limit is 2Gi" "$work/out" && ok "apply patches, waits for the new pod and the stable window" || bad "apply rc=$rc $(cat "$work/err")"
[ "$(patches)" = 1 ] && ok "exactly one patch" || bad "patches $(patches)"
python3 - "$work/record.jsonl" <<'PY' && ok "record: before, patched, done" || bad "record $(cat "$work/record.jsonl")"
import json, sys
events = [json.loads(l)["event"] for l in open(sys.argv[1])]
assert events == ["before", "patched", "done"], events
PY
[ ! -e "$work/unexpected-patch" ] && ok "the patch is exactly the five expected operations" || bad "unexpected patch $(cat "$work/unexpected-patch")"
[ ! -e "$work/stdin-read" ] && ok "no call read stdin" || bad "a call read stdin"

reset limit-2Gi; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 0 ] && grep -q "nothing to do" "$work/out" && [ "$(patches)" = 0 ] && [ ! -e "$work/record.jsonl" ] && ok "already 2Gi: nothing to do, nothing recorded" || bad "rc=$rc"

for change in limit-other managed foreign terminating two-managers; do
  reset "$change"; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
  [ "$rc" = 1 ] && grep -q "refused" "$work/err" && [ "$(patches)" = 0 ] && ok "$change: refused before any patch" || bad "$change: rc=$rc $(cat "$work/err")"
done

reset; rm "$work/deployment.json"; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 1 ] && grep -q "there is no Deployment" "$work/err" && [ "$(patches)" = 0 ] && ok "absent Deployment: refused" || bad "absent rc=$rc"

reset; rc=$(RECORD_FILE="$work/nodir/record.jsonl" run apply)
[ "$rc" = 1 ] && grep -q "nothing was changed" "$work/err" && [ "$(patches)" = 0 ] && ok "unwritable record: no patch" || bad "record rc=$rc $(cat "$work/err")"

reset; touch "$work/raced"; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 1 ] && grep -q "patch failed or its outcome is unknown" "$work/err" && [ "$(patches)" = 1 ] && [ "$(limit)" = 1Gi ] && ok "a write in between: the patch is rejected and not repeated" || bad "raced rc=$rc"

reset; touch "$work/reverted"; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 1 ] && grep -q "something reverted it" "$work/err" && ok "a reverted limit fails" || bad "reverted rc=$rc $(cat "$work/err")"

reset; touch "$work/restarts"; rc=$(STABLE=2 RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 1 ] && grep -q "restarted or was replaced" "$work/err" && ok "a restart in the stable window fails" || bad "restarts rc=$rc $(cat "$work/err")"

reset manager-second; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 0 ] && [ ! -e "$work/unexpected-patch" ] && ok "a manager at index 1 is patched at its index and verified by name" || bad "manager-second rc=$rc $(cat "$work/err")"

reset; touch "$work/reordered"; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 1 ] && grep -q "something reverted it" "$work/err" && ok "reordered containers with a 2Gi sidecar at the old index and a 1Gi manager fail" || bad "reordered rc=$rc $(cat "$work/err")"

reset; touch "$work/timeout-once"; rc=$(RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 0 ] && ok "a read that times out while time is left is retried, then success" || bad "timeout-once rc=$rc $(cat "$work/err")"

reset; touch "$work/slow-after-roll"; rc=$(WAIT=2 RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 1 ] && grep -q "not rolled out after 2 s" "$work/err" && ok "a rollout seen only after the deadline fails" || bad "slow-after-roll rc=$rc $(cat "$work/err")"

reset; touch "$work/never-rolls"; rc=$(WAIT=1 RECORD_FILE="$work/record.jsonl" run apply)
[ "$rc" = 1 ] && grep -q "not rolled out after 1 s" "$work/err" && ok "a rollout that never completes times out" || bad "never-rolls rc=$rc $(cat "$work/err")"

reset
rc1=$(run); rc2=$(run apply extra); rc3=$(KUBECONFIG= run check); rc4=$(PLATFORM_UID= run check); rc5=$(run apply); rc6=$(POLL=inf run check); rc7=$(STABLE=0 run check)
[ "$rc1$rc2" = 22 ] && [ "$rc3$rc4$rc5$rc6$rc7" = 11111 ] && [ "$(patches)" = 0 ] && ok "usage and environment errors change nothing" || bad "usage $rc1$rc2$rc3$rc4$rc5$rc6$rc7"

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
