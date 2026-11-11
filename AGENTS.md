# Repository Guidelines

## Project Structure & Module Organization

This repository contains GitOps configuration for an OpenShift multi-cluster AI Grid:

- `apps/` — Argo CD Applications, ApplicationSets, and numbered component manifests.
- `bootstrap/` — OpenShift GitOps bootstrap resources used by `bootstrap.sh`.
- `cluster-config/` — the cluster-level Helm chart and tracked values.
- `docs/` — runbooks, onboarding, and smoke-test scripts.
- `renovate.json` and `renovate-config.js` — dependency-update configuration.

## GitOps Principles

Persistent cluster state must be GitOps-driven and auditable. Change Git first, open a review, and allow Argo CD or ACM
to reconcile generated Applications, ApplicationSets, and Policies. Do not repair live state with ad hoc `kubectl edit`
or untracked `kubectl apply` changes. Configuration must be repeatable across any set of clusters: use generic ACM/OCM
placement and discovery flows and no hard-coded cluster names, contexts, endpoints, node names, or environment-specific
values. Use documented, parameterized scripts for unavoidable runtime inputs.

When a change begins managing a new custom resource kind, inspect its CRD status schema and, where available, read-only
examples on the authorized hub or a discovered spoke. Policy-embedded `objectDefinition` resources and resources rendered
by remote charts count as managed. Add a Lua health check to `apps/gitops-config/manifests/argocd.yaml` for every
status-bearing kind that lacks an Argo built-in, or add a narrowly scoped, documented exception in
`scripts/check-gitops-health-checks.sh`; remote-chart kinds absent from repository YAML must be added to that script's
external managed-resource list. Do not use a presence-only check for a resource that exposes readiness, degradation,
compliance, or generation state.

## Build, Validation, and Development Commands

```sh
helm lint cluster-config/chart -f cluster-config/values.yaml -f cluster-config/cluster-admins.yaml
helm template cluster-config/chart -f cluster-config/values.yaml -f cluster-config/cluster-admins.yaml
bash -n bootstrap.sh docs/acm/cluster-onboarding/import-managed-cluster.sh scripts/set-tenant-repo.sh
scripts/check-gitops-health-checks.sh
scripts/set-tenant-repo.sh --check
```

Use `helm template` to inspect rendered resources. These checks do not touch a cluster. Do not run `./bootstrap.sh`,
cluster import, credential-seeding, or other cluster-mutating scripts while contributing. Leave the live MaaS OIDC smoke
test to an authorized operator.

## Coding Style & Naming Conventions

- Use two-space indentation in YAML and four spaces in Python.
- Keep existing ordered manifest names (`00-`, `01-`, `10-`) and descriptive lowercase kebab-case file names.
- Preserve explicit resource names and namespaces; avoid environment-specific values.
- Use `#!/usr/bin/env bash` and `set -Eeuo pipefail` for new shell scripts.
- No formatter or lint pipeline is configured; keep diffs minimal and consistent with neighboring files.

## Testing Guidelines

There is no automated unit-test suite. Validate YAML rendering and shell syntax locally before opening a PR. Run
`scripts/check-gitops-health-checks.sh` whenever managed resource kinds or Argo CD health checks change. Do not make
live changes to validate cluster-affecting work; use read-only CRD and Application inspection on the authorized hub and
describe intended operator validation in the PR.

## Commit & Pull Request Guidelines

Use Conventional Commit-style subjects such as `fix(rhoai): ...`, `test: ...`, and `chore(deps): ...`; keep subjects
imperative and scoped.

Commits and pull requests should include the motivation, affected Applications or clusters, validation evidence, linked
issue when applicable, and rollback or sync risk. Include screenshots for Grafana dashboard changes.

## Security & Configuration Tips

Never commit credentials, tokens, kubeconfigs, private endpoints, or runtime data. Supply secrets through documented
environment variables or Kubernetes Secrets; use metadata-only `kubectl` commands when verifying Secrets.
