#!/usr/bin/env python3
"""Render the monitoring memory report templates with synthetic lookups; needs Helm and PyYAML (RHOAIENG-104114)."""
from pathlib import Path
import copy
import json
import re
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[3]
hub = root / 'apps/rhoai-prerequisites/hub'
docs = [d for d in yaml.safe_load_all((hub / '16-monitoring-memory-policy.yaml').read_text()) if d]
by_kind = {d['kind']: d for d in docs}
assert sorted(by_kind) == ['Placement', 'PlacementBinding', 'Policy'] and len(docs) == 3
policy, placement, binding = by_kind['Policy'], by_kind['Placement'], by_kind['PlacementBinding']
# ACM would create a missing named object, so this policy must never write: the script does that.
assert policy['spec']['remediationAction'] == 'inform' and policy['spec']['disabled'] is False
assert binding['placementRef']['name'] == placement['metadata']['name']
assert [s['name'] for s in binding['subjects']] == [policy['metadata']['name']]
# The same sites as the RHOAI Applications, on the pattern of the OTel compatibility policy.
reference = next(d for d in yaml.safe_load_all((hub / '12-otel-cert-manager-policy.yaml').read_text())
                 if d and d['kind'] == 'Placement')
assert placement['spec'] == reference['spec'], 'Placement must match the RHOAI Grid membership'

NAMESPACE, UID = 'observability', 'monitoring-uid'
TARGETS = {
    'rhoai-collector-memory': ('opentelemetry.io/v1beta1', 'OpenTelemetryCollector', 'data-science-collector',
                               {'requests': {'memory': '2Gi'}, 'limits': {'memory': '6Gi'}}),
    'rhoai-prometheus-memory': ('monitoring.rhobs/v1alpha1', 'MonitoringStack', 'data-science-monitoringstack',
                                {'requests': {'memory': '1Gi'}, 'limits': {'memory': '2Gi'}}),
}
entries = {t['objectDefinition']['metadata']['name']: t for t in policy['spec']['policy-templates']}
assert sorted(entries) == sorted(TARGETS)
templates = {name: entry['objectDefinition'] for name, entry in entries.items()}
MONITORING = 'lookup "services.platform.opendatahub.io/v1alpha1" "Monitoring" "" "default-monitoring"'


def render(raw, objects):
    with tempfile.TemporaryDirectory(prefix='monitoring-memory-test-') as directory:
        chart = Path(directory)
        (chart / 'templates').mkdir()
        (chart / 'Chart.yaml').write_text('apiVersion: v2\nname: monitoring-memory-test\nversion: 0.1.0\n')
        (chart / 'templates/policy.yaml').write_text(
            '{{- define "memory" -}}\n' + raw + '\n{{- end }}\nobjects:\n{{ include "memory" . | indent 2 }}\n')
        (chart / 'values.json').write_text(json.dumps(objects))
        output = subprocess.check_output(
            ['helm', 'template', 'test', str(chart), '-f', str(chart / 'values.json')], text=True)
        return yaml.safe_load(output)['objects'] or []


def stub(name, raw, calls):
    # ACM returns an empty map for a missing object; Helm executes the real Go/Sprig branches.
    for call, replacement in calls.items():
        assert raw.count(call) == 1, f'{name}: expected exactly one {call}'
        raw = raw.replace(call, replacement)
    assert 'lookup' not in raw, f'{name}: unexpected extra lookup'
    assert '{{hub' not in raw, f'{name}: ownership must be read on the managed cluster'
    return raw


monitoring = {'metadata': {'name': 'default-monitoring', 'uid': UID}, 'spec': {'namespace': NAMESPACE}}

# The values reported here are the ones the script sets.
script = (root / 'apps/rhoai-prerequisites/set-monitoring-memory.sh').read_text()
script_targets = {m.group(2): {'requests': {'memory': m.group(3)}, 'limits': {'memory': m.group(4)}}
                  for m in re.finditer(r'^  "(\S+) (\S+) (\S+) (\S+)"$', script, re.M)}
assert script_targets == {target: resources for _, _, target, resources in TARGETS.values()}, \
    'The policy and set-monitoring-memory.sh must agree on names and values'

