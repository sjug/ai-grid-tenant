#!/usr/bin/env bash
# The rhoai-metrics-addon Policy must leave the addon installable when it creates the ClusterManagementAddOn first:
# installStrategy.type Placements (the CRD default is Manual) and, on the global placement, the reference to the
# observability operator's AddOnDeploymentConfig.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$HERE/../hub/13-rhai-metrics-addon-policy.yaml" <<'PY'
import sys
import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
policy = next(d for d in docs if d.get("kind") == "Policy" and d["metadata"]["name"] == "rhoai-metrics-addon")
objects = [t["objectDefinition"] for pt in policy["spec"]["policy-templates"]
           for t in pt["objectDefinition"]["spec"]["object-templates"]]
cma = next(o for o in objects if o.get("kind") == "ClusterManagementAddOn"
           and o["metadata"]["name"] == "multicluster-observability-addon")
strategy = cma["spec"]["installStrategy"]
assert strategy["type"] == "Placements", strategy.get("type")
glob = next(p for p in strategy["placements"]
            if p["name"] == "global" and p["namespace"] == "open-cluster-management-global-set")
assert {"group": "addon.open-cluster-management.io", "resource": "addondeploymentconfigs",
        "namespace": "open-cluster-management-observability",
        "name": "multicluster-observability-addon"} in glob["configs"], glob["configs"]
PY
echo "metrics-addon-policy tests: 1 ok, 0 failed"
