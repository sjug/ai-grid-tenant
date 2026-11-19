#!/usr/bin/env bash
# Asserts the shape of the serving gateway's Grid client CA copy in the prerequisites Policy (no cluster). Needs PyYAML.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$HERE/../hub/03-policy.yaml" "$HERE/../../rhoai/roles" <<'END_PY'
import sys, yaml
fails = 0
def check(cond, name):
    global fails
    print(("   ok   " if cond else "   FAIL ") + name); fails += 0 if cond else 1
pols = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Policy"]
byname = {t["objectDefinition"]["metadata"]["name"]: t["objectDefinition"]
          for p in pols for t in p["spec"]["policy-templates"]}
cp = byname.get("serving-gateway-grid-client-ca")
check(cp is not None, "ConfigurationPolicy present")
raw = cp["spec"].get("object-templates-raw", "") if cp else ""
check('lookup "v1" "Secret" "redhat-ai-grid" "grid-ca"' in raw
      and 'lookup "v1" "Secret" "openshift-ingress" "openshift-ai-inference-service-tls"' in raw,
      "copies only where the Grid CA and the serving certificate both exist")
body = "\n".join(line for line in raw.splitlines() if not line.lstrip().startswith("{{-"))
objs = [o["objectDefinition"] for o in yaml.safe_load(body) or []]
check(len(objs) == 1 and objs[0]["kind"] == "Secret" and objs[0]["type"] == "Opaque", "writes exactly one Opaque Secret")
secret = objs[0] if objs else {"metadata": {}, "data": {}}
check(secret["data"] == {"cacert": '{{ fromSecret "redhat-ai-grid" "grid-ca" "ca.crt" }}'},
      "copies only the public ca.crt, under the key the mesh reads")
check("tls.key" not in raw and "grid-ca-key" not in raw and "grid-site-identity" not in raw, "reads no private key")
for role in ("inference", "combined"):
    values = yaml.safe_load(open(f"{sys.argv[2]}/{role}.yaml"))
    grid = [l for l in values["components"]["kserve"]["gateway"]["spec"]["listeners"] if l["name"] == "grid"]
    refs = [ref["name"] for l in grid for ref in l["tls"]["certificateRefs"]]
    check(refs == [secret["metadata"].get("name", "").removesuffix("-cacert")] and secret["metadata"].get("namespace") == "openshift-ingress",
          f"{role}: the Secret is the grid listener's certificate name plus -cacert, in the gateway's namespace")
check(cp is not None and cp["spec"].get("pruneObjectBehavior") == "DeleteAll", "the copy is pruned when the policy is removed")
print("serving-gateway-ca tests: %d ok, %d failed" % (8 - fails, fails)); sys.exit(fails)
END_PY
