#!/usr/bin/env bash
# Exercises the checker against a stub oc and temporary checkouts; no cluster.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
git -c core.hooksPath=/dev/null clone -q --shared "$ROOT" "$T/repo"
cp "$ROOT/scripts/check-root-appset.sh" "$T/repo/scripts/check-root-appset.sh"
REAL_GIT=$(command -v git)
export REAL_GIT

cat > "$T/bin/oc" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$STUB_CALLS"
refuse() { echo "STUB_REFUSED: unexpected oc command" >&2; exit 99; }
[[ $# == 10 ]] || refuse
[[ $1 == --kubeconfig && -f $2 && -r $2 ]] || refuse
[[ $3 =~ ^--request-timeout=([0-9]+([.][0-9]+)?)s$ ]] || refuse
python3 - "${BASH_REMATCH[1]}" <<'PY' || refuse
import math
import sys
value = float(sys.argv[1])
sys.exit(0 if math.isfinite(value) and value > 0 else 1)
PY
[[ $4 == --namespace && $5 == "$STUB_NAMESPACE" && $6 == get && $7 == applicationset &&
   $8 == "$STUB_NAME" && $9 == -o && ${10} == json ]] || refuse
if [[ ${STUB_SLOW:-0} == 1 ]]; then exec python3 -c 'import time; time.sleep(5)'; fi
if [[ -n ${STUB_ERROR:-} ]]; then printf '%s\n' "$STUB_ERROR" >&2; fi
cat "$STUB_JSON"
exit "${STUB_RC:-0}"
STUB
cat > "$T/bin/git" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -n ${STUB_GIT_FAIL:-} && " $* " == *" $STUB_GIT_FAIL "* ]]; then
  echo "fixture git failure" >&2
  exit 1
fi
exec "$REAL_GIT" "$@"
STUB
chmod 700 "$T/bin/oc" "$T/bin/git"

python3 - "$ROOT" "$T" <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import yaml

root, temporary = map(Path, sys.argv[1:])
repo = temporary / "repo"
plain = temporary / "plain"
(plain / "scripts").mkdir(parents=True)
shutil.copyfile(root / "scripts/check-root-appset.sh", plain / "scripts/check-root-appset.sh")
paths = {profile: Path("bootstrap") / profile / "applicationset.yaml" for profile in ("", "dedicated-hub")}
original = {profile: (root / path).read_text() for profile, path in paths.items()}
objects = {profile: yaml.safe_load(text) for profile, text in original.items()}
(temporary / "kubeconfig").touch()
cases = []


def change(path, value):
    def mutate(obj):
        target = obj
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
    return mutate


def remove(path):
    def mutate(obj):
        target = obj
        for key in path[:-1]:
            target = target[key]
        del target[path[-1]]
    return mutate


def bookkeeping(obj):
    obj["metadata"].update(uid="fixture", resourceVersion="2", generation=3,
                           managedFields=[], creationTimestamp="2020-01-01T00:00:00Z",
                           annotations={"kubectl.kubernetes.io/last-applied-configuration": "{}"})
    obj["status"] = {"conditions": []}


def add(name, expected=0, **options):
    cases.append(dict(name=name, expected=expected, **options))


