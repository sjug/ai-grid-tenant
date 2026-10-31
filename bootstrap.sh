#!/bin/bash
set -e
# Bootstrap a cluster to be managed by this repo
# Per https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.22/html/installing_gitops/installing-openshift-gitops#installing-gitops-operator-using-cli_installing-openshift-gitops
# BOOTSTRAP_PROFILE=dedicated-hub installs a hub that runs no Grid or RHOAI workloads.
profile="${BOOTSTRAP_PROFILE:-}"
case "$profile" in
  ""|dedicated-hub) ;;
  *) echo "ERROR: unknown BOOTSTRAP_PROFILE ${profile}." >&2; exit 1 ;;
esac
oc apply -f bootstrap/namespace.yaml
oc apply -f bootstrap/gitops-operator-group.yaml
oc apply -f bootstrap/openshift-gitops-sub.yaml

echo "Waiting for OpenShift GitOps CRDs..."
wait_for_crd() {
  local crd="$1"
  for _ in $(seq 1 120); do
    # A just-created CRD has no status.conditions yet, which oc wait reports as an error.
    if oc get "customresourcedefinitions.apiextensions.k8s.io/${crd}" >/dev/null 2>&1 &&
      oc wait --for=condition=Established "customresourcedefinitions.apiextensions.k8s.io/${crd}" --timeout=1m 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "ERROR: timed out waiting for CRD ${crd}." >&2
  return 1
}

wait_for_crd applications.argoproj.io
wait_for_crd applicationsets.argoproj.io

# The operator creates the openshift-gitops namespace and its default Argo CD
# instance shortly after the CRDs register. On a cold cluster the namespace can
# still be missing here, so wait for the instance before applying anything into it.
echo "Waiting for the openshift-gitops Argo CD instance..."
wait_for_argocd() {
  for _ in $(seq 1 120); do
    if [ "$(oc --request-timeout=30s -n openshift-gitops get argocd openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null)" = Available ]; then
      return 0
    fi
    sleep 5
  done
  echo "ERROR: timed out waiting for argocd/openshift-gitops to become Available." >&2
  return 1
}
wait_for_argocd

oc apply -f "bootstrap/${profile:+${profile}/}applicationset.yaml"
oc apply -f bootstrap/openshift-gitops-admin.yaml
oc patch consoles.operator.openshift.io cluster --patch '{ "spec": { "plugins": ["gitops-plugin"] } }' --type=merge

# Seed only the hub-side Quay credential. The rhoai-prerequisites ACM app
# distributes the registry mirror and pull secret to every managed cluster.
bash apps/rhoai-prerequisites/create-hub-secret.sh
