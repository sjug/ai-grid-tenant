#!/usr/bin/env python3
"""Render the real credential template with synthetic API data; needs Helm and PyYAML."""
import base64
import copy
import json
from pathlib import Path
import re
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[3]
policy = yaml.safe_load((root / 'apps/rhoai-prerequisites/hub/03-policy.yaml').read_text())
credential = next(item['objectDefinition'] for item in policy['spec']['policy-templates']
                  if item['objectDefinition']['metadata']['name'] == 'rhoai-global-pull-secret')
assert credential['spec'].get('pruneObjectBehavior', 'None') == 'None'
raw = credential['spec']['object-templates-raw']
assert '{{hub' not in raw, 'Use managed-cluster topology, not hub topology'
# Replace API calls at the template boundary; Helm supplies the real Sprig merge functions.
argument = r'(?:"[^"\n]*"|\$[A-Za-z][A-Za-z0-9]*)'
for function, count in [('lookup', 4), ('fromSecret', 3)]:
    pattern = rf'\b{function}\s+' + r'\s+'.join([f'({argument})'] * count)
    raw = re.sub(pattern, lambda match: '(include "' + function + '" (list . '
                 + ' '.join(match.groups()) + ')' + (' | fromJson)' if function == 'lookup' else ')'), raw)
raw = raw.replace('base64dec', 'b64dec').replace('base64enc', 'b64enc')
helpers = '''
{{- define "lookup" -}}
{{- $objects := (index . 0).Values.objects -}}
{{- $key := join "|" (slice . 1) -}}
{{- get $objects $key | default dict | toJson -}}
{{- end -}}
{{- define "fromSecret" -}}
{{- $objects := (index . 0).Values.objects -}}
{{- $key := printf "v1|Secret|%s|%s" (index . 1) (index . 2) -}}
{{- index (get $objects $key).data (index . 3) -}}
{{- end -}}
'''


def secret(config):
    return {'data': {'.dockerconfigjson': base64.b64encode(json.dumps(config).encode()).decode()}}


source_key = 'v1|Secret|openshift-marketplace|rhoai-catalog-pull-secret'
normal_key = 'v1|Secret|openshift-config|pull-secret'
hcp_key = 'v1|Secret|kube-system|additional-pull-secret'
original = {'auths': {'registry.redhat.io': {'auth': 'synthetic-original'}}}
source = {'auths': {'quay.io': {'auth': 'synthetic-quay'},
                    'registry.stage.redhat.io': {'auth': 'synthetic-stage'}}}
existing = {'auths': {'quay.io': {'auth': 'synthetic-broad'},
                      'quay.io/rhoai': {'auth': 'synthetic-old'},
                      'registry.redhat.io': {'auth': 'synthetic-redhat'},
                      'example.com': {'auth': 'synthetic-unrelated'}},
            'HttpHeaders': {'X-Test': 'preserved'}}


def render(topology, target=None, input_config=source, empty_input=False, infra_fixture="default"):
    objects = {'config.openshift.io/v1|Infrastructure||cluster':
               {'status': {'controlPlaneTopology': topology}},
               'v1|Secret|kube-system|original-pull-secret': secret(original),
               'v1|Secret|kube-system|global-pull-secret': secret(original)}
    infra_key = 'config.openshift.io/v1|Infrastructure||cluster'
    if infra_fixture == 'missing':
        objects.pop(infra_key)
    elif infra_fixture == 'no-status':
        objects[infra_key] = {}
    elif infra_fixture == 'empty-status':
        objects[infra_key] = {'status': {}}
    elif infra_fixture == 'no-topology':
        objects[infra_key] = {'status': {'platformStatus': {}}}
    # Deliberately supply a different guest global Secret on HCP: it must not be copied.
    if topology == 'External':
        objects[normal_key] = secret(original)
    if input_config is not None:
        objects[source_key] = secret(input_config)
    if empty_input:
        objects[source_key] = {"data": {".dockerconfigjson": ""}}
    if target is not None:
        objects[hcp_key if topology == 'External' else normal_key] = secret(target)
    with tempfile.TemporaryDirectory(prefix='pull-secret-test-') as directory:
        chart = Path(directory)
        (chart / 'templates').mkdir()
        (chart / 'Chart.yaml').write_text('apiVersion: v2\nname: secret-test\nversion: 0.1.0\n')
        (chart / 'templates/policy.yaml').write_text(helpers + '\n{{- define "policy" -}}\n'
            + raw + '\n{{- end }}\nobjects:\n{{ include "policy" . | indent 2 }}\n')
        (chart / 'values.json').write_text(json.dumps({'objects': objects}))
        output = subprocess.check_output(
            ['helm', 'template', 'test', str(chart), '-f', str(chart / 'values.json')], text=True)
        templates = yaml.safe_load(output)['objects']
    if not templates:
        return None
    assert len(templates) == 1
    result = templates[0]['objectDefinition']
    assert result['kind'] == 'Secret' and result['type'] == 'kubernetes.io/dockerconfigjson'
    config = json.loads(base64.b64decode(result['data']['.dockerconfigjson']))
    return result['metadata'], config


expected = copy.deepcopy(existing)
expected['auths'].update({'quay.io/rhoai': source['auths']['quay.io'],
                          'registry.stage.redhat.io': source['auths']['registry.stage.redhat.io']})
for topology in ['HighlyAvailable', 'SingleReplica']:
    assert render(topology, existing) == ({'name': 'pull-secret', 'namespace': 'openshift-config'}, expected)
    assert render(topology) is None, 'Do not create a missing conventional global Secret'
    assert render(topology, existing, None) is None, 'Missing source must not change credentials'
    assert render(topology, existing, empty_input=True) is None
    assert render(topology, expected)[1] == expected, 'Repeated rendering must be idempotent'
print('PASS: conventional target, existing credentials/fields, rotation and missing-input guards')

hcp_result = render('External')
assert hcp_result is not None, 'HCP must create its additional Secret without a guest global Secret dependency'
metadata, config = hcp_result
assert metadata == {'name': 'additional-pull-secret', 'namespace': 'kube-system'}
assert config == {'auths': {'quay.io/rhoai': source['auths']['quay.io'],
                           'registry.stage.redhat.io': source['auths']['registry.stage.redhat.io']}}
assert render('External', existing) == (metadata, expected)
assert render('External', existing, None) is None
assert render('External', existing, empty_input=True) is None
assert render('External', expected)[1] == expected
scoped = {'auths': {'quay.io/rhoai': {'auth': 'synthetic-scoped'},
                     'quay.io': {'auth': 'synthetic-broad-source'}}}
assert render('External', input_config=scoped)[1] == {'auths': {'quay.io/rhoai': scoped['auths']['quay.io/rhoai']}}
print('PASS: HCP creates/merges only additional credentials, preserving unrelated entries')
print('PASS: scoped Quay wins over broad source; no original/generated Secret writes or source aliases')
print('Fixture rendering only; live HCCO merge, worker delivery and image pulls remain unverified.')

for infra_fixture in ['missing', 'no-status', 'empty-status', 'no-topology']:
    result = render('HighlyAvailable', existing, infra_fixture=infra_fixture)
    assert result == ({'name': 'pull-secret', 'namespace': 'openshift-config'}, expected)
    assert render('HighlyAvailable', infra_fixture=infra_fixture) is None
    print('PASS: infrastructure lookup fixture', infra_fixture)
