# Getting started

An AI Grid on ACM takes three steps: a hub, then clusters, then models.

## Dependencies

What you bring:

- Hub: an OpenShift cluster with ACM, OpenShift GitOps (Argo CD) and cert-manager.
- A fork of this repository the hub's Argo CD can read.
- Pull credentials for quay.io/rhoai, and registry.stage.redhat.io for pre-release
  model images, given once to the bootstrap script as environment variables.
- Each site: a default StorageClass. RHOAI monitoring claims 20Gi and 10Gi. A MaaS
  database replica claims 20Gi on an ingress or combined site.
- Each site: two nodes Submariner can use as gateways, and its cloud prerequisites.
- Each site: a default router the other sites can reach, on 443.
- Each site: capacity for its models. The samples run on CPU, 10Gi each. A GPU
  model needs GPU nodes and the NVIDIA operator, which this repository does not
  install.

What the hub delivers to every site, by policy and Argo CD:

- Pull Secrets and the image mirror.
- The grid CA, the site's identity certificate, and its rotation.
- Grid CRDs, the grid operator and gateways, and RHOAI in the site's role.
- Submariner, and the MaaS database credentials.
- ACM Search's collector, so the provider console can read the site's GPUs and
  MaaSSubscriptions.

## Deployment options

Two labels on a ManagedCluster decide everything:

- ai-grid/enabled=true makes the cluster a grid member: identity, membership,
  the grid CRDs and operator. Removing it withdraws the site from the grid.
- ai-grid/role says what the site runs. Without a role nothing is installed.

The roles:

- ingress: RHOAI with MaaS and the portal, the consumer gateway, the tenant
  policy, a MaaS database replica. Users enter here. No models.
- inference: RHOAI without MaaS, the grid operator and provider gateway, the
  models. Requests arrive from ingress sites over mTLS.
- combined: both on one cluster.

The hub:

- A combined hub is a site too. Label it like any other cluster. The smallest
  grid is one combined hub.
- A dedicated hub only manages. Bootstrap it with BOOTSTRAP_PROFILE set to
  dedicated-hub and label the sites. It is never labelled itself.

The MaaS database primary always runs on the hub. A typical grid is one ingress
site plus inference sites, or one combined site plus inference sites.

Bare metal, or any site without a cloud provider: [bare metal](bare-metal/README.md)
lists what the site brings and declares.

## 1. Hub

Install Argo CD and ACM, point the fork at itself, run the bootstrap script.
Argo installs everything under apps, including the grid bootstrap that mints
the grid ID and delivers each member's identity.

Guide: [hub onboarding](hub-onboarding/README.md).

## 2. Cluster

Import the cluster into ACM, then label it:

```sh
oc label managedcluster <name> ai-grid/enabled=true ai-grid/role=combined
```

No cluster-specific file goes into Git. The grid operator derives all gateway
routing from the models each site publishes.

Guide: [cluster onboarding](cluster-onboarding/README.md).

## 3. Models

Label a project namespace and deploy a model into it:

```sh
oc label namespace <project> grid.opendatahub.io/allowed=true
```

The model controller publishes the model to the grid. No per-model entry in Git.

Guide: [AI project onboarding](ai-project-onboarding/README.md).

## Verification

- Hub: every Application Synced and Healthy, Policies Compliant.
- Site: every InferenceProvider Available.
- End to end: the [MaaS smoke test](../maas-oidc-smoke/README.md) gets a
  completion as a tenant user.

## Layout

| Concern | Path |
|---|---|
| Hub bootstrap and grid identity | apps/grid-bootstrap |
| Which clusters are sites, in what role | apps/ai-grid-spokes |
| RHOAI, grid operator and gateways | apps/rhoai |
| Namespaces, policies, pull secrets | apps/rhoai-prerequisites |
| Models and MaaS objects | apps/acm-models |
| MaaS database | apps/maas-db |
| Submariner | apps/acm/submariner |
| ACM Search collector on every managed cluster | apps/acm/manifests/search |
