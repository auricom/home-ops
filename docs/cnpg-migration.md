# CloudNativePG migration

Move each PostgreSQL database off its app-template StatefulSet and onto its own [CloudNativePG](https://cloudnative-pg.io/) `Cluster`, without deleting the data that is already on disk.

This document is the procedure. It does not install the operator, and it does not point any app at a new database. The YAML under [docs/cnpg-examples/](cnpg-examples/README.md) is a sketch for later pull requests. Flux does not build `docs/`.

## Design

One CloudNativePG `Cluster` and, where the app needs extensions, one `Database` per application that uses PostgreSQL. The operator is cluster-wide. The data stays in the application namespace (`default`), next to the app, the same way Dragonfly custom resources already sit next to Immich, Authelia, and LiteLLM while the Dragonfly operator lives under `kubernetes/apps/database/`.

Logical copy (`pg_dump` / `pg_restore`, or CloudNativePG's `bootstrap.initdb.import` of type `microservice`) is the migration. Once a cluster is up, its backup is Barman Cloud to Garage bucket `postgresql` (continuous WAL and a daily `ScheduledBackup`). Reusing the current PersistentVolumeClaim is not safe for these images; the reasons are in [Why the current PVC stays where it is](#why-the-current-pvc-stays-where-it-is).

**Keep PVC `immich-database`, `silo-database`, and `bookorbit-database` until a later pull request whose only job is deleting them, and only after the go-ahead in [phase 8](#phase-8-delete-the-old-pvc).** Do not delete them in the operator PR, the per-app cutover PR, or the HelmRelease removal PR. Do not point a `Cluster` at them with `bootstrap.recovery`, `existingClaim`, or a volume `dataSource`.

### What this pull request ships

- This runbook and the inventory below.
- Inert examples in [docs/cnpg-examples/](cnpg-examples/README.md): operator HelmRelease, Barman Cloud plugin kustomization, silo `ObjectStore` / `ScheduledBackup` / `ExternalSecret`, Immich `Cluster`, Immich `Database`, silo `Cluster`, and `logical-copy.sh`.
- No change under `kubernetes/`. No Flux `Kustomization` references `docs/`.

### Later pull requests

1. **Operator only.** Copy [operator-helmrelease.yaml](cnpg-examples/operator-helmrelease.yaml) into `kubernetes/apps/database/cloudnative-pg/` and [plugin-barman-cloud.yaml](cnpg-examples/plugin-barman-cloud.yaml) into `kubernetes/apps/database/plugin-barman-cloud/`. Add both Flux `Kustomization`s to [kubernetes/apps/database/kustomization.yaml](../kubernetes/apps/database/kustomization.yaml) the same way `dragonfly` and `mosquitto` are added. No `Cluster`, no `ObjectStore`, no `ScheduledBackup`. Confirm `kubectl explain database.postgresql.cnpg.io` and `kubectl explain objectstore.barmancloud.cnpg.io` work afterwards.
2. **One empty cluster at a time.** Order is silo, then bookorbit, then Immich. The happy path never creates `silo-db`, `bookorbit-db`, and `immich-db` in one pull request. Each PR adds that app's empty `Cluster`, its `ObjectStore`, and its `ScheduledBackup`, and leaves the HelmRelease and the app DSN alone. Migrate that app only after its empty cluster is Ready. Immich's `Database` CR arrives with the Immich cluster, not before.
3. **Cutover, per app.** Follow the phases below for the one cluster that exists. The app's DSN changes only after the restore check passes. The StatefulSet stays. Do not start the next app's cluster until this one's cutover has soaked or you have explicitly parked it.
4. **Remove the StatefulSet.** A separate PR deletes that app's database HelmRelease only. The Flux `Kustomization` stays, because its Kopiur component holds the PVC. Immich's database path also holds the shared `OCIRepository` named `immich`, `immich-configmap`, and `immich-dragonfly`; those stay too.
5. **Delete the old PVC.** A further PR, after an explicit go-ahead and a verified backup of the new cluster. One app per PR. Immich's non-database objects are moved off that Flux `Kustomization` first.

## What is in this repo today

Searched `kubernetes/` for `postgres`, `POSTGRES`, `DB_HOSTNAME`, `5432`, and `postgresql.cnpg.io`.

There is no `postgresql.cnpg.io` object and no `cloudnative-pg` chart on the current tree. A shared CloudNativePG 16 cluster used to live here (commit `bc41f2d15`, archived in `0c9529c7a`). It was one database server for many apps, with Barman writing to a MinIO bucket `postgresql`. That layout is not the target. Do not revive it. The per-app StatefulSets below are the source of truth.

### Postgres workloads

| | Immich | silo | bookorbit |
| --- | --- | --- | --- |
| HelmRelease | [`immich-database`](../kubernetes/apps/default/immich/database/helmrelease.yaml) | [`silo-database`](../kubernetes/apps/default/silo/database/helmrelease.yaml) | [`bookorbit-database`](../kubernetes/apps/default/bookorbit/database/helmrelease.yaml) |
| Namespace | `default` | `default` | `default` |
| Chart | app-template, OCIRepository tag `5.3.0` | same | same |
| Controller | StatefulSet, single controller `primary` | same | same |
| Image | `ghcr.io/immich-app/postgres:18-vectorchord0.5.3` `sha256:828081a755d3911a2d94f0a2be9f98570c07d52cf080fd310a9d6e4b83b73aa5` | `pgvector/pgvector:pg18` `sha256:c29f30688a9ad961691bdf0ec1650717cc132a5814619d80f80463d6e4c42e47` | same image and digest as silo |
| Data directory | `PGDATA=/var/lib/postgresql/data`, volume mounted with **subPath `data`** | `PGDATA=/var/lib/postgresql/data/pgdata`, volume mounted at `/var/lib/postgresql/data` with no subPath | same as silo |
| UID on the files | `runAsUser` / `fsGroup` 999, init container `chown 999:999` | same | init container `chown 999:999`; pod securityContext is unset and the image default is 999 |
| PVC | `immich-database` | `silo-database` (the HelmRelease name) | `bookorbit-database` |
| PVC request | 10Gi (`KOPIUR_CAPACITY` on the Flux Kustomization) | 5Gi (Kopiur component default) | 5Gi (Kopiur component default) |
| StorageClass | `ceph-block` (Kopiur default) | same | same |
| Service | `immich-database.default.svc.cluster.local:5432` | `silo-database.default.svc.cluster.local:5432` | `bookorbit-database.default.svc.cluster.local:5432` |
| 1Password item | `immich` via ClusterSecretStore `onepassword-connect` | `silo` | `bookorbit` |
| Rendered secret | `immich-database` | `silo-database` | `bookorbit-database` |
| Role / database | database name literal `immich`. Role is `IMMICH__POSTGRES_USER` (the commented pgautoupgrade block in the HelmRelease says `immich`; read the live secret before relying on that) | literals `silo` / `silo`. Password key `SILO_POSTGRES_PASS` | `BOOKORBIT_POSTGRES_USERNAME`, `BOOKORBIT_POSTGRES_PASSWORD`, `BOOKORBIT_POSTGRES_DB_NAME` |
| Pod resources | request 500m / 512Mi, limit 750m / 768Mi | same | same |
| Kopiur | component on the `immich-database` Flux Kustomization, `KOPIUR_PUID/PGID=999` | component on `silo-database`, same uid | component on `bookorbit-database`, same uid |

The PVC, `SnapshotPolicy`, `SnapshotSchedule`, and `Restore` come from [kubernetes/components/kopiur/backup](../kubernetes/components/kopiur/backup/kustomization.yaml), substituted with `APP` equal to the Flux Kustomization name. Snapshots go to `ClusterRepository/storage` ([kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml](../kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml)): Garage S3 bucket `kopiur-k8s` at `192.168.30.10:30188`. The VolumeSnapshotClass default is `csi-ceph-blockpool`.

### Who connects

| App | How it reaches Postgres | HelmRelease dependency |
| --- | --- | --- |
| Immich server | `secretRef` `immich-database` (`DB_HOSTNAME`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE_NAME`, and `JWT_SECRET`) | `dependsOn: immich-database` in [immich/app/helmrelease.yaml](../kubernetes/apps/default/immich/app/helmrelease.yaml) |
| Immich microservices | same secret | `dependsOn: immich` |
| Immich machine-learning | same secret (reloader watches it) | `dependsOn: immich` |
| Immich sync | does not use the database secret | none on the database |
| silo | `DATABASE_URL` is rendered on the **app** ExternalSecret in [silo/app/helmrelease.yaml](../kubernetes/apps/default/silo/app/helmrelease.yaml), host `silo-database.default.svc.cluster.local.` | `dependsOn: silo-database` |
| bookorbit | `secretRef` `bookorbit-database`, which is created by the **database** HelmRelease and contains `DATABASE_URL` | no `dependsOn`; the secret name is the coupling |

Immich also runs Dragonfly (`immich-dragonfly`). That is a cache. It stays as it is.

Hostnames in the templates use a trailing dot (`svc.cluster.local.`). Keep that form when the host string changes.

### Apps that looked like Postgres and are not

| App | What it actually uses |
| --- | --- |
| Authelia | sqlite file `/data/db.sqlite3` in [configuration.yaml](../kubernetes/apps/default/authelia/app/config/configuration.yaml). Session store is Dragonfly. Two `AUTHELIA_STORAGE_POSTGRES_*` lines in the HelmRelease are comments. |
| Tandoor | `DB_ENGINE=django.db.backends.sqlite3`. `POSTGRES_DB` is the sqlite path `/opt/recipes/data/tandoor.sqlite`. |
| Paperless | `PAPERLESS_DBNAME=paperless` and no `PAPERLESS_DBHOST`. Paperless uses sqlite unless `PAPERLESS_DBHOST` is set. Its `database/` directory is Dragonfly only. |
| Bookstack | MariaDB sidecar (`lscr.io/linuxserver/mariadb`), not Postgres. |
| atuin, donetick, joplin, vikunja, gatus, komf | sqlite (or an sqlite-specific image), from their HelmRelease env. |

No other `DB_HOSTNAME`, `POSTGRES_*` consumer, or `postgres://` URL showed up under `kubernetes/apps`.

## Where the new objects go

Operators in this repo that ship a real Helm chart (cert-manager, grafana-operator) use an `OCIRepository` plus a `HelmRelease` under `kubernetes/apps/<namespace>/<name>/app/`, and a Flux `Kustomization` at `kubernetes/apps/<namespace>/<name>/ks.yaml`. The namespace folder lists that `ks.yaml`. Dragonfly is the exception: it wraps the operator binary in app-template because that project publishes a manifest, not a chart this repo consumes.

CloudNativePG publishes `oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg`. Follow the cert-manager shape, in the namespace that already holds database operators:

```text
kubernetes/apps/database/cloudnative-pg/app/ocirepository.yaml
kubernetes/apps/database/cloudnative-pg/app/helmrelease.yaml
kubernetes/apps/database/cloudnative-pg/app/kustomization.yaml
kubernetes/apps/database/cloudnative-pg/ks.yaml
```

Add `./cloudnative-pg/ks.yaml` to [kubernetes/apps/database/kustomization.yaml](../kubernetes/apps/database/kustomization.yaml). `targetNamespace: database`. `config.clusterWide` stays at the chart default `true`, so a `Cluster` in `default` is watched. Setting `WATCH_NAMESPACE` to `database` would ignore the apps.

Chart tag `0.29.1` was the newest stable tag on that OCI repository on 2026-11-01. Pin the digest in the operator PR after checking again. The archived install used chart `0.23.0` and a `HelmRepository`; do not copy that.

Before that PR, confirm `cluster-apps` is actually building `kubernetes/apps`. [kubernetes/flux/cluster/ks.yaml](../kubernetes/flux/cluster/ks.yaml) sets `path: ./kubernetes/apps`, and `kubernetes/apps/kustomization.yaml` has been absent since `0c9529c7a`. Namespace folders such as `database/` are not referenced from anywhere else in git. If that Flux `Kustomization` is failing its build, adding a file under `database/` does nothing until the parent include is restored. Restoring it is outside this migration and is not part of the operator PR unless you have checked what a successful build would prune.

Per-app objects, added in the app's own later PR, stay beside the current database HelmRelease so both exist during the dual-run window:

```text
kubernetes/apps/database/cloudnative-pg/          # operator PR, no Cluster
kubernetes/apps/database/plugin-barman-cloud/     # operator PR, no Cluster
kubernetes/apps/default/silo/database/cnpg-cluster.yaml
kubernetes/apps/default/silo/database/cnpg-barman.yaml
kubernetes/apps/default/bookorbit/database/cnpg-cluster.yaml
kubernetes/apps/default/bookorbit/database/cnpg-barman.yaml
kubernetes/apps/default/immich/database/cnpg-cluster.yaml
kubernetes/apps/default/immich/database/cnpg-database.yaml
kubernetes/apps/default/immich/database/cnpg-barman.yaml
```

The operator directory is wired in the operator PR. Each app's files are listed from that app's existing `database/kustomization.yaml` only in that app's later PR. Silo's PR is the first of those, and it is the only one that also creates ExternalSecret `postgresql-s3`. Cluster names are `immich-db`, `silo-db`, and `bookorbit-db`, so the primary service is `<name>-rw` and does not collide with the StatefulSet service `<name>-database`.

Reference shapes, adapted rather than copied:

- Database CR: [deedee immich/database.yaml](https://github.com/deedee-ops/home-ops/blob/master/kubernetes/apps/immich-system/immich/database.yaml), compared with the live [immich-database HelmRelease](../kubernetes/apps/default/immich/database/helmrelease.yaml).
- Cluster fields worth keeping: one instance for the migration (the StatefulSets are a single replica), `storageClass: ceph-block`, resources equal to the current requests and limits, `shared_preload_libraries: [vchord.so]` on Immich only, and the `barman-cloud.cloudnative-pg.io` plugin block from [deedee cluster.yaml](https://github.com/deedee-ops/home-ops/blob/master/kubernetes/components/postgresql/cluster.yaml). A plugin entry without the plugin installed leaves the `Cluster` unable to reconcile, which is why the plugin lands in the operator PR.
- Fields to leave out: deedee's Cilium egress labels, `priorityClassName: cnpg-instance`, three instances, a separate WAL volume, and the in-tree `spec.backup.barmanObjectStore` block this repo used on the archived Postgres 16 cluster. That field is the old API. Backups go through the plugin and an `ObjectStore`. The per-namespace wiring in [deedee `_postgresql.yaml`](https://github.com/deedee-ops/home-ops/blob/master/kubernetes/clusters/deedee/apps/immich-system/_postgresql.yaml) does not match this repo; apps here are not split into `immich-system`.

`enableSuperuserAccess: true` for the migration window so a human can inspect the new server. A follow-up can turn it off once the app role is enough, which is what deedee runs day to day.

## Backups

The ongoing backup for each CloudNativePG cluster is Barman Cloud: continuous WAL archiving plus a daily `ScheduledBackup`, both through the `barman-cloud.cloudnative-pg.io` plugin. Retention is 7 days, the same `retentionPolicy` as [deedee's ObjectStore](https://github.com/deedee-ops/home-ops/blob/master/kubernetes/components/postgresql/objectstore.yaml). Kopiur snapshots of the current PVC stay in place as a second copy of the **old** bytes until phase 8. They are not the Postgres backup once a cluster is taking WAL.

### Bucket

Create a dedicated Garage bucket named `postgresql` before the first cluster PR. That name is the one this repo already used for Postgres backups on the archived cluster, and it is not the Kopiur repository.

- Endpoint and region are the Garage already declared on [ClusterRepository/storage](../kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml): `http://192.168.30.10:30188`, region `garage`, TLS off.
- Do not put Barman objects in bucket `kopiur-k8s`. That bucket is a Kopia repository.
- Do not point the endpoint at the archived MinIO URL `https://s3.${SECRET_INTERNAL_DOMAIN}`. That host is not in the current tree.
- Rook `cephObjectStores` is empty. This bucket is Garage, not Ceph RGW.
- Creating the bucket and its access key happens outside this pull request. This repository does not gain a bucket manifest.

Layout, one prefix per application (not per Kopiur `${APP}`, which is the Flux name `immich-database`):

```text
s3://postgresql/silo/silo-db/
s3://postgresql/bookorbit/bookorbit-db/
s3://postgresql/immich/immich-db/
```

`destinationPath` is `s3://postgresql/<app>`. `serverName` is the cluster name (`silo-db`, `bookorbit-db`, `immich-db`), which is the next path segment Barman adds.

### Credentials

S3 keys for this bucket are a new 1Password item named `postgresql` in the same `onepassword-connect` `ClusterSecretStore` the rest of the cluster uses. Do not reuse the `kopiur` item. The ExternalSecret matches [components/kopiur/secret/externalsecret.yaml](../kubernetes/components/kopiur/secret/externalsecret.yaml): `dataFrom.extract.key`, template only, no literal keys in git. It renders `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY` (the key names the `ObjectStore` secret refs use) plus region `garage`. One secret, `postgresql-s3`, in namespace `default`, created with the silo PR and referenced by the later ObjectStores. The sketch is [silo-barman.yaml](cnpg-examples/silo-barman.yaml).

### Objects, per cluster

With that app's empty cluster, not in the operator PR:

- `ObjectStore` `barmancloud.cnpg.io/v1`, name `<cluster>-store`, `retentionPolicy: 7d`, WAL compression `gzip`. Same shape as deedee, without the endpoint CA (this Garage endpoint is plain HTTP).
- `ScheduledBackup` with `method: plugin` and `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`. Daily, `0 0 * * * *`. Not `spec.backup.barmanObjectStore` on the Cluster.
- The Cluster `spec.plugins` entry sets `isWALArchiver: true`, `barmanObjectName`, and `serverName`. `externalClusters` named `<cluster>-restore` points at the same store so a later rebuild can bootstrap from it.

The plugin Deployment comes from `plugin-barman-cloud` v0.15.1 (the release deedee's tree references). The upstream manifest hardcodes namespace `cnpg-system`. The Flux `Kustomization` sets `targetNamespace: database` and the kustomization sets `namespace: database`, so it lands next to the operator instead of in a new namespace. No Cilium egress labels.

### Kopiur

Each database PVC already has a Kopiur `SnapshotPolicy` and an hourly `SnapshotSchedule` via [components/kopiur/backup](../kubernetes/components/kopiur/backup/kustomization.yaml). Leave that pointed at the old PVC name for the whole migration. It is a crash copy of the StatefulSet disk, which Barman cannot see, because the StatefulSet is not a CloudNativePG instance.

Do not retarget that policy at the CloudNativePG volume, and do not add the Kopiur component to the new cluster's kustomization. The component creates the PVC itself (`pvc.yaml` has a `dataSourceRef` to a Kopiur `Restore`). CloudNativePG creates `<cluster>-1`. Those two claims would fight.

### Recover a cluster from Barman

This is how a **CloudNativePG** cluster is rebuilt after cutover. It is not how the StatefulSet is migrated. The StatefulSet has no WAL archive. Migration remains the logical dump in phases 3 and 4.

After a `Backup` for that cluster has completed and WAL archiving is healthy:

1. Leave PVC `<app>-database` alone if it still exists.
2. Scale the app's writers to 0 if they point at this cluster.
3. Delete the failed `Cluster` by its CNPG name (`silo-db`, `bookorbit-db`, or `immich-db`). That removes only the PVCs that cluster created.
4. Recreate it with `bootstrap.recovery.source: <cluster>-restore` and delete the `bootstrap.initdb` block. The `externalClusters` entry from the sketch is the source. `serverName` and `barmanObjectName` stay the same, or Barman will look in an empty prefix.
5. Wait until the new `Cluster` is Ready, then run the inventory diff against the last known-good counts (or against the app's own health checks if this is a point-in-time restore and the counts are supposed to have moved).
6. Point the app back at `<cluster>-rw` only after that check. Do not bootstrap with `recovery` during the original migration; that flag consumes the archive and must not be combined with `pg_restore` into the same data directory.

## Images and extensions

### Immich

The running server image is `ghcr.io/immich-app/immich-server:v3.3.5` with database image `ghcr.io/immich-app/postgres:18-vectorchord0.5.3`. That database image is the Docker Postgres image plus VectorChord. It has no CloudNativePG instance manager, so it cannot be `spec.imageName`.

The CNPG image that matches the extension line is `ghcr.io/tensorchord/cloudnative-vectorchord:18.0-0.5.3` (digest in [immich-cluster.yaml](cnpg-examples/immich-cluster.yaml)). Checked against the GHCR tag list on 2026-11-01: there is a `18.0-0.5.3` tag and no `18-0.5.3` tag. Newer `18.x` tags on that repository are VectorChord 1.0 or 1.1. Deedee's pin `18.6-1.1.1` is a different extension version. Loading a 0.5.3 dump's indexes into 1.1.1 is a version upgrade, and it is out of scope here. Do that later, against a cluster that is already on CloudNativePG, with its own backup.

`postgresql.shared_preload_libraries` must include `vchord.so` before the postmaster starts. `CREATE EXTENSION vchord` fails with `vchord must be loaded via shared_preload_libraries` otherwise. The [Database CR](cnpg-examples/immich-database.yaml) then ensures `cube`, `earthdistance`, `pg_trgm`, `unaccent`, `uuid-ossp`, `vector`, and `vchord`, which is the set in deedee's Immich `Database`. `earthdistance` needs `cube`. `vchord` needs `vector`.

Gate before any dump is restored: on a throwaway `Cluster` using that image, `\dx` can create every extension in the list, and `\dx` on the **live** Immich database lists the same names. If the live database has an extra extension, add it to the `Database` and confirm the image ships the matching `.so`. If it is missing one, drop it from the sketch.

### silo and bookorbit

Both run `pgvector/pgvector:pg18`, which also is not a CloudNativePG image. The sketch uses stock `ghcr.io/cloudnative-pg/postgresql:18.6` only as the placeholder for "no extra extensions". Phase 0 records `\dx`. If the only extension is `plpgsql`, keep the stock image and pin a fresh digest in the app PR. If `vector` (or anything else) is installed, replace `imageName` with a CloudNativePG image that ships that exact extension version, and prove it on a throwaway cluster. Do not use the Immich VectorChord image for these apps just because it happens to contain `vector`; the preload list would change the server.

## Why the current PVC stays where it is

A CloudNativePG `Cluster` initializes its own volume. Handing it `immich-database`, `silo-database`, or `bookorbit-database` is a good way to make that volume unreadable by both the old and the new server.

- The CloudNativePG image cannot be swapped for `ghcr.io/immich-app/postgres` or `pgvector/pgvector`. Those images do not contain the instance manager the operator execs into the pod.
- Files are owned by uid 999. CloudNativePG's postgres user is uid 26. Confirm with `id` in a throwaway pod of the chosen image before anyone reopens this idea; the other blockers stand either way.
- Directory layout differs. Immich's claim stores the data directory at subPath `data` (the mount is `/var/lib/postgresql/data` and `PGDATA` is that path). silo and bookorbit store it at `pgdata/` inside the claim. CloudNativePG uses its own layout under `/var/lib/postgresql/data/pgdata` and writes cluster metadata the Docker entrypoint does not.
- `bootstrap.import.type: monolith` is a physical `pg_basebackup`. VectorChord's `.so` has to match the target image build, not just the version string. A physical copy from the Immich image onto `cloudnative-vectorchord` is the failure mode the logical dump exists to avoid.

`bootstrap.initdb.import` of type `microservice` is logical, and it is allowed as an alternative to the script for a single load. It runs once, during bootstrap. A failed import means deleting the **new** `Cluster` (and only the PVCs that `Cluster` created) and starting over. The default in the phases below is an empty `initdb` plus `pg_restore`, because a failed restore is the same recovery (delete the new `Cluster`) without the one-shot bootstrap flag.

## Procedure

Do one app at a time. "The app" below means silo, bookorbit, or Immich. Immich's writers are the deployments `immich`, `immich-microservices`, and `immich-machine-learning`, plus the cronjob `immich-sync`. Confirm the names with `kubectl -n default get deploy,cronjob` before scaling anything. silo's writer is deployment `silo`. bookorbit's writer is deployment `bookorbit`.

The database pod is the StatefulSet of HelmRelease `<app>-database`. With a single app-template controller the pod name is `<app>-database-0` and the container is `postgresql`. Confirm with `kubectl -n default get pods -l app.kubernetes.io/instance=<app>-database` before exec. If that label returns nothing, stop and find the pod from the StatefulSet. Do not exec a different pod.

`logical-copy.sh` refuses to restore when the target host is `immich-database`, `silo-database`, or `bookorbit-database`. It refuses when the target already has user tables (extension-owned tables do not count). It never passes `--clean` and it never drops a database.

### Phase 0 — read the live database

Nothing is scaled and nothing is written.

```bash
kubectl -n default exec <app>-database-0 -c postgresql -- \
  psql -U <role> -d <database> -c '\dx'
kubectl -n default exec <app>-database-0 -c postgresql -- \
  psql -U <role> -d <database> -c 'SELECT version();'
kubectl -n default exec <app>-database-0 -c postgresql -- \
  psql -U <role> -d <database> -c 'SELECT pg_database_size(current_database());'
kubectl -n default exec <app>-database-0 -c postgresql -- \
  df -h /var/lib/postgresql/data
```

Record the role, the database name, the extension list, the Postgres version (expect 18), and how full the 10Gi or 5Gi claim is. Size the new `Cluster` volume at least as large as the used space plus headroom. `ceph-block` allows expansion; do the expansion on the new claim before restore if the dump will not fit. Do not resize the old claim down.

For Immich, compare `\dx` to [immich-database.yaml](cnpg-examples/immich-database.yaml). For silo and bookorbit, this output picks the image.

Save the rendered secret keys (`DB_USERNAME` / `DB_PASSWORD` or `DATABASE_URL`) somewhere you already keep secrets. The new `Cluster`'s `bootstrap.initdb.secret` must reuse the same role name and the same password. Do not rotate them in the cutover.

### Phase 1 — backup gate

Do not take a dump you intend to restore until this passes. Barman is not available on the StatefulSet. The gate for the old bytes is the Kopiur snapshot plus the logical dump. Barman takes over once the new cluster has the restored data (phase 6).

Confirm the Kopiur `SnapshotSchedule` named `<app>-database` in namespace `default` has a successful snapshot, and that the `SnapshotPolicy` source PVC is still `<app>-database`. Then trigger a fresh snapshot and wait until it succeeds. A failed or missing snapshot stops the procedure.

Take a rehearsal dump as well, from a PostgreSQL 18 client (the database pod's own `pg_dump` is the right major):

```bash
kubectl -n default exec <app>-database-0 -c postgresql -- \
  pg_dump -U <role> -d <database> -Fc --no-owner --no-privileges \
  > "/tmp/<app>-rehearsal.dump"
pg_restore -l "/tmp/<app>-rehearsal.dump" | head
```

Copy that file off the node. `pg_restore -l` must list the application tables. This file is a rehearsal. Writers are still running, so it is not the cutover copy.

`logical-copy.sh dump` is the same dump with a fixed output path and a skip when the file is already non-empty. Use it from a host that can reach the service, with `SOURCE_PASSWORD` in the environment rather than the argv:

```bash
SOURCE_HOST=<app>-database.default.svc.cluster.local \
SOURCE_USER=<role> SOURCE_DB=<database> SOURCE_PASSWORD=... \
DUMP_DIR=/path/outside/the/pvc \
  docs/cnpg-examples/logical-copy.sh dump
```

### Phase 2 — operator, then an empty cluster

Operator PR first. It installs the operator and the Barman Cloud plugin under `kubernetes/apps/database/`, and nothing else. After it is Ready, `kubectl explain cluster.postgresql.cnpg.io`, `kubectl explain database.postgresql.cnpg.io`, and `kubectl explain objectstore.barmancloud.cnpg.io` all succeed. The bucket `postgresql` already exists on Garage, and the 1Password item `postgresql` exists, before the next PR.

Then one empty cluster. Silo first. That PR adds `silo-db`, `silo-db-store`, the silo `ScheduledBackup`, and the shared ExternalSecret `postgresql-s3`. It does not add `bookorbit-db` or `immich-db`. It does not remove the HelmRelease, the PVC, or the Kopiur component, and it does not change the app DSN. `bootstrap` is `initdb` only. The initdb secret carries the existing role and password. Bookorbit waits until silo's empty cluster is Ready and you have either cut silo over or explicitly decided to leave silo empty and move on. Immich waits the same way. Immich's PR is the one that adds the `Database` CR.

Wait until the `Cluster` condition `Ready` is true. The primary is `<app>-db-rw.default.svc.cluster.local:5432`. The old service `<app>-database` still answers, and the app still uses it.

On the new primary, as the superuser CloudNativePG created:

- Immich: the `Database` reports the extensions present, and `SHOW shared_preload_libraries` includes `vchord.so`.
- silo / bookorbit: `\dx` matches phase 0. If `vector` is missing here, the image is wrong. Delete this new `Cluster` and fix the image. The old PVC is untouched because the new `Cluster` created a different claim.

Optional rehearsal: restore the phase 1 dump into a second `Cluster` named `<app>-db-rehearsal`, run the phase 4 checks, then delete `<app>-db-rehearsal` before starting the next app. Deleting that object deletes only the PVCs it created. It does not justify creating the other two application clusters early.

### Phase 3 — stop writers, final dump

This is the dual-run window starting point. Both servers stay up. Only one of them may take writes, and until phase 5 that one is still the StatefulSet. You are about to pause writers so the copy is consistent.

Scale the app's writers to 0. Leave the database StatefulSet at 1 replica. For Immich, suspend `immich-sync` as well so it does not call the API mid-copy.

```bash
kubectl -n default scale deploy/<writer> --replicas=0
```

Confirm no client remains (`pg_stat_activity` shows only your session and the usual background processes). Then dump again, to a new file:

```bash
SOURCE_HOST=<app>-database.default.svc.cluster.local \
SOURCE_USER=<role> SOURCE_DB=<database> SOURCE_PASSWORD=... \
DUMP_FILE=/path/outside/the/pvc/<app>-cutover.dump FORCE_DUMP=1 \
  docs/cnpg-examples/logical-copy.sh dump
```

`pg_restore -l` on the cutover file must succeed. Record the file size and a checksum. That file, plus the Kopiur snapshot from phase 1, is the gate. If either is missing, scale the writers back up and stop. The old database has not been modified.

### Phase 4 — restore and verify

Restore into the empty CloudNativePG database, not into the StatefulSet:

```bash
SOURCE_HOST=<app>-database.default.svc.cluster.local \
TARGET_HOST=<app>-db-rw.default.svc.cluster.local \
SOURCE_USER=<role> SOURCE_DB=<database> \
TARGET_USER=<role> TARGET_DB=<database> \
SOURCE_PASSWORD=... TARGET_PASSWORD=... \
DUMP_FILE=/path/outside/the/pvc/<app>-cutover.dump \
  docs/cnpg-examples/logical-copy.sh restore
```

The script comments `EXTENSION` entries out of the restore list because the operator, not the app role, creates extensions (the app role is not a superuser; `CREATE EXTENSION vchord` as that role fails). If `pg_restore` then errors on a missing type, the `Database` CR is missing an extension or `vchord.so` was not preloaded. Fix that, delete the new `Cluster`, recreate it empty, and restore again. Do not grant the app role superuser to get past the error and leave it that way.

If you would rather use `bootstrap.initdb.import` (`type: microservice`, `databases: [<database>]`, `externalClusters` host `<app>-database.default.svc.cluster.local`, password key `DB_PASSWORD` or `POSTGRES_PASSWORD`), do it instead of this restore, on a `Cluster` that has not bootstrapped yet, with writers already stopped. Do not do both against the same data directory. A failed import is recovered by deleting the new `Cluster` only.

Verify, still with the app scaled to 0:

```bash
# old
SOURCE_HOST=<app>-database.default.svc.cluster.local \
SOURCE_USER=<role> SOURCE_DB=<database> SOURCE_PASSWORD=... \
  docs/cnpg-examples/logical-copy.sh inventory > /tmp/<app>-old.txt
# new
SOURCE_HOST=<app>-db-rw.default.svc.cluster.local \
SOURCE_USER=<role> SOURCE_DB=<database> SOURCE_PASSWORD=... \
  docs/cnpg-examples/logical-copy.sh inventory > /tmp/<app>-new.txt
diff -u /tmp/<app>-old.txt /tmp/<app>-new.txt
```

Read the diff. It will not be empty: the `host=` line and `version()` differ by image build, and `pg_database_size` can move a little when indexes are rewritten. The gate is the same Postgres major, the same extension names, and the same table row counts. A row-count or extension mismatch stops the procedure. Scale the writers back to their previous replica count so they keep using the old service, and leave the new `Cluster` for inspection. Do not point the app at it.

### Phase 5 — point the app at the new service

Do this only after phase 4's diff is clean. Edit the DSN host and nothing else (same user, same password, same database name, port 5432).

| App | Change | Secret that must keep working |
| --- | --- | --- |
| silo | In [silo/app/helmrelease.yaml](../kubernetes/apps/default/silo/app/helmrelease.yaml), set the host inside `DATABASE_URL` to `silo-db-rw.default.svc.cluster.local.` | The app ExternalSecret already owns `DATABASE_URL`. The database HelmRelease secret is only the server's `POSTGRES_*` env. |
| bookorbit | In the database HelmRelease template, set the host inside `DATABASE_URL` to `bookorbit-db-rw.default.svc.cluster.local.` | The app `secretRef`s `bookorbit-database`, which this HelmRelease creates. See the warning under phase 7 before you delete that HelmRelease. |
| Immich | In the database HelmRelease template, set `DB_HOSTNAME` to `immich-db-rw.default.svc.cluster.local.` | The same secret carries `JWT_SECRET` and is mounted by the server, microservices, and machine-learning. Those three set a reloader annotation, so they restart onto the new host. The database StatefulSet does not, and its PVC mount is unchanged. `DB_HOSTNAME` is the app connection variable; it is also injected into the database container via `envFrom`. |

Scale the writers back up. For Immich, resume `immich-sync` only after the server is Ready. Hit the existing health endpoints (silo `/api/v1/ready`, bookorbit `/api/v1/health`, Immich `/server-info/ping`) and use the app.

The old StatefulSet is still Running and still has its PVC. Rollback is reverting the host string so the app uses `<app>-database` again. Rollback drops writes that landed on the new cluster after this phase. Before reverting, dump the new cluster with `logical-copy.sh dump` if those writes matter. Do not roll back by deleting the new `Cluster` first; you would throw away the only copy of the post-cutover writes.

### Phase 6 — soak

Both servers stay installed. The app uses the `-rw` service. The StatefulSet stays at 1 replica so a DSN revert still has somewhere to connect. Confirm nothing else in git still contains `<app>-database.default.svc.cluster.local` once the template above is merged (Immich's machine-learning and microservices follow the secret; they do not hardcode the host).

Soak ends when you say it ends, after all of these are true:

- The app has been used for real and its health checks are green.
- A Barman `Backup` for this cluster, taken **after** the phase 4 restore, is `completed`, and WAL archiving to `s3://postgresql/<app>/<cluster>/` is current. A backup of the empty database from before the restore does not count. Trigger one with a `Backup` object (`method: plugin`, `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`) rather than waiting for the next midnight if the soak needs it sooner.
- You have written down that rollback discards post-cutover writes, or you have rehearsed the DSN revert on a scratch cluster.

There is no timer in this runbook that makes the old PVC disposable.

### Phase 7 — remove the StatefulSet, keep the PVC

**Do not delete the old PVC in this phase. Do not delete the Flux `Kustomization` that carries the Kopiur component.**

That Flux `Kustomization` (`immich-database`, `silo-database`, or `bookorbit-database` in the app `ks.yaml`) is what applies [components/kopiur/backup](../kubernetes/components/kopiur/backup/kustomization.yaml). `prune: true` on it deletes the PVC. Leave the Flux `Kustomization` in place. Remove only the HelmRelease from the path it builds.

The PVC is not created by the HelmRelease. After the HelmRelease is gone, the path's `kustomization.yaml` can be `resources: []`. Kustomize still accepts that, and the Flux `components:` entry still renders the claim, the `SnapshotPolicy`, the `SnapshotSchedule`, and the `Restore`.

Secrets and chart objects that the HelmRelease owns have to move first, or deleting the release deletes them:

- silo: `DATABASE_URL` already lives on the app ExternalSecret. Drop `dependsOn: silo-database` from the app HelmRelease in the same PR. The database directory's `OCIRepository` is named `silo-database`; the app has its own `OCIRepository` named `silo`, so removing the database chart source does not unhook the app.
- bookorbit: the app `secretRef`s `bookorbit-database`, and that secret is created by the database HelmRelease. Move `DATABASE_URL` onto the app ExternalSecret, or a standalone ExternalSecret that still produces a secret of that name, before the HelmRelease is removed. The app chart source is `OCIRepository/bookorbit`, separate from `bookorbit-database`.
- Immich is not "just a database directory". [immich/database/kustomization.yaml](../kubernetes/apps/default/immich/database/kustomization.yaml) also lists:
  - `ocirepository.yaml`, name `immich`. This is the only app-template `OCIRepository` for the server, microservices, machine-learning, sync, and the database HelmRelease. Pruning it strands every Immich HelmRelease.
  - `configmap.yaml`, `immich-configmap`, mounted by the server, microservices, machine-learning, and the database pod.
  - `dragonfly.yaml`, the `immich-dragonfly` cache the server uses.

  Phase 7 removes `helmrelease.yaml` from that kustomization and nothing else in the directory. Move the ExternalSecret (name `immich-database`, including `JWT_SECRET` and the `DB_*` keys, hostname already on `-rw`) to the app or a standalone ExternalSecret **before** the HelmRelease goes, and drop `dependsOn: immich-database` from the server HelmRelease. `dependsOn` refers to the HelmRelease, not the Flux `Kustomization` of the same name; the Flux object stays.

After the PR reconciles:

```bash
kubectl -n default get pvc <app>-database
kubectl -n default get helmrelease <app>-database
kubectl -n default get cluster <app>-db
```

The PVC is `Bound`. The HelmRelease is gone. The `Cluster` is Ready. For Immich, `kubectl -n default get ocirepository immich,configmap immich-configmap,dragonfly immich-dragonfly` still returns all three.

### Phase 8 — delete the old PVC

**Do not delete the old PVC until** all of the following are true for that app:

1. Phase 7 has reconciled and the app is still healthy on `<app>-db-rw`.
2. You have an explicit go-ahead to destroy the old copy.
3. A completed Barman backup of the new cluster (phase 6) still lists as `completed` after phase 7, so the HelmRelease removal did not take the only good copy with it. Recovery is the [Barman bootstrap](#recover-a-cluster-from-barman), not a Kopiur restore of the old PVC.
4. `kubectl -n default get pvc` shows the CloudNativePG claim (`<app>-db-1`, or the name the `Cluster` status reports) `Bound`, and it is a different claim from `<app>-database`.

The deletion is its own PR, one app at a time. For silo and bookorbit the database Flux `Kustomization` now exists only to hold the Kopiur component, so removing that `Kustomization` from `ks.yaml` prunes the policy and the PVC together. For Immich, that same Flux `Kustomization` still owns the `OCIRepository`, the ConfigMap, and Dragonfly. Move those three to another path (the app kustomization is the natural one) and confirm they are still listed from a `Kustomization` you are not deleting **before** you remove `immich-database` from [immich/ks.yaml](../kubernetes/apps/default/immich/ks.yaml). Removing it while they are only listed there prunes the chart source and the cache along with the PVC.

`kubectl delete pvc` against `immich-database`, `silo-database`, or `bookorbit-database` is not a step in any earlier phase. `reclaimPolicy` on `ceph-block` is `Delete`; removing the claim destroys the volume.

## Standing rules

- Do not delete, shrink, or snapshot-restore over `immich-database`, `silo-database`, or `bookorbit-database` as part of standing up CloudNativePG.
- Do not scale the database StatefulSet to 0 to "free" the PVC. The dump needs it, and the soak needs it.
- Do not change the app DSN before the row-count diff is clean.
- Do not remove the HelmRelease and the PVC in one pull request.
- A failed new `Cluster` is deleted by name (`immich-db`, `silo-db`, `bookorbit-db`, or a `*-rehearsal` cluster). That deletion does not select the old PVC. If a command's PVC name is the HelmRelease name, you are pointed at the live data and you stop.
