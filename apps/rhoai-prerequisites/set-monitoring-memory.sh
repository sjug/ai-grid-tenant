#!/usr/bin/env bash
# Memory headroom for RHOAI's metrics collector and Prometheus on one site (RHOAIENG-104114).
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Raise the memory of RHOAI's metrics collector and Prometheus on one site, and mark both custom resources
opendatahub.io/managed: "false" so that RHOAI's observability module leaves them alone.
See apps/rhoai-prerequisites/README.md, "Monitoring memory headroom".

Usage:
  set-monitoring-memory.sh check            report what would change; changes nothing
  set-monitoring-memory.sh apply            patch what differs, then read parent and object back
  set-monitoring-memory.sh watch [seconds]  follow every change of both objects for that long (default 1800)

Required environment:
  KUBECONFIG      The site's kubeconfig, a readable file. It is passed to every request.
  MONITORING_UID  The UID of that site's Monitoring default-monitoring, read beforehand on the site that is meant.
                  Every action refuses a cluster whose Monitoring has another UID.
Environment for apply:
  RECORD_FILE     Required. JSON lines are appended: before each write the object's UID, resourceVersion, memory
                  and annotation as they were, and afterwards the outcome. A write is not attempted unless its
                  line could be written. Roll back from this record.
Environment for watch:
  READY_FILE      Optional. Created once both streams have delivered the objects' current state.

apply only patches an existing object, with one JSON Patch that first tests the object's UID and resourceVersion,
so the API server changes nothing unless that object is still as it was read; nothing is created. It patches only
while the Monitoring controls the object and neither is terminating. It stops at the first object it cannot bring
to the wanted state and read back, and when an object or the Monitoring's namespace is no longer the one it
started with or a write that the API server acknowledged is not in place afterwards.
Exit 0: nothing to do, or done and verified. 1: refused or failed; the reason is printed. 2: usage.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# resource, name, memory request, memory limit. The collector limit clears its shipped limiter's 4000 MiB.
targets=(
  "opentelemetrycollectors.opentelemetry.io data-science-collector 2Gi 6Gi"
  "monitoringstacks.monitoring.rhobs data-science-monitoringstack 1Gi 2Gi"
)
monitoring_resource=monitorings.services.platform.opendatahub.io
annotation=opendatahub.io/managed

action="${1:-}"
case "$action" in
  check | apply) [ $# -eq 1 ] || { usage >&2; exit 2; } ;;
  watch) [ $# -le 2 ] && [[ ${2:-1800} =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
kubeconfig="${KUBECONFIG:-}"
[ -n "$kubeconfig" ] && [ -f "$kubeconfig" ] && [ -r "$kubeconfig" ] || die "KUBECONFIG must name the site's kubeconfig, one readable file"
expected_parent="${MONITORING_UID:-}"
[ -n "$expected_parent" ] || die "MONITORING_UID must hold the UID of the intended site's Monitoring"
record="${RECORD_FILE:-}"
[ "$action" != apply ] || [ -n "$record" ] || die "RECORD_FILE must name the file that records what apply changes"
for required_command in kubectl python3; do
  command -v "$required_command" > /dev/null 2>&1 || die "required command not found: $required_command"
done
work="$(mktemp -d)" || die "no temporary directory"
trap 'rm -rf "$work"' EXIT

kube() {
  kubectl --kubeconfig "$kubeconfig" --request-timeout=30s "$@"
}

# read_json <file> <kubectl get arguments>: a complete answer in <file> (status 0), absent (1) or unreadable (2).
read_json() {
  local file=$1
  shift
  if kube get "$@" -o json > "$file.tmp" 2> "$file.err"; then
    python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$file.tmp" 2> /dev/null || return 2
    mv "$file.tmp" "$file" || return 2
    return 0
  fi
  if grep -q 'NotFound' "$file.err"; then return 1; fi
  return 2
}

# read_parent: the Monitoring into $work/monitoring.json and its namespace into $namespace; status 1 with a reason
# unless it is the intended site's, is not terminating and names the namespace that the first read of this run found.
read_parent() {
  local rc=0 verdict
  read_json "$work/monitoring.json" "$monitoring_resource" default-monitoring || rc=$?
  if [ "$rc" = 1 ]; then echo "refused: there is no Monitoring default-monitoring"; return 1; fi
  if [ "$rc" != 0 ]; then echo "refused: the Monitoring could not be read"; return 1; fi
  verdict="$(python3 -I - "$work/monitoring.json" "$expected_parent" <<'PY'
import json
import sys

meta = json.load(open(sys.argv[1])).get("metadata") or {}
spec = json.load(open(sys.argv[1])).get("spec") or {}
if meta.get("uid") != sys.argv[2]:
    print("no this is not the intended site: its Monitoring has UID %s" % meta.get("uid"))
elif meta.get("deletionTimestamp"):
    print("no the Monitoring is terminating")
elif not spec.get("namespace"):
    print("no the Monitoring names no namespace")
else:
    print("ok " + spec["namespace"])
PY
  )" || { echo "refused: the Monitoring could not be assessed"; return 1; }
  if [ "${verdict%% *}" != ok ]; then echo "refused: ${verdict#no }"; return 1; fi
  if [ -n "$namespace" ] && [ "$namespace" != "${verdict#ok }" ]; then
    echo "refused: the Monitoring now names namespace ${verdict#ok }, not $namespace"
    return 1
  fi
  namespace="${verdict#ok }"
}