for profile in paths:
    prefix = profile or "default"
    add(prefix + ": bookkeeping ignored", profile=profile, live=bookkeeping,
        contains=["desired file has uncommitted changes: no", "desired /spec/generators/0/git:",
                  "live /spec/generators/0/git:", "checkout SHA:", f"profile: {prefix}"])
    for title, path, value in (
        ("template", ["spec", "template", "spec", "project"], "different-project"),
        ("templatePatch", ["spec", "templatePatch"], objects[profile]["spec"]["templatePatch"] + "\n"),
        ("goTemplateOptions", ["spec", "goTemplateOptions"], []),
        ("deletion policy", ["spec", "syncPolicy", "applicationsSync"], "create-update"),
        ("preservation true", ["spec", "syncPolicy", "preserveResourcesOnDeletion"], True),
        ("repoURL", ["spec", "generators", 0, "git", "repoURL"], "different-repository"),
        ("revision", ["spec", "generators", 0, "git", "revision"], "different-revision"),
    ):
        add(prefix + ": " + title, 1, profile=profile, live=change(path, value),
            contains=["REVIEW: selection or deletion", "/".join(map(str, [""] + path))])
    add(prefix + ": extra spec field", 1, profile=profile,
        live=change(["spec", "extraField"], "value"), contains=["/spec/extraField", "<absent>"])
    add(prefix + ": absent live preservation", profile=profile,
        live=remove(["spec", "syncPolicy", "preserveResourcesOnDeletion"]))
    add(prefix + ": absent desired preservation", profile=profile,
        desired=remove(["spec", "syncPolicy", "preserveResourcesOnDeletion"]),
        contains=["desired file has uncommitted changes: yes"])
    add(prefix + ": absent live applicationsSync", 1, profile=profile,
        live=remove(["spec", "syncPolicy", "applicationsSync"]))
    add(prefix + ": absent desired applicationsSync", 1, profile=profile,
        desired=remove(["spec", "syncPolicy", "applicationsSync"]))
    add(prefix + ": absent entire policy", profile=profile,
        desired=remove(["spec", "syncPolicy"]), live=change(["spec", "syncPolicy"], {"preserveResourcesOnDeletion": False}))
    for title, path, value in (
        ("wrong kind", ["kind"], "ConfigMap"),
        ("wrong name", ["metadata", "name"], objects[profile]["metadata"]["name"] + "-other"),
        ("wrong namespace", ["metadata", "namespace"], objects[profile]["metadata"]["namespace"] + "-other"),
        ("non-mapping spec", ["spec"], []),
    ):
        add(prefix + ": " + title, 2, profile=profile, live=change(path, value))
    add(prefix + ": missing spec", 2, profile=profile, live=remove(["spec"]))
    add(prefix + ": snapshot equal", profile=profile, snapshot=True, calls=0,
        env={"KUBECONFIG": None}, contains=["mode: snapshot", "no freshness claim", "snapshot /spec/generators/0/git:"])
    add(prefix + ": snapshot drift", 1, profile=profile, snapshot=True, calls=0,
        live=change(["spec", "template", "spec", "project"], "different-project"), contains=["mode: snapshot"])

add("historical exclusion rename", 1,
    live=change(["spec", "generators", 0, "git", "files", 3, "path"], "apps/maas-home/application.yaml"),
    contains=["apps/maas-home/application.yaml", "apps/external-services/application.yaml", "REVIEW:"])
add("list order significant", 1, live=lambda obj: obj["spec"]["generators"][0]["git"]["files"].reverse())
add("mapping key order ignored", live=lambda obj: obj.update(spec=dict(reversed(list(obj["spec"].items())))))
add("explicit empty list is not absent", 1, live=change(["spec", "extraField"], []))
add("desired comment flagged", fixture="comment", contains=["desired file has uncommitted changes: yes"])
for title, env in (
    ("unset profile", {"BOOTSTRAP_PROFILE": None}),
    ("invalid profile", {"BOOTSTRAP_PROFILE": "unknown"}),
    ("missing kubeconfig", {"KUBECONFIG": None}),
    ("unreadable kubeconfig", {"KUBECONFIG": str(temporary / "missing-kubeconfig")}),
    ("git revision failure", {"STUB_GIT_FAIL": "rev-parse"}),
    ("git status failure", {"STUB_GIT_FAIL": "status"}),
):
    add(title, 2, env=env, calls=0)
for timeout in ("0", "-1", "nan", "inf", "", "1e309"):
    add("invalid timeout: " + repr(timeout), 2, env={"OC_REQUEST_TIMEOUT": timeout}, calls=0)
add("bounded slow read", 2, env={"STUB_SLOW": "1", "OC_REQUEST_TIMEOUT": "0.1"}, contains=["timed out"])
for fixture in ("missing desired", "malformed desired", "duplicate desired key", "non-git"):
    add(fixture, 2, fixture=fixture, calls=0)
