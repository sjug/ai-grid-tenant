#!/usr/bin/env python3
"""Render the KServe module operator memory report with synthetic lookups; needs Helm and PyYAML (RHOAIENG-103335)."""
from pathlib import Path
import copy
import json
import re
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[3]
hub = root / 'apps/rhoai-prerequisites/hub'
docs = [d for d in yaml.safe_load_all((hub / '17-kserve-module-memory-policy.yaml').read_text()) if d]
by_kind = {d['kind']: d for d in docs}
assert sorted(by_kind) == ['Placement', 'PlacementBinding', 'Policy'] and len(docs) == 3
policy, placement, binding = by_kind['Policy'], by_kind['Placement'], by_kind['PlacementBinding']
# ACM would create a missing named object, so this policy must never write: the script does that.
assert policy['spec']['remediationAction'] == 'inform' and policy['spec']['disabled'] is False
assert binding['placementRef']['name'] == placement['metadata']['name']
assert [s['name'] for s in binding['subjects']] == [policy['metadata']['name']]
# The hub only, selected by label and never by cluster name.
selector = placement['spec']['predicates'][0]['requiredClusterSelector']['labelSelector']
assert selector == {'matchLabels': {'ai-grid/enabled': 'true', 'local-cluster': 'true'}}, selector
assert 'clusterNames' not in json.dumps(placement['spec'])

entries = policy['spec']['policy-templates']
assert len(entries) == 1 and sorted(entries[0]) == ['objectDefinition']
template = entries[0]['objectDefinition']
assert template['kind'] == 'ConfigurationPolicy'
assert template['spec']['remediationAction'] == 'inform', 'the policy must only report'
assert template['spec']['pruneObjectBehavior'] == 'None', 'withdrawing the policy must not delete the Deployment'
assert 'object-templates' not in template['spec'], 'report only on the Deployment the Platform controls'

# The value reported here is the one the script sets.
script = (root / 'apps/rhoai-prerequisites/set-kserve-module-memory.sh').read_text()
TARGET = re.search(r'^target=(\S+)$', script, re.M).group(1)
assert re.search(r'^shipped=1Gi$', script, re.M) and TARGET == '2Gi', 'the policy and the script must agree'

PLATFORM = 'lookup "config.opendatahub.io/v1alpha2" "Platform" "" "default"'
LIVE = 'lookup "apps/v1" "Deployment" "redhat-ods-applications" "kserve-module-controller-manager"'
raw = template['spec']['object-templates-raw']
for call, replacement in {PLATFORM: 'index $.Values "platform" | default dict',
                          LIVE: 'index $.Values "live" | default dict'}.items():
    assert raw.count(call) == 1, f'expected exactly one {call}'
    raw = raw.replace(call, replacement)
assert 'lookup' not in raw and '{{hub' not in raw


def render(objects):
    with tempfile.TemporaryDirectory(prefix='kserve-module-memory-test-') as directory:
        chart = Path(directory)
        (chart / 'templates').mkdir()
        (chart / 'Chart.yaml').write_text('apiVersion: v2\nname: kserve-module-memory-test\nversion: 0.1.0\n')
        (chart / 'templates/policy.yaml').write_text(
            '{{- define "memory" -}}\n' + raw + '\n{{- end }}\nobjects:\n{{ include "memory" . | indent 2 }}\n')
        (chart / 'values.json').write_text(json.dumps(objects))
        output = subprocess.check_output(
            ['helm', 'template', 'test', str(chart), '-f', str(chart / 'values.json')], text=True)
        return yaml.safe_load(output)['objects'] or []


UID = 'platform-uid'
owned = {
    'platform': {'metadata': {'name': 'default', 'uid': UID}},
    # What the product ships: the CPU values and the memory request stay outside the report.
    'live': {'metadata': {'name': 'kserve-module-controller-manager', 'namespace': 'redhat-ods-applications',
                          'ownerReferences': [{'apiVersion': 'config.opendatahub.io/v1alpha2', 'kind': 'Platform',
                                               'name': 'default', 'uid': UID, 'controller': True}]},
             'spec': {'template': {'spec': {'containers': [
                 {'name': 'manager', 'resources': {'limits': {'cpu': '500m', 'memory': '1Gi'},
                                                   'requests': {'cpu': '100m', 'memory': '256Mi'}}}]}}}},
}
expected = [{'complianceType': 'musthave', 'objectDefinition': {
    'apiVersion': 'apps/v1', 'kind': 'Deployment',
    'metadata': {'name': 'kserve-module-controller-manager', 'namespace': 'redhat-ods-applications'},
    'spec': {'template': {'spec': {'containers': [{'name': 'manager',
                                                   'resources': {'limits': {'memory': TARGET}}}]}}}}}]
assert render(owned) == expected, render(owned)
print('PASS: a Deployment controlled by the Platform -> one musthave with the manager memory limit only')


def case(label, mutate):
    objects = copy.deepcopy(owned)
    mutate(objects)
    assert render(objects) == [], f'{label}: must render nothing'
    print(f'PASS: {label} -> nothing rendered')


owner = lambda o: o['live']['metadata']['ownerReferences'][0]  # noqa: E731
case('no Platform', lambda o: o.pop('platform'))
case('terminating Platform', lambda o: o['platform']['metadata'].update(deletionTimestamp='2026-01-01T00:00:00Z'))
case('no Deployment', lambda o: o.pop('live'))
case('Deployment without owners', lambda o: o['live']['metadata'].pop('ownerReferences'))
case('Deployment owned by another Platform', lambda o: owner(o).update(uid='other'))
case('Deployment owned by another kind', lambda o: owner(o).update(kind='DataScienceCluster'))
case('Platform owner without the controller flag', lambda o: owner(o).pop('controller'))
case('Platform owner that is not the controller', lambda o: owner(o).update(controller=False))
case('Platform without a UID', lambda o: (o['platform']['metadata'].pop('uid'), owner(o).pop('uid')))
case('terminating Deployment', lambda o: o['live']['metadata'].update(deletionTimestamp='2026-01-01T00:00:00Z'))

patched = copy.deepcopy(owned)
patched['live']['metadata']['ownerReferences'].insert(0, {'kind': 'Other', 'name': 'x', 'uid': 'y'})
patched['live']['spec']['template']['spec']['containers'][0]['resources']['limits']['memory'] = TARGET
assert render(patched) == expected
print('PASS: an extra owner and an already patched Deployment render the same musthave')
print('Local rendering only; ACM matching the container by name and the Platform keeping the limit need live validation.')
