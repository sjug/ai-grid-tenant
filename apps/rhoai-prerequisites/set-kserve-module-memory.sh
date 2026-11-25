#!/usr/bin/env bash
# Memory limit of RHOAI's KServe module operator on one site (RHOAIENG-103335).
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Raise the memory limit of the manager container of redhat-ods-applications/kserve-module-controller-manager, the
KServe module operator that RHOAI's Platform deploys, from the shipped 1Gi to 2Gi on one site.
See apps/rhoai-prerequisites/README.md, "KServe module operator memory".

Usage:
  set-kserve-module-memory.sh check   report what apply would change; changes nothing
  set-kserve-module-memory.sh apply   patch the limit, then wait for the new pod and watch that it stays

Required environment:
  KUBECONFIG    The site's kubeconfig, a readable file. It is passed to every request.
  PLATFORM_UID  The UID of that site's Platform default, read beforehand on the site that is meant. Every action
                refuses a Deployment that this Platform does not control.
Environment for apply:
  RECORD_FILE   Required. JSON lines are appended: before the write the Deployment's UID, resourceVersion and
                previous memory limit, and afterwards the outcome. The write is not attempted unless its line could
                be written. Roll back from this record.
  STABLE        Seconds the new pod must stay Ready without a restart and the limit must stay in place (default 180).
  WAIT          Seconds to wait for the rollout (default 420). Every read and pause while waiting is bounded by the
                time left; a read that times out while time is left counts as a failed observation.
  POLL          Seconds between reads while waiting (default 5).

apply sends one JSON Patch that tests the Deployment's UID and resourceVersion, the container's name at its index and
the old limit, then replaces only that limit; the API server changes nothing unless the Deployment is still as it was
read. The Platform keeps a live container resource value when it renders the Deployment, unless the Deployment is
annotated opendatahub.io/managed: "true", so the script refuses such a Deployment. Success needs: the Deployment
rolled out with the new limit, every pod of it new, Running and Ready, and then for STABLE seconds no restart, no
replacement and the limit still 2Gi.
Exit 0: nothing to do, or done and verified. 1: refused or failed; the reason is printed. 2: usage.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

namespace=redhat-ods-applications
deployment=kserve-module-controller-manager
container=manager
shipped=1Gi
target=2Gi
annotation=opendatahub.io/managed

action="${1:-}"
case "$action" in
  check | apply) [ $# -eq 1 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
kubeconfig="${KUBECONFIG:-}"
[ -n "$kubeconfig" ] && [ -f "$kubeconfig" ] && [ -r "$kubeconfig" ] || die "KUBECONFIG must name the site's kubeconfig, one readable file"
platform="${PLATFORM_UID:-}"
[ -n "$platform" ] || die "PLATFORM_UID must hold the UID of the intended site's Platform default"
record="${RECORD_FILE:-}"
[ "$action" != apply ] || [ -n "$record" ] || die "RECORD_FILE must name the file that records what apply changes"
stable="${STABLE:-180}"
wait_seconds="${WAIT:-420}"
[[ $stable =~ ^[1-9][0-9]{0,3}$ ]] || die "STABLE must be whole seconds, 1 to 9999"
[[ $wait_seconds =~ ^[1-9][0-9]{0,3}$ ]] || die "WAIT must be whole seconds, 1 to 9999"
poll="${POLL:-5}"
python3 -I -c 'import math, sys
try: v = float(sys.argv[1])
except ValueError: sys.exit(1)
sys.exit(0 if math.isfinite(v) and 0 < v <= 60 else 1)' "$poll" || die "POLL must be a number of seconds above 0 and at most 60"
for required_command in kubectl python3; do
  command -v "$required_command" > /dev/null 2>&1 || die "required command not found: $required_command"
done
work="$(mktemp -d)" || die "no temporary directory"
trap 'rm -rf "$work"' EXIT

# deadline: 0 outside the waits; while waiting, kube is bounded by the time left and returns 125 without sending
# anything once none is left (124 is a read that timed out).
deadline=0
kube() {
  local t=60
  if [ "$deadline" -gt 0 ]; then
    t=$(( deadline - $(date +%s) ))
    [ "$t" -le 60 ] || t=60
    [ "$t" -ge 1 ] || return 125
  fi
  timeout "$t" kubectl --kubeconfig "$kubeconfig" --request-timeout=30s "$@" < /dev/null
}

# read_json <file> <kubectl get arguments>: a complete answer in <file> (0), absent (1), unreadable (2), timed out
# (124) or not sent because no time is left (125).
read_json() {
  local file=$1 rc=0
  shift
  kube get "$@" -o json > "$file.tmp" 2> "$file.err" || rc=$?
  if [ "$rc" = 0 ]; then
    python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$file.tmp" 2> /dev/null || return 2
    mv "$file.tmp" "$file" || return 2
    return 0
  fi
  case "$rc" in 124 | 125) return "$rc" ;; esac
  if grep -q 'NotFound' "$file.err"; then return 1; fi
  return 2
}

