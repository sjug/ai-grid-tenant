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

# The default Argo CD instance appears shortly after the operator's CRDs register; wait for it
# (ARGOCD_READY_TIMEOUT_SECONDS, default 600; ARGOCD_POLL_SECONDS, default 5) before applying into it.
echo "Waiting for the openshift-gitops Argo CD instance..."
wait_for_argocd() {
  timeout="${ARGOCD_READY_TIMEOUT_SECONDS:-600}"
  poll="${ARGOCD_POLL_SECONDS:-5}"
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || break
    request_timeout=30; [ "$request_timeout" -gt "$remaining" ] && request_timeout=$remaining
    if phase=$(oc --request-timeout="${request_timeout}s" -n openshift-gitops get argocd openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null) \
      && [ "$phase" = Available ] && [ "$SECONDS" -lt "$deadline" ]; then
      return 0
    fi
    remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || break
    if [ "$poll" -lt "$remaining" ]; then sleep "$poll"; else sleep "$remaining"; fi
  done
  echo "ERROR: argocd/openshift-gitops not Available after ${timeout}s; set ARGOCD_READY_TIMEOUT_SECONDS to wait longer." >&2
  return 1
}
wait_for_argocd

# Under ACM load the application controller can be OOM-killed before it syncs gitops-config, which is
# what sets its memory. Apply the same controller resources here, read from that manifest so it stays
# the one source of the values, before the root ApplicationSet starts the fan-out.
patch_argocd_controller_resources() {
  local manifest=apps/gitops-config/manifests/argocd.yaml resources
  # The ai-grid.dev/read label only exists in --local's stdout; it is never applied to the live CR.
  resources=$(KUBECONFIG=/dev/null oc label --local -f "$manifest" ai-grid.dev/read=true \
    -o jsonpath='{.spec.controller.resources}')
  if [ -z "$resources" ]; then
    echo "ERROR: no spec.controller.resources in ${manifest}." >&2
    return 1
  fi
  echo "Setting the Argo CD application controller's resources from ${manifest}..."
  oc patch argocd openshift-gitops -n openshift-gitops --type merge \
    -p "{\"spec\":{\"controller\":{\"resources\":${resources}}}}"
}
patch_argocd_controller_resources

# The patch only changes the CR; the GitOps operator then rolls the controller's StatefulSet. Wait
# (ARGOCD_CONTROLLER_TIMEOUT_SECONDS, default 600) until its pod template carries the manifest's memory
# limit and the rollout is done, so the fan-out doesn't start on the old limit.
wait_for_argocd_controller_resources() {
  local manifest=apps/gitops-config/manifests/argocd.yaml sts=openshift-gitops-application-controller want got
  timeout="${ARGOCD_CONTROLLER_TIMEOUT_SECONDS:-600}"
  poll="${ARGOCD_POLL_SECONDS:-5}"
  deadline=$((SECONDS + timeout))
  want=$(KUBECONFIG=/dev/null oc label --local -f "$manifest" ai-grid.dev/read=true \
    -o jsonpath='{.spec.controller.resources.limits.memory}')
  if [ -z "$want" ]; then
    echo "ERROR: no spec.controller.resources.limits.memory in ${manifest}." >&2
    return 1
  fi
  echo "Waiting for statefulset/${sts} to run with memory limit ${want}..."
  while :; do
    got=$(oc -n openshift-gitops get statefulset "$sts" \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="argocd-application-controller")].resources.limits.memory}' 2>/dev/null) || got=
    [ "$got" = "$want" ] && break
    remaining=$((deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then
      echo "ERROR: statefulset/${sts} memory limit is '${got}', not ${want}, after ${timeout}s; set ARGOCD_CONTROLLER_TIMEOUT_SECONDS to wait longer." >&2
      return 1
    fi
    if [ "$poll" -lt "$remaining" ]; then sleep "$poll"; else sleep "$remaining"; fi
  done
  remaining=$((deadline - SECONDS)); [ "$remaining" -gt 0 ] || remaining=1
  if ! oc -n openshift-gitops rollout status "statefulset/${sts}" --timeout="${remaining}s"; then
    echo "ERROR: statefulset/${sts} did not finish rolling out within ${timeout}s; set ARGOCD_CONTROLLER_TIMEOUT_SECONDS to wait longer." >&2
    return 1
  fi
}
wait_for_argocd_controller_resources

oc apply -f "bootstrap/${profile:+${profile}/}applicationset.yaml"
oc apply -f bootstrap/openshift-gitops-admin.yaml
oc patch consoles.operator.openshift.io cluster --patch '{ "spec": { "plugins": ["gitops-plugin"] } }' --type=merge

# Seed only the hub-side Quay credential. The rhoai-prerequisites ACM app
# distributes the registry mirror and pull secret to every managed cluster.
bash apps/rhoai-prerequisites/create-hub-secret.sh
