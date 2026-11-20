#!/usr/bin/env python3
"""The gateway stats monitor keeps every Envoy family the repository's dashboards query and drops the rest."""
import glob, os, re, sys
import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
policy = os.path.join(ROOT, "apps/rhoai-prerequisites/hub/15-rhoai-source-metrics-policy.yaml")


def find_monitor(node):
    if isinstance(node, dict):
        if node.get("kind") == "PodMonitor" and node.get("metadata", {}).get("name") == "ai-grid-gateway-collector-stats":
            return node
        node = list(node.values())
    if isinstance(node, list):
        for item in node:
            found = find_monitor(item)
            if found:
                return found
    return None


monitor = next(m for m in (find_monitor(d) for d in yaml.safe_load_all(open(policy))) if m)
rules = monitor["spec"]["podMetricsEndpoints"][0]["metricRelabelings"]
keep = [r for r in rules if r["action"] == "keep" and r["sourceLabels"] == ["__name__"]]
assert len(keep) == 1, "expected one __name__ keep rule"
kept = re.compile("^(?:%s)$" % keep[0]["regex"])  # Prometheus anchors relabel regexes

used = set()
for path in glob.glob(os.path.join(ROOT, "apps/acm/manifests/observability/dashboards/*.json")):
    used |= {re.sub(r"_(bucket|sum|count)$", "", n) for n in re.findall(r"envoy_[A-Za-z0-9_]+", open(path).read())}
assert used, "no Envoy families found in the dashboards"

failures = [n for n in sorted(used) if not (kept.match(n) or kept.match(n + "_bucket"))]
for unused in ("envoy_cluster_assignment_stale", "envoy_http_downstream_rq_http1_total", "envoy_runtime_load_success"):
    if kept.match(unused):
        failures.append("unused family kept: " + unused)
for name in failures:
    print("FAIL", name)
print("gateway stats keep-list: %d dashboard families, %d failures" % (len(used), len(failures)))
sys.exit(1 if failures else 0)
