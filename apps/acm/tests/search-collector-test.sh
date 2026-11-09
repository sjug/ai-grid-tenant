#!/usr/bin/env bash
# Renders apps/acm/manifests and checks the search-collector policy: it runs on the hub only,
# changes no ClusterManagementAddOn and creates no KlusterletAddonConfig, and its
# object-templates-raw, executed with Go's text/template and a stubbed lookup over sample
# clusters, asks for the add-on on exactly the clusters it should. No cluster.
# Needs kubectl, go and python3 with PyYAML.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

kubectl kustomize "$HERE/../manifests" > "$TMP_DIR/rendered.yaml"

# ACM resolves object-templates-raw with Go's text/template; lookup lists or gets an object and
# returns nothing, not an error, when it isn't found (stolostron/go-template-utils). This stub
# answers from the fixture and understands the "key!=value" and "key=value" selectors.
mkdir "$TMP_DIR/render"
cat > "$TMP_DIR/render/main.go" <<'END_GO'
package main

import (
	"encoding/json"
	"os"
	"strings"
	"text/template"
)

type fixture struct {
	Objects []map[string]interface{} `json:"objects"`
}

func field(obj map[string]interface{}, keys ...string) interface{} {
	var cur interface{} = obj
	for _, k := range keys {
		m, ok := cur.(map[string]interface{})
		if !ok {
			return nil
		}
		cur = m[k]
	}
	return cur
}

func matches(obj map[string]interface{}, selectors []string) bool {
	labels, _ := field(obj, "metadata", "labels").(map[string]interface{})
	for _, s := range selectors {
		for _, term := range strings.Split(s, ",") {
			if k, v, ok := strings.Cut(term, "!="); ok {
				if labels[k] == v {
					return false
				}
			} else if k, v, ok := strings.Cut(term, "="); ok {
				if labels[k] != v {
					return false
				}
			}
		}
	}
	return true
}

func main() {
	raw, _ := os.ReadFile(os.Args[1])
	data, _ := os.ReadFile(os.Args[2])
	var fx fixture
	if err := json.Unmarshal(data, &fx); err != nil {
		panic(err)
	}
	lookup := func(apiVersion, kind, namespace, name string, selectors ...string) (map[string]interface{}, error) {
		var items []interface{}
		for _, o := range fx.Objects {
			ns, _ := field(o, "metadata", "namespace").(string)
			if o["apiVersion"] != apiVersion || o["kind"] != kind || ns != namespace {
				continue
			}
			if name != "" {
				if field(o, "metadata", "name") == name {
					return o, nil
				}
				continue
			}
			if matches(o, selectors) {
				items = append(items, o)
			}
		}
		if name != "" {
			return nil, nil
		}
		return map[string]interface{}{"items": items}, nil
	}
	tmpl := template.Must(template.New("raw").Funcs(template.FuncMap{"lookup": lookup}).Parse(string(raw)))
	if err := tmpl.Execute(os.Stdout, nil); err != nil {
		panic(err)
	}
}
END_GO

python3 - "$TMP_DIR/rendered.yaml" "$TMP_DIR" <<'PY'
import json
import subprocess
import sys
import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
tmp = sys.argv[2]
fails = 0
total = 0


def check(cond, name, detail=""):
    global fails, total
    total += 1
    print(("   ok   " if cond else "   FAIL ") + name + ("" if cond else "  " + str(detail)))
    fails += 0 if cond else 1


def find(kind, name):
    return next((d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name), None)


def wave(d):
    return int(d["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"])


policy = find("Policy", "search-collector")
binding = find("PlacementBinding", "search-collector")
placement = find("Placement", "search-collector-hub")
check(policy and binding and placement, "Policy, PlacementBinding and Placement rendered")

check(binding["placementRef"] == {"apiGroup": "cluster.open-cluster-management.io", "kind": "Placement",
                                  "name": "search-collector-hub"}
      and binding["subjects"] == [{"apiGroup": "policy.open-cluster-management.io", "kind": "Policy",
                                   "name": "search-collector"}],
      "PlacementBinding binds the policy to the hub Placement")
