# RHOAI Application Guidelines

## Profile and Value Ownership

- Move reusable RHOAI rendering behavior and role defaults into the `rhai-on-openshift-chart`
  profiles in `odh-gitops`. Keep this repository's RHOAI values limited to tenant-specific
  choices, payload image references, per-site overrides, and contracts with other Applications.
- The intended roles are:
  - `ingress`: MaaS plus the Grid consumer gateway; KServe is removed.
  - `inference`: KServe plus the Grid provider gateway; MaaS is removed.
  - `combined`: both ingress and inference behavior.
- Do not duplicate resources or value ownership between an ApplicationSet source and the chart.
  Before adding a source or manifest here, verify whether a chart profile already renders the
  equivalent resource and choose exactly one owner.
- Do not put environment-specific endpoints, cluster names, credentials, or runtime data in the
  chart profiles or shared RHOAI values.

## Chart Changes and Rollout

- A behavior change in an `odh-gitops` profile requires chart snapshot validation and publication
  of a new immutable OCI chart revision. Update this ApplicationSet's `targetRevision` to that
  exact revision; do not point production-like Applications at mutable branch tags.
- After changing profiles or ApplicationSet sources, render every role and compare the final
  resources—not just the input values—with the previous contract.
- Preserve cross-Application contracts explicitly, including MaaS provider routing, Grid mTLS and
  identity handling, Authorino trust bundles, gateway images, NetworkPolicy peers, and dashboard
  management states.
- Keep readiness and policy checks role-aware. An ingress site is healthy with KServe removed;
  inference and combined sites require KServe.

## Validation

Run the focused checks before opening a change:

```sh
RHAI_CHART_DIR=<odh-gitops>/charts/rhai-on-openshift-chart \
  apps/rhoai/tests/provider-gateway-network-test.sh
RHAI_CHART_DIR=<odh-gitops>/charts/rhai-on-openshift-chart \
  apps/rhoai/tests/dashboard-state-test.sh
RHAI_CHART_DIR=<odh-gitops>/charts/rhai-on-openshift-chart \
  apps/rhoai/tests/operator-namespaces-test.sh
```

When validating the exact rollout, omit `RHAI_CHART_DIR` so the tests pull the immutable chart
revision named by the ApplicationSet. Also run `git diff --check`.