# assess <deployment.json>: "refuse <reason>" | "done <uid> <rv>" | "patch <uid> <rv> <index of the container>"
assess() {
  python3 -I - "$1" "$platform" "$container" "$shipped" "$target" "$annotation" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
platform, name, shipped, target, annotation = sys.argv[2:7]
meta = d.get("metadata") or {}


def out(*words):
    print(" ".join(str(w) for w in words))
    sys.exit(0)


if not meta.get("uid") or not meta.get("resourceVersion"):
    out("refuse", "the Deployment has no UID or resourceVersion")
if meta.get("deletionTimestamp"):
    out("refuse", "the Deployment is terminating")
controllers = [o for o in meta.get("ownerReferences") or [] if o.get("controller") is True]
if len(controllers) != 1 or controllers[0].get("kind") != "Platform" or controllers[0].get("uid") != platform:
    out("refuse", "the Deployment is not controlled by the Platform with UID", platform)
if (meta.get("annotations") or {}).get(annotation) == "true":
    out("refuse", "the Deployment is annotated %s: true, so the Platform would revert the limit" % annotation)
containers = ((d.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers") or []
index = [i for i, c in enumerate(containers) if c.get("name") == name]
if len(index) != 1:
    out("refuse", "the Deployment has %d containers named %s" % (len(index), name))
limit = ((containers[index[0]].get("resources") or {}).get("limits") or {}).get("memory")
if limit == target:
    out("done", meta["uid"], meta["resourceVersion"])
if limit != shipped:
    out("refuse", "the %s memory limit is %s, neither the shipped %s nor %s; not touching it" % (name, limit, shipped, target))
out("patch", meta["uid"], meta["resourceVersion"], index[0])
PY
}

read_deployment() {
  local rc=0
  read_json "$work/$1" -n "$namespace" deployment "$deployment" || rc=$?
  [ "$rc" = 0 ] && return 0
  [ "$rc" = 1 ] && die "there is no Deployment $namespace/$deployment"
  die "the Deployment could not be read"
}

record_line() {
  python3 -I -c 'import json, sys, time; print(json.dumps(dict(time=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **json.loads(sys.argv[1]))))' "$1" >> "$record"
}

read_deployment before.json
verdict="$(assess "$work/before.json")" || die "the Deployment could not be assessed"
set -- $verdict
case "$1" in
  refuse) die "refused: ${verdict#refuse }" ;;
  done) echo "nothing to do: the $container memory limit is already $target (Deployment $2)"; exit 0 ;;
  patch) uid=$2 rv=$3 index=$4 ;;
  *) die "unexpected assessment: $verdict" ;;
esac
echo "Deployment $namespace/$deployment ($uid, resourceVersion $rv): $container memory limit $shipped -> $target"
[ "$action" = check ] && exit 0

old_pods="$work/old-pods.txt"
selector="$(python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1]))["spec"]["selector"].get("matchLabels") or {}; print(",".join("%s=%s" % kv for kv in sorted(m.items())))' "$work/before.json")" || die "no selector"
[ -n "$selector" ] || die "the Deployment has no matchLabels selector"
read_json "$work/pods-before.json" -n "$namespace" pods -l "$selector" || die "the module operator's pods could not be read"
python3 -I -c 'import json, sys; [print(p["metadata"]["uid"]) for p in json.load(open(sys.argv[1]))["items"]]' "$work/pods-before.json" > "$old_pods" || die "the pods could not be parsed"

record_line "$(printf '{"event":"before","uid":"%s","resourceVersion":"%s","limit":"%s"}' "$uid" "$rv" "$shipped")" || die "could not write $record; nothing was changed"
printf '[{"op":"test","path":"/metadata/uid","value":"%s"},{"op":"test","path":"/metadata/resourceVersion","value":"%s"},{"op":"test","path":"/spec/template/spec/containers/%s/name","value":"%s"},{"op":"test","path":"/spec/template/spec/containers/%s/resources/limits/memory","value":"%s"},{"op":"replace","path":"/spec/template/spec/containers/%s/resources/limits/memory","value":"%s"}]\n' \
  "$uid" "$rv" "$index" "$container" "$index" "$shipped" "$index" "$target" > "$work/patch.json"
if ! kube -n "$namespace" patch deployment "$deployment" --type=json --patch-file="$work/patch.json" > "$work/patch.out" 2>&1; then
  record_line '{"event":"patch-failed"}' || true
  die "the patch failed or its outcome is unknown ($(head -c 300 "$work/patch.out" | tr '\n' ' ')); read the Deployment before any retry"
fi
record_line "$(printf '{"event":"patched","uid":"%s","limit":"%s"}' "$uid" "$target")" || true

