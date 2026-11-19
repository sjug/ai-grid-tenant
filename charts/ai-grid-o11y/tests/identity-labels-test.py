#!/usr/bin/env python3
"""Check that Loki retains the full identity dimensions as stream labels."""

import os
import subprocess

import yaml


CHART = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def main():
    rendered = subprocess.run(
        ["helm", "template", "ai-grid-o11y", CHART, "--show-only", "templates/lokistack.yaml"],
        check=True, capture_output=True, text=True).stdout
    resource = yaml.safe_load(rendered)

    assert resource["apiVersion"] == "loki.grafana.com/v1"
    assert resource["kind"] == "LokiStack"
    assert resource["metadata"]["name"] == "usage-logs"

    limits = resource["spec"]["limits"]
    stream_labels = limits["global"]["otlp"]["streamLabels"]["resourceAttributes"]
    labels = {attribute["name"] for attribute in stream_labels}
    expected = {
        "service.name",
        "subscription",
        "organization_id",
        "user_id",
        "model",
        "response_type",
        "kubernetes_namespace_name",
        "cluster_name",
        "cluster_id",
    }
    assert labels == expected, labels
    assert "identity_source" not in labels
    assert "identity_issuer" not in labels
    assert limits["global"]["retention"]["days"] == 30

    print("identity stream label checks: ok")


if __name__ == "__main__":
    main()