check(placement["spec"] == {"clusterSets": ["global"], "predicates": [{"requiredClusterSelector": {
          "labelSelector": {"matchLabels": {"local-cluster": "true"}}}}]},
      "Placement selects the hub only (local-cluster=true)", placement["spec"])

binding_global = find("ManagedClusterSetBinding", "global")
check(binding_global and binding_global["metadata"]["namespace"] == placement["metadata"]["namespace"]
      and wave(binding_global) < wave(placement) < wave(policy) == wave(binding),
      "global set bound in the Placement's namespace; waves binding < Placement < Policy")
policy_addons = [d for d in docs if d["kind"] == "ClusterManagementAddOn"]
check(all(wave(d) < wave(policy) for d in policy_addons),
      "Policy syncs after the policy add-ons' ClusterManagementAddOns")

check(not any(d["kind"] == "ClusterManagementAddOn" and d["metadata"]["name"] == "search-collector"
              for d in docs), "ClusterManagementAddOn search-collector is not managed (MCH owns it)")
check(not any(d["kind"] == "KlusterletAddonConfig" for d in docs), "no KlusterletAddonConfig")

templates = policy["spec"]["policy-templates"]
check(len(templates) == 1, "one ConfigurationPolicy")
cp = templates[0]["objectDefinition"]["spec"]
check(policy["spec"]["remediationAction"] == "enforce" and cp["remediationAction"] == "enforce",
      "enforced")
check(cp.get("pruneObjectBehavior") == "DeleteIfCreated", "prunes only the add-ons it created")
check("object-templates" not in cp and "object-templates-raw" in cp, "objects come from object-templates-raw")

MC = "cluster.open-cluster-management.io/v1"
KAC = "agent.open-cluster-management.io/v1"


def cluster(name, labels=None, deleting=False):
    meta = {"name": name, "labels": labels or {}}
    if deleting:
        meta["deletionTimestamp"] = "2026-11-05T00:00:00Z"
    return {"apiVersion": MC, "kind": "ManagedCluster", "metadata": meta}


def namespace(name):
    return {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": name}}


def kac(name):
    return {"apiVersion": KAC, "kind": "KlusterletAddonConfig", "metadata": {"name": name, "namespace": name}}


def render(objects):
    open(tmp + "/raw.tmpl", "w").write(cp["object-templates-raw"])
    json.dump({"objects": objects}, open(tmp + "/fixture.json", "w"))
    out = subprocess.run(["go", "run", tmp + "/render/main.go", tmp + "/raw.tmpl", tmp + "/fixture.json"],
                         check=True, capture_output=True, text=True).stdout
    return yaml.safe_load(out) or []


hub_only = [cluster("hub", {"local-cluster": "true"}), namespace("hub"), kac("hub")]
check(render(hub_only) == [], "hub alone: no add-on")

sites = hub_only + [
    cluster("site-a", {"ai-grid/enabled": "true", "ai-grid/role": "ingress"}), namespace("site-a"),
    cluster("site-b", {"ai-grid/enabled": "true"}), namespace("site-b"), kac("site-b"),
    cluster("site-c", {}, deleting=True), namespace("site-c"),
    cluster("site-d", {}),
    cluster("site-e", {}), namespace("site-e"),
]
rendered = render(sites)
got = sorted(t["objectDefinition"]["metadata"]["namespace"] for t in rendered)
check(got == ["site-a", "site-e"],
      "add-on for every cluster but the hub, one with a KlusterletAddonConfig, one being deleted "
      "and one without a namespace", got)
check(all(t["complianceType"] == "musthave" and t["objectDefinition"] == {
          "apiVersion": "addon.open-cluster-management.io/v1alpha1", "kind": "ManagedClusterAddOn",
          "metadata": {"name": "search-collector", "namespace": t["objectDefinition"]["metadata"]["namespace"]},
          "spec": {"installNamespace": "open-cluster-management-agent-addon"}} for t in rendered),
      "each is a musthave ManagedClusterAddOn search-collector, as the klusterlet-addon-controller writes it")

print("search-collector tests: %d ok, %d failed" % (total - fails, fails))
sys.exit(fails)
PY
