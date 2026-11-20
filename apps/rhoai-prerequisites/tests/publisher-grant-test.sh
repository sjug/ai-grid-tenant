#!/usr/bin/env bash
# Asserts the shape of the model controller's publisher grant in the prerequisites Policy (no cluster). Needs PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$HERE/../hub/03-policy.yaml" <<'END_PY'
import sys, yaml
fails = 0
def check(cond, name):
    global fails
    print(("   ok   " if cond else "   FAIL ") + name); fails += 0 if cond else 1
pols = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Policy"]
cps = [t["objectDefinition"] for p in pols for t in p["spec"]["policy-templates"]]
byname = {c["metadata"]["name"]: c for c in cps}
cr = byname.get("odh-model-controller-grid-publisher"); ns = byname.get("odh-model-controller-grid-publisher-namespaces")
check(cr is not None and ns is not None, "both ConfigurationPolicies present")
objs = [o["objectDefinition"] for o in cr["spec"].get("object-templates", [])] if cr else []
roles = [o for o in objs if o["kind"] == "ClusterRole"]
check(len(roles) == 1 and roles[0]["rules"] == [{"apiGroups": ["serving.opendatahub.io"], "resources": ["models"], "verbs": ["post"]}], "ClusterRole grants exactly post on serving.opendatahub.io models")
check(not any(o["kind"] == "ClusterRoleBinding" for c in cps for o in [t["objectDefinition"] for t in c["spec"].get("object-templates", [])] if o["metadata"]["name"].startswith("odh-model-controller-grid-publisher")), "no cluster-wide binding of the publisher grant")
sel = (ns or {}).get("spec", {}).get("namespaceSelector", {}).get("matchLabels", {})
check(sel == {"grid.opendatahub.io/allowed": "true"}, "RoleBinding policy selects namespaces by grid.opendatahub.io/allowed=true")
nobjs = [o["objectDefinition"] for o in ns["spec"].get("object-templates", [])] if ns else []
rb = [o for o in nobjs if o["kind"] == "RoleBinding"]
check(len(rb) == 1 and rb[0]["roleRef"] == {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "odh-model-controller-grid-publisher"} and rb[0]["subjects"] == [{"kind": "ServiceAccount", "name": "odh-model-controller", "namespace": "redhat-ods-applications"}], "RoleBinding binds the controller ServiceAccount to the ClusterRole in each selected namespace")
check(all(o.get("metadata", {}).get("namespace") is None for o in nobjs), "RoleBinding template carries no namespace (the selector supplies it)")
check(all(c["spec"].get("pruneObjectBehavior") == "DeleteAll" for c in (cr, ns) if c), "both policies prune their objects when removed (pruneObjectBehavior DeleteAll)")
print("publisher-grant tests: %d ok, %d failed" % (7 - fails, fails)); sys.exit(fails)
END_PY
