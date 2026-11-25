#!/usr/bin/env python3
"""Check that Loki retains the full identity dimensions as stream labels.

Renders charts/ai-grid-o11y with helm and asserts the promoted label set on
the LokiStack. Needs helm and PyYAML.
"""

import os
import subprocess
import sys

import yaml

REPO = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
)
CHART = os.path.join(REPO, "charts", "ai-grid-o11y")


def main():
    # The labels promoted by the hub store must stay in lockstep with what the
    # maas-api Loki read proxy scopes its queries by: every proxy query filters
    # on tenant_name, and the organization/user access modes filter on
    # organization_id and user_id.
    expected = {
        "service.name",
        "tenant_name",
        "subscription",
        "organization_id",
        "user_id",
        "model",
        "response_type",
        "kubernetes_namespace_name",
        "cluster_name",
        "cluster_id",
    }

    rendered = subprocess.run(
        ["helm", "template", "usage-logs", CHART],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    for resource in yaml.safe_load_all(rendered):
        if not resource or resource.get("kind") != "LokiStack":
            continue
        assert resource["apiVersion"] == "loki.grafana.com/v1", resource["apiVersion"]
        assert resource["metadata"]["name"] == "usage-logs", resource["metadata"]["name"]

        limits = resource["spec"]["limits"]
        stream_labels = limits["global"]["otlp"]["streamLabels"]["resourceAttributes"]
        labels = {attribute["name"] for attribute in stream_labels}
        assert labels == expected, labels
        assert "identity_source" not in labels
        assert "identity_issuer" not in labels
        assert limits["global"]["retention"]["days"] == 30

        print("identity stream label checks: ok")
        return

    print("LokiStack not found in rendered chart", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
