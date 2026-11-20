#!/usr/bin/env python3
"""The chart's fleet dashboards use their own Perses identities; RHOAI's are never pruned or deleted by Argo CD."""
import os, subprocess, sys
import yaml

CHART = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
VALUES = os.path.abspath(os.path.join(CHART, "..", "..", "values", "hub", "ai-grid-o11y", "values.yaml"))
LEGACY = {("PersesDatasource", "cluster-prometheus-datasource"), ("PersesDashboard", "dashboard-0-cluster-admin"),
          ("PersesDashboard", "dashboard-1-model-admin")}
FLEET_DS = "ai-grid-acm-prometheus"
FLEET = {"dashboard-0-ai-grid-fleet-cluster-admin": 25, "dashboard-1-ai-grid-fleet-models-admin": 21}

out = subprocess.run(["helm", "template", "ai-grid-o11y", CHART, "-f", VALUES], check=True, capture_output=True, text=True).stdout
docs = [d for d in yaml.safe_load_all(out) if d]
failures = []


def check(cond, msg):
    print(("   ok   " if cond else "   FAIL ") + msg)
    if not cond:
        failures.append(msg)


ids = [(d["kind"], d["metadata"].get("namespace"), d["metadata"].get("name") or d["metadata"].get("generateName")) for d in docs]
check(len(ids) == len(set(ids)), "every rendered identity is unique")
perses = {(d["kind"], d["metadata"]["name"]): d for d in docs if d["kind"].startswith("Perses")}


def refs(node):
    if isinstance(node, dict):
        if node.get("kind") == "PrometheusDatasource" and "name" in node:
            yield node["name"]
        for v in node.values():
            yield from refs(v)
    elif isinstance(node, list):
        for v in node:
            yield from refs(v)


ds = perses.get(("PersesDatasource", FLEET_DS))
check(ds is not None, "fleet datasource %s rendered" % FLEET_DS)
if ds:
    proxy = ds["spec"]["config"]["plugin"]["spec"]["proxy"]["spec"]
    check(proxy["url"] == "https://rbac-query-proxy.open-cluster-management-observability.svc:8443",
          "fleet datasource uses the query proxy's authenticated HTTPS listener")
    ca = ds["spec"]["client"]["tls"]["caCert"]
    check(ds["spec"]["client"]["tls"]["enable"] and ca == {"type": "configmap", "name": "openshift-service-ca-bundle",
          "namespace": "redhat-ods-monitoring", "certPath": "service-ca.crt"}, "fleet datasource verifies the service CA")
    check(ds["spec"]["config"]["default"] is False, "fleet datasource is not the default")
    check(proxy.get("secret") == FLEET_DS + "-secret", "fleet datasource names its own Perses secret")

for name, count in FLEET.items():
    d = perses.get(("PersesDashboard", name))
    check(d is not None, "fleet dashboard %s rendered" % name)
    if d:
        r = list(refs(d["spec"]))
        check(len(r) == count and set(r) == {FLEET_DS}, "%s: %d references, all to %s" % (name, count, FLEET_DS))

# Revision 1 (bridge) protects all three legacy objects; revision 2 (handoff hooks present) renders none of them.
final = any(d["kind"] == "Job" and d["metadata"].get("name") == "ai-grid-o11y-perses-handoff-guard" for d in docs)
print("   revision: %s" % ("2, handoff" if final else "1, bridge"))
for kind, name in sorted(LEGACY):
    d = perses.get((kind, name))
    if final:
        check(d is None, "%s/%s no longer rendered" % (kind, name))
        continue
    check(d is not None and d["metadata"].get("namespace") == "redhat-ods-monitoring",
          "%s/%s still rendered in redhat-ods-monitoring" % (kind, name))
    opts = (d or {}).get("metadata", {}).get("annotations", {}).get("argocd.argoproj.io/sync-options", "")
    check({"Prune=false", "Delete=false"} <= set(opts.split(",")), "%s/%s protected with Prune=false,Delete=false" % (kind, name))

print("perses ownership tests: %d failed" % len(failures))
sys.exit(1 if failures else 0)