# assess <object.json> <request> <limit> [<before.json>]
#   "refuse <reason>" | "same <uid> <rv>" | "patch <uid> <rv> <map|none> <now>" | "done <uid> <rv>"
# With <before.json> it answers "done" when the object is exactly that earlier state with the patch applied.
assess() {
  python3 -I - "$work/monitoring.json" "$annotation" "$@" <<'PY'
import copy
import json
import sys

monitoring = json.load(open(sys.argv[1]))
annotation, live, request, limit = sys.argv[2], json.load(open(sys.argv[3])), sys.argv[4], sys.argv[5]
before = json.load(open(sys.argv[6])) if len(sys.argv) > 6 else None


def out(*words):
    print(" ".join(words))
    sys.exit(0)


parent, meta = monitoring["metadata"], live.get("metadata") or {}
if not meta.get("uid") or not meta.get("resourceVersion"):
    out("refuse", "the object has no UID or resourceVersion")
if meta.get("deletionTimestamp"):
    out("refuse", "the object is terminating")
controllers = [o for o in meta.get("ownerReferences") or [] if o.get("controller") is True]
if len(controllers) != 1 or controllers[0].get("kind") != "Monitoring" or controllers[0].get("uid") != parent["uid"]:
    out("refuse", "the site's Monitoring does not control the object")
resources = (live.get("spec") or {}).get("resources")
if not isinstance(resources, dict) or not all(isinstance(resources.get(k), dict) for k in ("requests", "limits")):
    out("refuse", "the object has no resource requests and limits to patch")
annotations = meta.get("annotations")
now = "%s/%s/%s" % (resources["requests"].get("memory"), resources["limits"].get("memory"),
                    (annotations or {}).get(annotation))
if before is not None:
    want = copy.deepcopy(before["spec"]["resources"])
    want["requests"]["memory"], want["limits"]["memory"] = request, limit
    if (meta["uid"] == before["metadata"]["uid"] and (annotations or {}).get(annotation) == "false"
            and resources == want and meta.get("ownerReferences") == before["metadata"].get("ownerReferences")):
        out("done", meta["uid"], meta["resourceVersion"])
if now == "%s/%s/false" % (request, limit):
    out("same", meta["uid"], meta["resourceVersion"])
out("patch", meta["uid"], meta["resourceVersion"], "map" if isinstance(annotations, dict) else "none", now)
PY
}

# read_object <resource> <name>: into $work/object.json; status 1 with a reason when absent or unreadable.
read_object() {
  local rc=0
  read_json "$work/object.json" -n "$namespace" "$1" "$2" || rc=$?
  if [ "$rc" = 1 ]; then echo "refused: $namespace/$2 is absent; this script never creates it"; return 1; fi
  if [ "$rc" != 0 ]; then echo "refused: $namespace/$2 could not be read"; return 1; fi
}

