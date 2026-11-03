#!/usr/bin/env bash
# Compare the selected root ApplicationSet with Git. Needs Python/PyYAML, git, and oc for live reads.
# BOOTSTRAP_PROFILE must be set: '' or dedicated-hub. LIVE_JSON skips the API and needs no kubeconfig.
# Exit: 0 equal, 1 drift, 2 unable to check. OC_REQUEST_TIMEOUT is seconds (default 20).
set -Eeuo pipefail

unable() { echo "unable to check: $*" >&2; exit 2; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || unable "cannot locate repository"
[[ ${BOOTSTRAP_PROFILE+x} ]] || unable "set BOOTSTRAP_PROFILE explicitly (empty or dedicated-hub)"
case "$BOOTSTRAP_PROFILE" in
  ''|dedicated-hub) ;;
  *) unable "invalid BOOTSTRAP_PROFILE: $BOOTSTRAP_PROFILE" ;;
esac
export BOOTSTRAP_PROFILE

if python3 - "$root" <<'PY'
import copy
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys


def run(args, *, timeout=None):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
    if result.returncode:
        raise ValueError(f"{args[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError(f"invalid or duplicate mapping key: {key!r}")
        result[key] = value
    return result


def validate(obj, label, identity=None):
    if not isinstance(obj, dict) or obj.get("kind") != "ApplicationSet":
        raise ValueError(f"{label}: expected an ApplicationSet object")
    metadata = obj.get("metadata")
    if not isinstance(metadata, dict):
        raise ValueError(f"{label}: missing metadata mapping")
    actual = tuple(obj.get(key) for key in ("apiVersion", "kind")) + tuple(
        metadata.get(key) for key in ("name", "namespace"))
    if not all(isinstance(value, str) and value for value in actual):
        raise ValueError(f"{label}: missing apiVersion, name or namespace")
    if identity is not None and actual != identity:
        raise ValueError(f"{label}: object identity {actual!r} differs from {identity!r}")
    if not isinstance(obj.get("spec"), dict):
        raise ValueError(f"{label}: missing or non-mapping spec")
    policy = obj["spec"].get("syncPolicy", {})
    if not isinstance(policy, dict):
        raise ValueError(f"{label}: syncPolicy must be a mapping")
    if "preserveResourcesOnDeletion" in policy and type(policy["preserveResourcesOnDeletion"]) is not bool:
        raise ValueError(f"{label}: preserveResourcesOnDeletion must be a boolean")
    json.dumps(obj["spec"], allow_nan=False)
    return actual


def sources(value, path="/spec/generators"):
    if isinstance(value, dict):
        for key, child in sorted(value.items()):
            if key == "git" and isinstance(child, dict):
                yield path + "/git", child.get("repoURL"), child.get("revision")
            else:
                yield from sources(child, path + "/" + key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from sources(child, path + "/" + str(index))


def provenance(label, spec):
    found = list(sources(spec.get("generators", [])))
    if not found:
        print(f"{label} git sources: none")
    for path, repo, revision in found:
        print(f"{label} {path}: repoURL={json.dumps(repo)} revision={json.dumps(revision)}")


def normalise(spec):
    result = copy.deepcopy(spec)
    result.setdefault("syncPolicy", {}).setdefault("preserveResourcesOnDeletion", False)
    return result


ABSENT = object()


def differences(live, desired, path="/spec"):
    if type(live) is not type(desired):
        yield path, live, desired
    elif isinstance(live, dict):
        for key in sorted(live.keys() | desired.keys()):
            escaped = key.replace("~", "~0").replace("/", "~1")
            yield from differences(live.get(key, ABSENT), desired.get(key, ABSENT), path + "/" + escaped)
    elif isinstance(live, list):
        for index in range(max(len(live), len(desired))):
            yield from differences(live[index] if index < len(live) else ABSENT,
                                   desired[index] if index < len(desired) else ABSENT,
                                   path + "/" + str(index))
    elif live != desired:
        yield path, live, desired


def display(value):
    return "<absent>" if value is ABSENT else json.dumps(value, sort_keys=True, ensure_ascii=False)


def main():
    import yaml

    class UniqueLoader(yaml.SafeLoader):
        pass

    def mapping(loader, node):
        loader.flatten_mapping(node)
        return unique_pairs((loader.construct_object(key), loader.construct_object(value))
                            for key, value in node.value)

    UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
    root = Path(sys.argv[1])
    profile = os.environ["BOOTSTRAP_PROFILE"]
    relative = Path("bootstrap") / profile / "applicationset.yaml"
    desired = yaml.load((root / relative).read_text(), Loader=UniqueLoader)
    identity = validate(desired, "desired")
    sha = run(["git", "-C", str(root), "rev-parse", "--verify", "HEAD"]).strip()
    dirty = run(["git", "-C", str(root), "status", "--porcelain", "--", str(relative)]).strip()
    print(f"profile: {profile or 'default'}; file: {relative}")
    print(f"checkout SHA: {sha}")
    print(f"desired file has uncommitted changes: {'yes' if dirty else 'no'}")
    provenance("desired", desired["spec"])

    if "LIVE_JSON" in os.environ:
        snapshot = os.environ["LIVE_JSON"]
        if not snapshot:
            raise ValueError("LIVE_JSON must name a readable JSON file")
        print(f"mode: snapshot ({snapshot}); no freshness claim")
        payload = Path(snapshot).read_text()
        label = "snapshot"
    else:
        kubeconfig = os.environ.get("KUBECONFIG", "")
        if not kubeconfig or not Path(kubeconfig).is_file() or not os.access(kubeconfig, os.R_OK):
            raise ValueError("KUBECONFIG must name a readable file")
        request_timeout = os.environ.get("OC_REQUEST_TIMEOUT", "20")
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", request_timeout):
            raise ValueError("OC_REQUEST_TIMEOUT must be positive finite seconds")
        seconds = float(request_timeout)
        if not math.isfinite(seconds) or seconds <= 0:
            raise ValueError("OC_REQUEST_TIMEOUT must be positive finite seconds")
        print("mode: live")
        payload = run(["oc", "--kubeconfig", kubeconfig, f"--request-timeout={request_timeout}s",
                       "--namespace", identity[3], "get", "applicationset", identity[2], "-o", "json"],
                      timeout=seconds)
        label = "live"
    live = json.loads(payload, object_pairs_hook=unique_pairs)
    validate(live, label, identity)
    provenance(label, live["spec"])
    changes = list(differences(normalise(live["spec"]), normalise(desired["spec"])))
    if not changes:
        print(f"equal: {label} spec matches the desired file")
        return 0
    print(f"drift: {label} spec differs from the desired file")
    sensitive = {"generators", "syncPolicy", "template", "templatePatch", "goTemplate", "goTemplateOptions"}
    if any(path.split("/")[2] in sensitive for path, _, _ in changes):
        print("REVIEW: selection or deletion behaviour may change; review generated Application removals before applying")
    for path, old, new in changes:
        print(f"{path}:\n  {label}: {display(old)}\n  desired: {display(new)}")
    return 1


try:
    result = main()
except Exception as error:
    print(f"unable to check: {error}", file=sys.stderr)
    result = 2
sys.exit(result)
PY
then
  exit 0
else
  rc=$?
  case "$rc" in
    1|2) exit "$rc" ;;
    *) unable "checker failed (exit $rc)" ;;
  esac
fi
