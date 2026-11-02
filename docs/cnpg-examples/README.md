# Inert CloudNativePG examples

These files are a sketch of the later migration PRs. They are not a live install.

- Nothing under `docs/` is on the Flux path. `cluster-apps` builds `./kubernetes/apps` ([kubernetes/flux/cluster/ks.yaml](../../kubernetes/flux/cluster/ks.yaml)).
- No `kustomization.yaml` in this directory, and no Flux `Kustomization` points here.
- Do not copy them into `kubernetes/` until the matching phase in [the runbook](../cnpg-migration.md) says so.
- Do not `kubectl apply` them against the cluster. Applying a Cluster example creates a new empty database beside the current StatefulSet. That is a later, deliberate step, one app at a time starting with silo, and it still must not adopt the existing PVC. The Barman `ObjectStore` writes only to the planned Garage bucket `postgresql`, which is not created here.

`logical-copy.sh` only dumps and restores. It has no delete, scale, or PVC path.