# log_line <stage> <name> <outcome> [<acknowledged resourceVersion>]: one JSON line in the record, from the object as it
# was read ($work/before.json). Stage "before" is written ahead of a write, "outcome" when the object is settled.
log_line() {
  python3 -I - "$work/before.json" "$annotation" "$expected_parent" "$@" >> "$record" <<'PY'
import json
import sys
import time

before, annotation, parent, stage, name, outcome = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
resources, annotations = before["spec"]["resources"], before["metadata"].get("annotations") or {}
line = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "stage": stage, "monitoringUID": parent, "name": name,
        "namespace": before["metadata"].get("namespace"), "uid": before["metadata"]["uid"],
        "resourceVersion": before["metadata"]["resourceVersion"],
        "before": {"request": resources["requests"].get("memory"), "limit": resources["limits"].get("memory"),
                   "annotationPresent": annotation in annotations, "annotation": annotations.get(annotation)},
        "outcome": outcome}
if len(sys.argv) > 7:
    line["acknowledgedResourceVersion"] = sys.argv[7]
print(json.dumps(line))
PY
}

# unresolved <name> <message>: say why the object is not settled and keep that in the record, then fail.
unresolved() {
  echo "$2"
  log_line outcome "$1" "unresolved: $2" || echo "the record could not be written either"
  return 1
}

# one <resource> <name> <request> <limit>: bring one object to the wanted state. Status 0: done or nothing to do,
# and in apply mode verified. 1: refused or failed.
one() {
  local resource=$1 name=$2 request=$3 limit=$4 verdict kind uid version shape now pinned tested tries=0 acknowledged rejected
  read_parent || return 1
  read_object "$resource" "$name" || return 1
  verdict="$(assess "$work/object.json" "$request" "$limit")" || { echo "failed: $namespace/$name could not be assessed"; return 1; }
  read -r kind uid version shape now <<< "$verdict"
  if [ "$kind" = refuse ]; then echo "refused: $namespace/$name: ${verdict#refuse }"; return 1; fi
  pinned=$uid
  cp "$work/object.json" "$work/before.json" || return 1
  if [ "$action" = check ]; then
    if [ "$kind" = same ]; then echo "ok: $namespace/$name already has $request/$limit and $annotation=false (uid $uid)"
    else echo "would patch: $namespace/$name (uid $uid) from $now to $request/$limit/false (request/limit/$annotation)"; fi
    return 0
  fi
  if [ "$kind" = same ]; then
    log_line outcome "$name" "already as wanted; not changed by this run" || { echo "failed: $record could not be written"; return 1; }
    echo "ok: $namespace/$name already has $request/$limit and $annotation=false (uid $uid)"
    return 0
  fi
  while :; do
    tries=$((tries + 1))
    if [ "$tries" -gt 3 ]; then unresolved "$name" "failed: $namespace/$name: three patches met a changed object"; return 1; fi
    python3 -I - "$uid" "$version" "$shape" "$request" "$limit" "$annotation" > "$work/patch.json" <<'PY' || { echo "failed: no patch could be written"; return 1; }
import json
import sys

uid, version, shape, request, limit, annotation = sys.argv[1:7]
patch = [{"op": "test", "path": "/metadata/uid", "value": uid},
         {"op": "test", "path": "/metadata/resourceVersion", "value": version}]
if shape == "map":
    patch.append({"op": "add", "path": "/metadata/annotations/" + annotation.replace("~", "~0").replace("/", "~1"),
                  "value": "false"})
else:
    patch.append({"op": "add", "path": "/metadata/annotations", "value": {annotation: "false"}})
patch += [{"op": "add", "path": "/spec/resources/requests/memory", "value": request},
          {"op": "add", "path": "/spec/resources/limits/memory", "value": limit}]
print(json.dumps(patch))
PY
    # What the object was goes into the record before the write; without that line there is no write.
    log_line before "$name" "patch attempt $tries" || { echo "failed: $record could not be written; nothing was patched"; return 1; }
    tested=$version
    acknowledged=""
    rejected=""
    echo "patching $namespace/$name (uid $uid, resourceVersion $version) from $now to $request/$limit/false"
    if kube -n "$namespace" patch "$resource" "$name" --type=json --patch-file "$work/patch.json" -o json > "$work/patch.out" 2> "$work/patch.err"; then
      acknowledged="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["metadata"]["resourceVersion"])' "$work/patch.out" 2> /dev/null)" || acknowledged=unreadable
      echo "acknowledged: $namespace/$name at resourceVersion $acknowledged"
    elif grep -q -E 'the server rejected our request due to an error in our request|\(Conflict\)|the object has been modified' "$work/patch.err"; then
      # The API server answered and refused: a test operation or the stored version did not match. Nothing was written.
      rejected=yes
      echo "the patch was rejected: $(tr '\n' ' ' < "$work/patch.err" | cut -c1-200)"
    else
      # No answer that settles it: the patch may or may not have been stored.
      echo "the patch has no answer: $(tr '\n' ' ' < "$work/patch.err" | cut -c1-200)"
    fi
    # Whatever the answer was, read the Monitoring and the object again.
    read_parent || { unresolved "$name" "failed: $namespace/$name: the Monitoring could not be confirmed after the patch attempt" || true; return 1; }
    read_object "$resource" "$name" || { unresolved "$name" "failed: $namespace/$name could not be read after the patch attempt" || true; return 1; }
    verdict="$(assess "$work/object.json" "$request" "$limit" "$work/before.json")" || { unresolved "$name" "failed: $namespace/$name could not be assessed" || true; return 1; }
    read -r kind uid version shape now <<< "$verdict"
    if [ "$kind" = refuse ]; then unresolved "$name" "refused: $namespace/$name: ${verdict#refuse }" || true; return 1; fi
    if [ "$uid" != "$pinned" ]; then unresolved "$name" "failed: $namespace/$name is another object now (uid $uid, was $pinned)" || true; return 1; fi
    if [ "$kind" = "done" ]; then
      if [ -n "$acknowledged" ]; then
        log_line outcome "$name" "patched by this run" "$acknowledged" || { echo "failed: $record could not be written"; return 1; }
        echo "ok: $namespace/$name patched (acknowledged at resourceVersion $acknowledged) and read back with its Monitoring"
      elif [ -n "$rejected" ]; then
        log_line outcome "$name" "as wanted, written by another writer: this run's patch was rejected; read back at resourceVersion $version" || { echo "failed: $record could not be written"; return 1; }
        echo "ok: $namespace/$name is as wanted, by another writer (this run's patch was rejected; read back at resourceVersion $version)"
      else
        log_line outcome "$name" "as wanted after a patch without an answer: the state is verified, the writer is not established; read back at resourceVersion $version" || { echo "failed: $record could not be written"; return 1; }
        echo "ok: $namespace/$name is as wanted after a patch without an answer (read back at resourceVersion $version); the writer is not established"
      fi
      return 0
    fi
    if [ -n "$acknowledged" ]; then
      unresolved "$name" "failed: $namespace/$name: the acknowledged patch is not in place (now $now at resourceVersion $version); not written again" || true
      return 1
    fi
    if [ -z "$rejected" ]; then
      unresolved "$name" "failed: $namespace/$name: the patch has no answer and the object is not the intended result (now $now at resourceVersion $version); not written again" || true
      return 1
    fi
    if [ "$kind" != patch ] || [ "$version" = "$tested" ]; then
      unresolved "$name" "failed: $namespace/$name: the patch was rejected and the object is not a changed version of the one read (now $now at resourceVersion $version)" || true
      return 1
    fi
    # A definite rejection and the same object at another resourceVersion: a confirmed conflict. Patch that state.
    cp "$work/object.json" "$work/before.json" || return 1
  done
}