add("missing object", 2, env={"STUB_RC": "1", "STUB_ERROR": "NotFound"}, live_text="")
add("failed read with valid JSON", 2, env={"STUB_RC": "1"})
add("malformed live JSON", 2, live_text="{")
add("live is a list", 2, live_text="[]")
add("duplicate live key", 2, live_text='{"kind":"ApplicationSet","kind":"ApplicationSet"}')
add("non-mapping syncPolicy", 2, live=change(["spec", "syncPolicy"], []))
add("non-boolean preservation", 2, live=change(["spec", "syncPolicy", "preserveResourcesOnDeletion"], 0))
add("missing desired spec", 2, desired=remove(["spec"]), calls=0)
add("wrong desired kind", 2, desired=change(["kind"], "ConfigMap"), calls=0)
add("unreadable snapshot", 2, env={"LIVE_JSON": str(temporary / "missing.json")}, calls=0)
add("empty snapshot input", 2, env={"LIVE_JSON": ""}, calls=0)
add("malformed snapshot", 2, snapshot=True, live_text="{", calls=0)

failures = 0
for case in cases:
    profile = case.get("profile", "")
    current = plain if case.get("fixture") == "non-git" else repo
    for key, path in paths.items():
        (current / path).parent.mkdir(parents=True, exist_ok=True)
        (current / path).write_text(original[key])
    desired_path = current / paths[profile]
    if "desired" in case:
        desired = copy.deepcopy(objects[profile])
        case["desired"](desired)
        desired_path.write_text(yaml.safe_dump(desired, sort_keys=False))
    fixture = case.get("fixture")
    if fixture == "missing desired":
        desired_path.unlink()
    elif fixture == "malformed desired":
        desired_path.write_text("spec: [")
    elif fixture == "duplicate desired key":
        desired_path.write_text(original[profile] + "\nspec: {}\n")
    elif fixture == "comment":
        desired_path.write_text("# fixture comment\n" + original[profile])
    live = copy.deepcopy(objects[profile])
    if "live" in case:
        case["live"](live)
    live_path = temporary / "live.json"
    live_path.write_text(case.get("live_text", json.dumps(live)))
    calls_path = temporary / "calls"
    calls_path.write_text("")
    env = {"PATH": str(temporary / "bin") + os.pathsep + os.environ["PATH"], "LC_ALL": "C",
           "REAL_GIT": os.environ["REAL_GIT"], "BOOTSTRAP_PROFILE": profile,
           "KUBECONFIG": str(temporary / "kubeconfig"), "STUB_JSON": str(live_path),
           "STUB_CALLS": str(calls_path), "STUB_NAMESPACE": objects[profile]["metadata"]["namespace"],
           "STUB_NAME": objects[profile]["metadata"]["name"]}
    if case.get("snapshot"):
        env["LIVE_JSON"] = str(live_path)
    for key, value in case.get("env", {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    try:
        result = subprocess.run(["bash", str(current / "scripts/check-root-appset.sh")], env=env,
                                capture_output=True, text=True, timeout=10)
        output = result.stdout + result.stderr
        calls = len(calls_path.read_text().splitlines())
        checks = (result.returncode == case["expected"] and calls == case.get("calls", 1)
                  and "STUB_REFUSED" not in output
                  and all(needle in output for needle in case.get("contains", [])))
        verdict = {0: r"^equal:", 1: r"^drift:", 2: r"^unable to check:"}[case["expected"]]
        checks = checks and re.search(verdict, output, re.MULTILINE)
        if case["expected"] != 0:
            checks = checks and not re.search(r"^equal:", output, re.MULTILINE)
        if checks:
            print(f"   ok   {case['name']} (rc={result.returncode}, reads={calls})")
        else:
            failures += 1
            print(f"   FAIL {case['name']} (rc={result.returncode}, reads={calls})\n{output}")
    except subprocess.TimeoutExpired:
        failures += 1
        print(f"   FAIL {case['name']}: checker exceeded test deadline")

print(f"check-root-appset tests: {len(cases) - failures} ok, {failures} failed")
sys.exit(failures)
PY
