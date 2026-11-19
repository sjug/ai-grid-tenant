#!/usr/bin/env python3
"""Render the mirror policy with Infrastructure fixtures; needs Helm and PyYAML."""
from pathlib import Path
import json
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[3]
policy = yaml.safe_load((root / 'apps/rhoai-prerequisites/hub/03-policy.yaml').read_text())
mirror = next(item['objectDefinition'] for item in policy['spec']['policy-templates']
              if item['objectDefinition']['metadata']['name'] == 'rhoai-image-mirror')
assert mirror['spec']['pruneObjectBehavior'] == 'DeleteAll', 'Preserve existing conventional pruning'
raw = mirror['spec']['object-templates-raw']
lookup = 'lookup "config.openshift.io/v1" "Infrastructure" "" "cluster"'
assert raw.count(lookup) == 1, 'Detect topology on the managed cluster'
assert '{{hub' not in raw, 'Hub topology must not select the managed cluster branch'


def render(topology=None, infra_fixture="default"):
    infrastructure = {'status': {'controlPlaneTopology': topology}}
    if infra_fixture in ('missing', 'no-status'):
        infrastructure = {}
    elif infra_fixture == 'empty-status':
        infrastructure = {'status': {}}
    elif infra_fixture == 'no-topology':
        infrastructure = {'status': {'platformStatus': {}}}
    # Substitute only Kubernetes lookup; Helm executes the actual Go/Sprig branches.
    with tempfile.TemporaryDirectory(prefix='image-mirror-test-') as directory:
        chart = Path(directory)
        (chart / 'templates').mkdir()
        (chart / 'Chart.yaml').write_text('apiVersion: v2\nname: mirror-test\nversion: 0.1.0\n')
        (chart / 'templates/policy.yaml').write_text(
            '{{- define "infrastructure" -}}{{ .Values.infrastructure | default dict | toJson }}{{- end -}}\n'
            + '{{- define "mirror" -}}\n' + raw.replace(lookup, '(include "infrastructure" . | fromJson)')
            + '\n{{- end }}\nobjects:\n{{ include "mirror" . | indent 2 }}\n')
        values = {} if infra_fixture == 'missing' else {'infrastructure': infrastructure}
        (chart / 'values.json').write_text(json.dumps(values))
        output = subprocess.check_output(
            ['helm', 'template', 'test', str(chart), '-f', str(chart / 'values.json')], text=True)
        return yaml.safe_load(output)['objects']


sources = ['rhoai', 'rhaii', 'rhaii-early-access', 'rhaii-fast']
mappings = [{'source': 'registry.redhat.io/' + source,
             'mirrors': [('quay.io/' if source == 'rhoai' else 'registry.stage.redhat.io/') + source]}
            for source in sources]
expected = [{'complianceType': 'musthave', 'objectDefinition': {
    'apiVersion': 'config.openshift.io/v1', 'kind': 'ImageDigestMirrorSet',
    'metadata': {'name': 'quay-registry'},
    'spec': {'imageDigestMirrors': [dict(item, mirrorSourcePolicy='NeverContactSource')
                                  for item in mappings]}}}]
for topology in ['HighlyAvailable', 'SingleReplica']:
    assert render(topology) == expected, f'{topology}: conventional enforcement changed'
print('PASS: conventional clusters retain exact named mappings and NeverContactSource')

for fixture in ['missing', 'no-status', 'empty-status', 'no-topology']:
    assert render(infra_fixture=fixture) == expected, f'{fixture}: topology fallback changed'
    print(f'PASS: infrastructure lookup fixture {fixture}')

hcp = render('External')
assert len(hcp) == 1 and hcp[0]['complianceType'] == 'musthave'
obj = hcp[0]['objectDefinition']
assert obj['apiVersion'] == 'config.openshift.io/v1'
assert obj['kind'] == 'ImageDigestMirrorSet'
assert not obj.get('metadata', {}).get('name'), 'Named templates would enforce guest writes'
assert obj['spec']['imageDigestMirrors'] == mappings, 'Require all four service-managed mappings'
print('PASS: HCP uses an unnamed inform-only template requiring all four mappings')
print('PASS: existing pruning setting retained; HCP service name and source-fallback policy are not required')
print('Local rendering only; ACM compliance and service-managed rollout need live validation.')
