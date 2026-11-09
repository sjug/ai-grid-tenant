# MetalLB

A site without a load-balancer provider leaves every LoadBalancer Service
pending, and OpenShift's Gateway API controller fronts each Gateway with one
(the RHOAI chart creates two per site: the MaaS gateway and the serving
gateway). This app installs the MetalLB operator and address pools on every
managed cluster labelled `ai-grid/metallb-pool`; a cluster without the label
gets nothing, so a site with its own load balancer (a cloud provider, BGP
equipment, an existing MetalLB) is untouched.

The label carries the site's L2 range, an IPv4 `first-last` inside the site's
network and outside the addresses the installer and the nodes use. It lives on
the ManagedCluster next to the role labels, not in Git. Labelling activates the
app at once with its defaults (operator installed, one instance, one pool
named `ai-grid`), so a site that needs anything else commits its override file
first and labels after it is on the tracked branch:

```yaml
# apps/metallb/values-<cluster>.yaml, committed before the label
pools:                      # replaces the label's range
  - name: tenant            # pool names must not collide with pools the site already has,
    addresses: ["192.0.2.64/27", "192.0.2.100-192.0.2.110"]   # unless adopting them is intended
  - name: transit
    addresses: ["198.51.100.0/28"]
    l2: false               # no L2Advertisement; bring your own BGPAdvertisement
    autoAssign: false
operator:
  install: false            # the operator is already there
instance:
  create: false             # a MetalLB resource is already there
```

```sh
oc label managedcluster <name> ai-grid/metallb-pool=192.0.2.10-192.0.2.50
```

Render checks: the label must be an IPv4 `first-last` whose end is not before
its start, and every pool must list addresses; anything else fails the render
and nothing is applied. The addresses themselves (overlaps, reserved ranges,
CIDR shape in a pools file) are validated by MetalLB when the pool is applied.

Handing over or withdrawing: the Namespace, OperatorGroup, Subscription and
MetalLB instance are never pruned, so turning `operator.install` or
`instance.create` off leaves them in place for the site to own. While the
label is set, pools and advertisements removed from the input are pruned;
removing the label deletes the Application but keeps everything it created
(`preserveResourcesOnDeletion`), pools included. Removing MetalLB from a site
is a deliberate manual step after the label is gone. Only IPv4 ranges have
been exercised; IPv6 and dual-stack pools are not claimed.

Check: `apps/metallb/tests/render-test.sh`.
