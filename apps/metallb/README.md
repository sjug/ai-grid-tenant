# MetalLB

Bare metal sites have no cloud load balancer. OpenShift's Gateway API
controller fronts every Gateway with a LoadBalancer Service, and the RHOAI
chart creates two per site (the MaaS gateway and the serving gateway). Without
a load balancer controller those Services stay pending indefinitely; OpenShift
documents MetalLB as the tested controller for on-premise Gateway API.

This app installs the MetalLB operator and one L2 address pool on every managed
cluster that carries the label `ai-grid/metallb-pool`. The pool is the only
site-specific value and lives on the ManagedCluster, next to the role labels,
not in Git:

```sh
oc label managedcluster <name> ai-grid/metallb-pool=198.18.1.10-198.18.1.50
```

The value is an address range inside the site's machine network, outside the
addresses the installer uses. ACM copies the label onto Argo CD's cluster
Secret, where the ApplicationSet reads it. A cluster without the label gets
nothing.