if [ "$action" = watch ]; then
  seconds="${2:-1800}"
  namespace=""
  read_parent || exit 1
  # One process follows both streams, so that a failure of either ends the watch at once.
  exec python3 -I -u - "$kubeconfig" "$namespace" "$annotation" "$seconds" "${READY_FILE:-}" "${targets[@]}" <<'PY'
import json
import os
import selectors
import subprocess
import sys
import time

kubeconfig, namespace, annotation, seconds, ready_file = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]
stamp = lambda: time.strftime("%H:%M:%S", time.gmtime())
streams, selector, decoder = {}, selectors.DefaultSelector(), json.JSONDecoder()
for target in sys.argv[6:]:
    resource, name, request, limit = target.split()
    # A watch of the collection, filtered to the name, lists first and then follows from that list's resourceVersion,
    # so the first event is the baseline and nothing after it is missed. (A get of the name itself does not.)
    process = subprocess.Popen(["kubectl", "--kubeconfig", kubeconfig, "-n", namespace, "get", resource,
                                "--field-selector", "metadata.name=" + name, "--watch", "--output-watch-events",
                                "-o", "json"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector.register(process.stdout, selectors.EVENT_READ, name)
    streams[name] = {"process": process, "want": "%s/%s/false" % (request, limit), "buffer": "", "uid": None,
                     "events": 0, "target": False, "eof": False}


def stop(code, why=None):
    for stream in streams.values():
        if stream["process"].poll() is None:
            stream["process"].terminate()
    for stream in streams.values():
        try:
            stream["process"].wait(timeout=10)
        except subprocess.TimeoutExpired:
            stream["process"].kill()
    for name, stream in streams.items():
        print("%s watch of %s ended: %d events, wanted values %s" % (
            stamp(), name, stream["events"], "seen" if stream["target"] else "NOT seen"), flush=True)
    if why:
        print("%s WATCH FAILED: %s" % (stamp(), why), flush=True)
    sys.exit(code)


def handle(name, event):
    stream = streams[name]
    kind, obj = event.get("type"), event.get("object") or {}
    meta, resources = obj.get("metadata") or {}, (obj.get("spec") or {}).get("resources") or {}
    now = "%s/%s/%s" % ((resources.get("requests") or {}).get("memory"), (resources.get("limits") or {}).get("memory"),
                        (meta.get("annotations") or {}).get(annotation))
    if kind == "BOOKMARK":
        return
    stream["events"] += 1
    print("%s %s %s uid=%s rv=%s gen=%s %s" % (stamp(), name, kind, meta.get("uid"), meta.get("resourceVersion"),
                                               meta.get("generation"), now), flush=True)
    if kind not in ("ADDED", "MODIFIED"):
        stop(1, "%s: a %s event" % (name, kind))
    if meta.get("name") != name or not meta.get("uid") or not meta.get("resourceVersion"):
        stop(1, "%s: an event for %s without a UID or resourceVersion, or for another name" % (name, meta.get("name")))
    if stream["uid"] is None:
        if kind != "ADDED":
            stop(1, "%s: the first event is not the baseline" % name)
        stream["uid"], stream["baseline"] = meta["uid"], meta["resourceVersion"]
        if all(s["uid"] for s in streams.values()):
            state = " ".join("%s=%s@%s" % (n, s["uid"], s["baseline"]) for n, s in sorted(streams.items()))
            print("%s READY: both baselines are in (%s)" % (stamp(), state), flush=True)
            if ready_file:
                open(ready_file, "w").write(state + "\n")
    elif meta["uid"] != stream["uid"]:
        stop(1, "%s: another object under the name (uid %s)" % (name, meta["uid"]))
    if now == stream["want"]:
        stream["target"] = True
    elif stream["target"]:
        stop(1, "%s: REVERTED to %s after it had the wanted values" % (name, now))


started = time.time()
deadline = started + seconds
while True:
    remaining = deadline - time.time()
    if remaining <= 0:
        break
    if time.time() - started > 60 and not all(s["uid"] for s in streams.values()):
        stop(1, "no baseline within 60 s for: %s" % ", ".join(n for n, s in streams.items() if not s["uid"]))
    for key, _ in selector.select(timeout=min(remaining, 1.0)):
        name = key.data
        stream = streams[name]
        chunk = os.read(key.fileobj.fileno(), 65536)
        if chunk == b"":
            stream["eof"] = True
            selector.unregister(key.fileobj)
            continue
        stream["buffer"] += chunk.decode()
        while stream["buffer"].lstrip():
            text = stream["buffer"].lstrip()
            try:
                event, end = decoder.raw_decode(text)
            except ValueError:
                break
            stream["buffer"] = text[end:]
            handle(name, event)
    for name, stream in streams.items():
        if stream["eof"]:
            left = " with truncated data" if stream["buffer"].strip() else ""
            stop(1, "%s: the stream ended early%s (kubectl exit %s)" % (name, left, stream["process"].wait()))
missing = [name for name, stream in streams.items() if not stream["target"]]
if missing:
    stop(1, "the wanted values were never seen on: %s" % ", ".join(missing))
stop(0)
PY
fi

namespace=""
for target in "${targets[@]}"; do
  read -r resource name request limit <<< "$target"
  if ! one "$resource" "$name" "$request" "$limit"; then
    [ "$action" = check ] || echo "stopped: nothing further was written"
    exit 1
  fi
done
exit 0
