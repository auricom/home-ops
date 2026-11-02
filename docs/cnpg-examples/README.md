# Cutover helper

Live CloudNativePG manifests are under `kubernetes/apps/database/cloudnative-pg/`, `kubernetes/apps/database/plugin-barman-cloud/`, and `kubernetes/apps/default/{silo,bookorbit,immich}/cnpg/`. Flux builds them from [kubernetes/apps/kustomization.yaml](../../kubernetes/apps/kustomization.yaml).

This directory only has `logical-copy.sh`, used by [the runbook](../cnpg-migration.md) when an app is actually migrated. It does not delete PVCs or change HelmReleases.
