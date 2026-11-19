# AI project onboarding

How an AI project namespace and its models join the grid on a cluster that already runs RHOAI. A cluster gets RHOAI by its `ai-grid/enabled=true` label: see [cluster onboarding](../cluster-onboarding/README.md).

## Add a project namespace

Create the namespace and opt it in with one label:

```bash
oc create namespace <project>
oc label namespace <project> grid.opendatahub.io/allowed=true
```

The label is the only switch. On every cluster in the grid it gives the namespace:

- route admission on the inference gateway (`openshift-ai-inference`), whose listeners select namespaces by this label;
- the NetworkPolicies from the `rhoai-prerequisites` policy, which isolate the model pods and admit only the scheduler, the router, the Grid namespace and RHOAI's metrics collector;
- InferenceProvider publication: the model controller publishes each LLMInferenceService in a labelled namespace whose Gateway carries the Grid serving annotation.

`ai-grid-internal-models` is created with the label, and is where the catalog deploys models.

## Deploy a model

Use the provider console, which writes the model to the catalog repository, or commit an `LLMInferenceService` to a labelled namespace. See [apps/acm-models](../../../apps/acm-models/README.md) for the catalog, its AppProjects and the sample models.

A minimal model, as the lab runs it:

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: facebook-opt-125m
  namespace: <project>
spec:
  baseRefs:
    - name: v3-6-0-kserve-config-llm-template-cpu
  model:
    uri: hf://facebook/opt-125m
    name: facebook-opt-125m
  replicas: 1
  router:
    scheduler:
      template:
        containers:
          - name: main
            args:
              - --metrics-cert-dir=/var/run/kserve/tls
    route: {}
    gateway:
      refs:
        - name: openshift-ai-inference
          namespace: openshift-ingress
  template:
    containers:
      - name: main
        args:
          - --chat-template=template_chatml.jinja
          - --override-generation-config.max_new_tokens=64
```

- baseRefs picks a platform preset. Use v3-6-0-kserve-config-llm-template for GPU nodes.
- model.name is the name clients send, and the name MaaS publishes.
- The model must serve `/v1/chat/completions`, which the MaaS portal's example and playground call, so it needs a chat template. opt-125m is a base model without one, so `--chat-template` gives it vLLM's bundled ChatML template; a model that ships a template needs no argument. Base models without a template are not supported.
- A base model like opt-125m rarely ends a reply, so `--override-generation-config.max_new_tokens=64` caps replies at 64 tokens, the default and the upper bound for `max_tokens`. Without it, a chat request that sets no `max_tokens`, like the MaaS portal's example, runs to the context limit, minutes on CPU. A chat model that ends its replies needs no cap.
- router.gateway attaches the model to the inference gateway, which the grid dials.
- The scheduler argument serves its metrics over TLS, until the platform preset does.

The working sample is [apps/acm-models/facebook-opt-125m](../../../apps/acm-models/facebook-opt-125m/10-facebook-opt-125m-cpu.yaml).

Nothing else per model. The grid operator derives the gateway's dial from the published InferenceProvider. The dial goes to the serving gateway at the model's publisher path, as the grid model client, so the inference scheduler picks the pod. The serving gateway authorizes that path with a review for post on the model. The rhoai-prerequisites policy grants that verb to the grid model client in every labelled namespace, since the model controller's own Role covers another path (odh-model-controller#996).

Other sites reach the model through the site's provider gateway, which the peers policy publishes to them.

## Verify

- `oc -n <project> get networkpolicy` includes `grid-gateway-backend`, `llminference-engine-serving`, `llminference-scheduler-serving` and `rhoai-collector-metrics`, and the `rhoai-prerequisites` policy is Compliant.
- The model's HTTPRoute reports Accepted on `openshift-ai-inference`.
- `oc get inferenceproviders` shows the model's provider `Available`, with `MetricsAvailable=True`.
- The dial file in the grid-serving-grid-grid-gateway ConfigMap lists the model's provider with the serving gateway address, a base path and a credential.
- A completion through the grid gateway returns 200, with the x-grid-backend header set to that provider.
