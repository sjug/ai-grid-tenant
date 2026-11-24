#!/usr/bin/env python3
"""Every ConfigurationPolicy that selects namespaces must state terminatingInclusion; needs PyYAML.

The ConfigurationPolicy API defaults an omitted namespaceSelector.terminatingInclusion to Default. ACM 2.17 leaves
that field unset when it compares a template with the stored spec. When this omission is the only mismatch, the API
can return the same resourceVersion after the update, and the template sync then skips the status reset that would
prompt a new compliance event, so a template-error from an earlier failed update can stay on the policy. Stating
the default removes that mismatch.
"""
from pathlib import Path

import yaml

root = Path(__file__).resolve().parents[1]
found = []


def walk(node, path):
    if isinstance(node, dict):
        spec = node.get('spec')
        if node.get('kind') == 'ConfigurationPolicy' and isinstance(spec, dict) and 'namespaceSelector' in spec:
            name = (node.get('metadata') or {}).get('name')
            selector = spec['namespaceSelector']
            assert isinstance(selector, dict) and selector.get('terminatingInclusion') == 'Default', \
                f'{path}: ConfigurationPolicy {name} must set namespaceSelector.terminatingInclusion: Default'
            found.append((path, name))
        for value in node.values():
            walk(value, path)
    elif isinstance(node, list):
        for value in node:
            walk(value, path)


for file in sorted((root / 'apps').rglob('*.yaml')):
    text = file.read_text()
    if 'ConfigurationPolicy' not in text or 'namespaceSelector' not in text:
        continue
    relative = file.relative_to(root)
    try:
        documents = list(yaml.safe_load_all(text))
    except yaml.YAMLError as error:
        # A Helm template is not YAML until rendered; none selects namespaces in a ConfigurationPolicy today.
        raise AssertionError(f'{relative}: render this template before checking it') from error
    for document in documents:
        walk(document, relative)

assert found, 'expected at least one ConfigurationPolicy with a namespaceSelector'
print(f'PASS: {len(found)} ConfigurationPolicies with a namespaceSelector state terminatingInclusion: Default')
