# Grid bootstrap

This hub Application deploys the existing `grid-enrollment` chart from
`odh-gitops:main` in external mode. `managedClusters.enabled` selects
inventory-based enrollment through the common ACM/OCM APIs. The chart itself
has no Argo-specific switch.

The existing `redhat-ai-grid/grid-ca` Issuer continues to use `grid-ca-key`.
Bootstrap never regenerates the CA. Selected clusters have the `ai-grid/enabled`
label and use their ManagedCluster name as the site identity. The hub is enrolled
through the same flow as other members.

The chart requests a Certificate per selected member, delivers the identity and
public CA bundle, and installs a read-only GridSite observer per cluster. It
watches public endpoint metadata and distributes remote GridSites to peers,
with a site-only operator ConfigMap on each member. Model discovery uses the
Local operator's HTTPS provider catalog. The CA signing key remains on the hub.

Bootstrap now persists the grid ID in the immutable `grid-bootstrap-state`
ConfigMap. It adopts an existing GridNetwork ID, including a legacy status-only
ID, before generating one for a new grid. Enrollment waits for the GridNetwork
and GridSite CRDs to be Established and for the identity Secrets, then delivers
the complete network with Local membership, poll transport, SPIFFE trust, and
the per-cluster gateway reference.

The bootstrap image is the payload's Grid v0.3.0 build, read from the
rhods-operator Deployment's RELATED_IMAGE_ODH_PRAXIS_AI_GRID_ENROLLMENT_IMAGE on a
member. The operator itself comes from the payload. Keep this digest and the gateway
digest in apps/rhoai/values.yaml aligned with the payload.

Merge the chart update providing work-agent GridSite read permissions before
this rollout. The local-endpoints policy creates a passthrough signals Route and
publishes each member's source GridSite using admitted gateway and signals Route
addresses. It waits for CRDs and Local network enrollment before writing the
GridSite; router addresses are discovered on each member rather than stored in
Git. The enrollment chart's observers then distribute those endpoints to peers.
It places only on inference and combined members. An ingress member runs no models,
so the operator's own GridSite for it carries no endpoints, and peers admit its
calls without dialing or polling it.

The enrollment policy is the only source of each member's GridNetwork. The
operator's read access to its ConfigMap comes from the AI gateway operator's own
manifests. No enrollment service runs: the RHOAI release keeps grid-enrollment
disabled.

## Verify the rollout

Use an explicit hub context and inspect metadata, not Secret data:

```sh
kubectl --context "$HUB_CONTEXT" -n openshift-gitops get applications.argoproj.io grid-bootstrap
kubectl --context "$HUB_CONTEXT" -n redhat-ai-grid get issuers.cert-manager.io grid-ca
kubectl --context "$HUB_CONTEXT" -n redhat-ai-grid get certificates.cert-manager.io
kubectl --context "$HUB_CONTEXT" -n redhat-ai-grid get policies.policy.open-cluster-management.io
kubectl --context "$HUB_CONTEXT" get manifestworks.work.open-cluster-management.io -A
kubectl --context "$HUB_CONTEXT" -n redhat-ai-grid get configmap grid-bootstrap-state
kubectl --context "$HUB_CONTEXT" get gridnetworks.grid.praxis.fast,gridsites.grid.praxis.fast
kubectl --context "$HUB_CONTEXT" -n redhat-ai-grid get routes grid-provider-gateway grid-operator-signals
kubectl --context "$HUB_CONTEXT" -n redhat-ai-grid get secret grid-ca-key \
  -o jsonpath='{.metadata.uid}{"\n"}'
```

The CA UID must be unchanged, both site Certificates Ready, and identity policies
Compliant. Check each cluster's `grid-site-identity` has the corresponding
`cert-manager.io/certificate-name` annotation and that its GridNetwork accepts the
identity. Each member must have the same persisted grid ID, `membership.mode:
Local`, poll transport, and SPIFFE trust. Check each observer's
`status.resourceStatus`: successful root-policy compliance alone does not prove
the work agent can read GridSites. Both observers must return gateway and signals
endpoint feedback. Confirm Local mode in operator logs and provider catalog
discovery before removing the manual provider record.

Read-only observers must never overwrite source GridSites. After cutover, change
one source endpoint through Git and verify it appears on the other member without
copying status or changing the source. Restore the endpoint through Git. Removal
of a selection label withdraws peer records and stops certificate renewal; verify
withdrawal before removing identities or detaching a cluster. The CA is retained.

If rollout fails, fix configuration through Git while retaining
the CA and identities. Removing a Certificate stops renewal but does not revoke
an issued certificate or guarantee deletion of its Secret. Do not switch the CA
to Generate as a recovery action.

Do not roll back by deleting the GridNetwork or bootstrap ConfigMap. Disabling
`gridIdentity.enabled` stops policy delivery but deliberately retains the network;
a runtime rollback needs an explicit reviewed membership change. Record the
pre-rollout ID and CA UID, and preserve both throughout recovery.
