# Shared Limitador Redis

This Application owns the Redis replication cluster and the local Limitador
storage configuration on the hub.

The Redis Service is exported through Submariner. `rhoai-prerequisites`
distributes the remote-only `kuadrant-system/limitador-redis` Secret and
Limitador storage patch, so every gateway site counts against the same Redis
backed rate-limit counters.

## Validation

On the Redis-owning cluster:

```sh
kubectl -n limitador-redis get serviceexport limitador-redis-master
kubectl -n limitador-redis get networkpolicy limitador-redis-isolation
```

On a remote cluster:

```sh
kubectl -n limitador-redis get serviceimport limitador-redis-master
kubectl -n kuadrant-system get limitador limitador \
  -o jsonpath='{.spec.storage.redis.configSecretRef.name}{"\n"}'
```

After both values are `limitador-redis`, exhaust a subscription's token quota
through one gateway and immediately call the other gateway. The second call
must return HTTP `429` without another exhaustion request.