# state: prints the situation; 0 when the Deployment has the UID and limit, has rolled out and every pod is new and Ready
state() {
  local rc=0
  read_json "$work/now.json" -n "$namespace" deployment "$deployment" || rc=$?
  case "$rc" in 0) ;; 125) echo "NOTIME"; return 1 ;; 124) echo "the Deployment read timed out"; return 1 ;; *) echo "the Deployment could not be read"; return 1 ;; esac
  read_json "$work/pods.json" -n "$namespace" pods -l "$selector" || rc=$?
  case "$rc" in 0) ;; 125) echo "NOTIME"; return 1 ;; 124) echo "the pods read timed out"; return 1 ;; *) echo "the pods could not be read"; return 1 ;; esac
  python3 -I - "$work/now.json" "$work/pods.json" "$old_pods" "$uid" "$container" "$target" "$work/restarts.json" <<'PY'
import json
import sys

d, pods = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))["items"]
old, uid, name, target, restarts_file = set(open(sys.argv[3]).read().split()), sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]


def bad(message):
    print(message)
    sys.exit(1)


meta, status, spec = d["metadata"], d.get("status") or {}, d["spec"]
if meta.get("uid") != uid:
    bad("FATAL the Deployment was replaced (UID %s)" % meta.get("uid"))
if meta.get("deletionTimestamp"):
    bad("FATAL the Deployment is terminating")
managers = [c for c in spec["template"]["spec"].get("containers") or [] if c.get("name") == name]
if len(managers) != 1:
    bad("FATAL the Deployment now has %d containers named %s" % (len(managers), name))
limit = ((managers[0].get("resources") or {}).get("limits") or {}).get("memory")
if limit != target:
    bad("FATAL the memory limit is %s again, not %s: something reverted it" % (limit, target))
want = spec.get("replicas", 1)
if status.get("observedGeneration") != meta.get("generation") or not (
        status.get("updatedReplicas") == status.get("readyReplicas") == status.get("availableReplicas") == want):
    bad("rolling out: updated %s ready %s available %s of %s" % (
        status.get("updatedReplicas"), status.get("readyReplicas"), status.get("availableReplicas"), want))
if len(pods) != want:
    bad("%d pods, want %d" % (len(pods), want))
restarts = {}
for p in pods:
    pod = p["metadata"]["name"]
    if p["metadata"]["uid"] in old:
        bad("pod %s is from before the patch" % pod)
    if p["metadata"].get("deletionTimestamp"):
        bad("pod %s is terminating" % pod)
    ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in (p.get("status") or {}).get("conditions") or [])
    if not ready or (p.get("status") or {}).get("phase") != "Running":
        bad("pod %s is not Running and Ready" % pod)
    restarts[p["metadata"]["uid"]] = sum(c.get("restartCount", 0) for c in (p.get("status") or {}).get("containerStatuses") or [])
json.dump(restarts, open(restarts_file, "w"))
print("rolled out: %d new pod(s) Running and Ready with the %s limit" % (want, target))
PY
}

# pause: sleep POLL seconds, or less when the deadline is nearer
pause() {
  local left=$(( deadline - $(date +%s) ))
  [ "$left" -gt 0 ] || return 0
  sleep "$(python3 -I -c 'import sys; print(min(float(sys.argv[1]), float(sys.argv[2])))' "$poll" "$left")"
}

deadline=$(( $(date +%s) + wait_seconds )); last="no observation yet"
while :; do
  if [ "$(date +%s)" -ge "$deadline" ]; then record_line '{"event":"timeout"}' || true; die "not rolled out after $wait_seconds s: $last"; fi
  if now="$(state)"; then
    if [ "$(date +%s)" -gt "$deadline" ]; then record_line '{"event":"timeout"}' || true; die "not rolled out after $wait_seconds s: the rollout was seen only after the deadline"; fi
    break
  fi
  case "$now" in
    FATAL*) record_line '{"event":"failed"}' || true; die "${now#FATAL }" ;;
    NOTIME) record_line '{"event":"timeout"}' || true; die "not rolled out after $wait_seconds s: $last" ;;
  esac
  last=$now
  pause
done
echo "$now"
cp "$work/restarts.json" "$work/restarts-start.json"
stable_end=$(( $(date +%s) + stable ))
deadline=$(( stable_end + 60 ))
while [ "$(date +%s)" -lt "$stable_end" ]; do
  sleep "$poll"
  if ! now="$(state)"; then record_line '{"event":"unstable"}' || true; die "not stable: ${now#FATAL }"; fi
  if ! python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$work/restarts-start.json" "$work/restarts.json"; then
    record_line '{"event":"restarted"}' || true
    die "the new pod restarted or was replaced within $stable s"
  fi
done
record_line "$(printf '{"event":"done","uid":"%s","limit":"%s","stable":%s}' "$uid" "$target" "$stable")" || true
echo "done: the $container memory limit is $target and the new pod stayed Ready without a restart for $stable s"