for name, (api, kind, target, resources) in TARGETS.items():
    template = templates[name]
    assert sorted(entries[name]) == ['objectDefinition']
    assert template['kind'] == 'ConfigurationPolicy'
    assert template['spec']['remediationAction'] == 'inform', f'{name}: the policy must only report'
    assert template['spec']['pruneObjectBehavior'] == 'None', 'Withdrawing the policy must not delete the object'
    assert 'object-templates' not in template['spec'], 'Report only on the object that Monitoring controls'
    raw = stub(name, template['spec']['object-templates-raw'], {
        MONITORING: 'index $.Values "monitoring" | default dict',
        f'lookup "{api}" "{kind}" $namespace "{target}"': 'index $.Values "live" | default dict',
    })

    owned = {
        'monitoring': copy.deepcopy(monitoring),
        # What the product ships: both CPU values and the small memory values stay outside the patch.
        'live': {'metadata': {'name': target, 'namespace': NAMESPACE,
                              'ownerReferences': [{'kind': 'Monitoring', 'name': 'default-monitoring', 'uid': UID,
                                                   'controller': True}]},
                 'spec': {'resources': {'limits': {'cpu': 1, 'memory': '256Mi'},
                                        'requests': {'cpu': '100m', 'memory': '256Mi'}}}},
    }
    expected = [{'complianceType': 'musthave', 'objectDefinition': {
        'apiVersion': api, 'kind': kind,
        'metadata': {'name': target, 'namespace': NAMESPACE, 'annotations': {'opendatahub.io/managed': 'false'}},
        'spec': {'resources': resources}}}]
    rendered = render(raw, owned)
    assert rendered == expected, f'{name}: expected only the annotation and the two memory values'
    assert isinstance(rendered[0]['objectDefinition']['metadata']['annotations']['opendatahub.io/managed'], str)
    print(f'PASS: {name}: an object controlled by Monitoring -> one musthave with the annotation and the memory values')

    def case(label, mutate):
        objects = copy.deepcopy(owned)
        mutate(objects)
        assert render(raw, objects) == [], f'{name}: {label}: must render nothing'
        print(f'PASS: {name}: {label} -> nothing rendered')

    owner = lambda o: o['live']['metadata']['ownerReferences'][0]  # noqa: E731
    case('no Monitoring', lambda o: o.pop('monitoring'))
    case('Monitoring without a namespace', lambda o: o['monitoring']['spec'].pop('namespace'))
    case('terminating Monitoring', lambda o: o['monitoring']['metadata'].update(deletionTimestamp='2026-01-01T00:00:00Z'))
    case('no object', lambda o: o.pop('live'))
    case('object without owners', lambda o: o['live']['metadata'].pop('ownerReferences'))
    case('object owned by another Monitoring', lambda o: owner(o).update(uid='other'))
    case('object owned by another kind', lambda o: owner(o).update(kind='Deployment'))
    case('Monitoring owner without the controller flag', lambda o: owner(o).pop('controller'))
    case('Monitoring owner that is not the controller', lambda o: owner(o).update(controller=False))
    case('Monitoring as a plain owner beside another controller', lambda o: (
        owner(o).update(controller=False),
        o['live']['metadata']['ownerReferences'].append({'kind': 'Other', 'name': 'x', 'uid': 'y', 'controller': True})))
    case('Monitoring without a UID', lambda o: (o['monitoring']['metadata'].pop('uid'), owner(o).pop('uid')))
    case('terminating object', lambda o: o['live']['metadata'].update(deletionTimestamp='2026-01-01T00:00:00Z'))

    # A second, plain owner must not hide the controlling Monitoring, and an already patched object stays patched.
    extra = copy.deepcopy(owned)
    extra['live']['metadata']['ownerReferences'].insert(0, {'kind': 'Other', 'name': 'x', 'uid': 'y'})
    extra['live']['metadata']['annotations'] = {'opendatahub.io/managed': 'false'}
    extra['live']['spec']['resources'] = {'limits': {'cpu': 1, **resources['limits']},
                                          'requests': {'cpu': '100m', **resources['requests']}}
    assert render(raw, extra) == expected
    print(f'PASS: {name}: an extra owner and an already patched object render the same musthave')
print('Local rendering only; the module leaving the patched objects alone needs live validation.')
