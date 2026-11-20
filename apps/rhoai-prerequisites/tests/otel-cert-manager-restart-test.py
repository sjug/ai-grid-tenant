#!/usr/bin/env python3
"""Render the OTel restart template with synthetic lookups; needs Helm and PyYAML (RHAI-49185)."""
from pathlib import Path
import copy
import json
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[3]
docs = [d for d in yaml.safe_load_all(
    (root / 'apps/rhoai-prerequisites/hub/12-otel-cert-manager-policy.yaml').read_text()) if d]
policy = next(d for d in docs if d['kind'] == 'Policy')
templates = {t['objectDefinition']['metadata']['name']: t['objectDefinition']
             for t in policy['spec']['policy-templates']}
restart = templates['rhoai-otel-cert-manager-restart']
grant = {o['objectDefinition']['kind']: o['objectDefinition']
         for o in templates['rhoai-otel-cert-manager-compat']['spec']['object-templates']}
assert restart['spec']['remediationAction'] == 'enforce'
assert restart['spec']['pruneObjectBehavior'] == 'None', 'Leave the env var on deselection'
raw = restart['spec']['object-templates-raw']
assert '{{hub' not in raw, 'Readiness must be read on the managed cluster'

values = yaml.safe_load((root / 'apps/rhoai/values.yaml').read_text())
otel_namespace = values['dependencies']['opentelemetry']['olm']['namespace']
assert 'config' not in values['dependencies']['opentelemetry']['olm'], \
    'An Argo-rendered Subscription env list would fight the policy'

# ACM returns an empty map for a missing object; Helm executes the real Go/Sprig branches.
stubs = {
    f'lookup "operators.coreos.com/v1alpha1" "Subscription" "{otel_namespace}" "opentelemetry-product"':
        'index $.Values "otel" | default dict',
    'lookup "apps/v1" "Deployment" "cert-manager" "cert-manager-webhook"':
        'index $.Values "webhook" | default dict',
    'lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" (printf "%s.cert-manager.io" $resource)':
        'index (index $.Values "crds" | default dict) $resource | default dict',
    f'lookup "rbac.authorization.k8s.io/v1" "ClusterRole" "" "{grant["ClusterRole"]["metadata"]["name"]}"':
        'index $.Values "role" | default dict',
    f'lookup "rbac.authorization.k8s.io/v1" "ClusterRoleBinding" "" "{grant["ClusterRoleBinding"]["metadata"]["name"]}"':
        'index $.Values "binding" | default dict',
}
for call, stub in stubs.items():
    assert raw.count(call) == 1, f'expected exactly one {call}'
    raw = raw.replace(call, stub)
assert 'lookup' not in raw, 'Unexpected extra lookup'


def render(objects):
    with tempfile.TemporaryDirectory(prefix='otel-restart-test-') as directory:
        chart = Path(directory)
        (chart / 'templates').mkdir()
        (chart / 'Chart.yaml').write_text('apiVersion: v2\nname: otel-restart-test\nversion: 0.1.0\n')
        (chart / 'templates/policy.yaml').write_text(
            '{{- define "restart" -}}\n' + raw
            + '\n{{- end }}\nobjects:\n{{ include "restart" . | indent 2 }}\n')
        (chart / 'values.json').write_text(json.dumps(objects))
        output = subprocess.check_output(
            ['helm', 'template', 'test', str(chart), '-f', str(chart / 'values.json')], text=True)
        return yaml.safe_load(output)['objects'] or []


def crd(established='True'):
    return {'status': {'conditions': [{'type': 'NamesAccepted', 'status': 'True'},
                                      {'type': 'Established', 'status': established}]}}


# The ready site uses the grant exactly as this Policy enforces it.
ready = {
    'otel': {'metadata': {'name': 'opentelemetry-product'}},
    'webhook': {'status': {'availableReplicas': 1}},
    'crds': {r: crd() for r in grant['ClusterRole']['rules'][0]['resources']},
    'role': copy.deepcopy(grant['ClusterRole']),
    'binding': copy.deepcopy(grant['ClusterRoleBinding']),
}
expected = [{'complianceType': 'musthave', 'objectDefinition': {
    'apiVersion': 'operators.coreos.com/v1alpha1', 'kind': 'Subscription',
    'metadata': {'name': 'opentelemetry-product', 'namespace': otel_namespace},
    'spec': {'config': {'env': [{'name': 'AI_GRID_CERT_MANAGER_READY', 'value': 'true'}]}}}}]
assert render(ready) == expected, 'Ready site: expected only the fixed env var on the Subscription'
print('PASS: usable prerequisites -> one musthave env entry on the OTel Subscription')


def case(name, mutate):
    objects = copy.deepcopy(ready)
    mutate(objects)
    assert render(objects) == [], f'{name}: must render nothing'
    print(f'PASS: {name} -> nothing rendered')


case('no OTel Subscription', lambda o: o.pop('otel'))
case('no cert-manager webhook', lambda o: o.pop('webhook'))
case('webhook without status', lambda o: o.update(webhook={}))
case('webhook with 0 available replicas', lambda o: o.update(webhook={'status': {'availableReplicas': 0}}))
for resource in ready['crds']:
    case(f'{resource} CRD missing', lambda o, r=resource: o['crds'].pop(r))
    case(f'{resource} CRD not Established', lambda o, r=resource: o['crds'].update({r: crd('False')}))
case('CRDs without conditions', lambda o: o.update(crds={r: {} for r in ready['crds']}))
case('no ClusterRole', lambda o: o.pop('role'))
case('ClusterRole without rules', lambda o: o['role'].update(rules=[]))
case('ClusterRole for another API group', lambda o: o['role']['rules'][0].update(apiGroups=['example.io']))
for field in ['resources', 'verbs']:
    for item in ready['role']['rules'][0][field]:
        case(f'ClusterRole missing {field[:-1]} {item}',
             lambda o, f=field, i=item: o['role']['rules'][0].update({f: [x for x in o['role']['rules'][0][f] if x != i]}))
case('no ClusterRoleBinding', lambda o: o.pop('binding'))
case('binding to another role', lambda o: o['binding']['roleRef'].update(name='other'))
case('binding to a Role', lambda o: o['binding']['roleRef'].update(kind='Role'))
case('binding without subjects', lambda o: o['binding'].pop('subjects'))
case('binding to another ServiceAccount', lambda o: o['binding']['subjects'][0].update(name='other'))
case('binding in another namespace', lambda o: o['binding']['subjects'][0].update(namespace='other'))
case('binding to a User', lambda o: o['binding']['subjects'][0].update(kind='User'))
# The reviewer's reproduction: unestablished CRD plus a binding to the wrong role with no subjects.
case('unestablished CRD, wrong role, no subjects', lambda o: (
    o['crds'].update(certificates=crd('False')), o['binding']['roleRef'].update(name='other'),
    o['binding'].pop('subjects')))

# A second subject or an extra rule must not hide a usable grant.
extra = copy.deepcopy(ready)
extra['binding']['subjects'].insert(0, {'kind': 'ServiceAccount', 'name': 'other', 'namespace': 'other'})
extra['role']['rules'].insert(0, {'apiGroups': [''], 'resources': ['configmaps'], 'verbs': ['get']})
assert render(extra) == expected
print('PASS: extra subjects and rules still recognise the usable grant')
print('Local rendering only; the OLM rollout and collector admission need live validation.')
