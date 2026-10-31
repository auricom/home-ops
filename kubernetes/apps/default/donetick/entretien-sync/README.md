# Donetick entretien sync

Daily CronJob that copies the house maintenance frequency checklist into Donetick chores with calendar-aware due dates.

## Schedule

Daily at 07:00 Europe/Paris (`0 7 * * *`). Kubernetes can start a missed run within the next 6 hours. Runs cannot overlap (`concurrencyPolicy: Forbid`).

Calendar chores are due on the **15th at 09:00 Europe/Paris**, with daylight-saving changes handled at the target date. If the current month is scheduled but the 15th has passed, the initial date stays overdue in that month. Otherwise the next scheduled month is used.

| Chore                                                     | Scheduled months                   |
| --------------------------------------------------------- | ---------------------------------- |
| Gutters                                                   | April, November                    |
| Laurel hedge                                              | June, September                    |
| Fruit-tree treatments                                     | February, November                 |
| Radiator bleeding                                         | September                          |
| Clear outdoor PAC unit                                    | September, November                |
| Lifting station                                           | October                            |
| Roof / attic inspection                                   | March / December (separate chores) |
| Solar-panel cleaning                                      | April                              |
| Pool opening / winterizing                                | April / October (separate chores)  |
| Gate and garage door                                      | March                              |
| Alarm / cameras                                           | December                           |
| Tiled terrace / wooden terrace                            | April                              |
| Outdoor taps frost protection                             | November                           |
| Tree pruning (outside frost)                              | January                            |
| Fruit-tree pruning / summer pruning                       | February / July                    |
| Roses / summer-flowering shrubs / spring-flowering shrubs | March / March / May                |

Roof moss treatment and pool filter-media replacement retain their multi-year interval, with an April anchor. Their first date is the first April 15 no earlier than one interval from creation or migration.

Chores without calendar guidance start one documented interval after creation or migration, at 09:00 local time. Month-end dates are clamped to the last valid day. Later valid due dates and overdue work are preserved.

### Seasonal recurring chores

- Pool care: May–September.
- Garden care: April–October.
- PAC heating checks: October–April.

Monthly seasonal checks use the 15th of each active month. Weekly seasonal chores retain a seven-day interval. The daily sync moves a weekly out-of-season date or winter backlog to the first day of the next active season at 09:00. Valid overdue work remains overdue while in season.

Donetick has no native seasonal restriction for weekly chores. Completing one can briefly produce an out-of-season date until the next successful daily sync. The daily job must keep running for this correction to work.

## What is synced

Source: `https://raw.githubusercontent.com/auricom/docs/main/content/docs/maison/entretien.md`, section **Récapitulatif par fréquence**. “À chaque utilisation” is skipped; tasks appearing only in the detailed tables or seasonal calendar are not added.

The seasonal calendar is encoded explicitly in `CALENDAR_MONTHS`, `SEASON_MONTHS`, and `SPLITS` in `sync.py`. Update these rules when the document's seasonal guidance changes. Unknown frequency headings, duplicate planned names, and unrecognized “en saison” / “saison de chauffe” items fail instead of silently receiving a default season.

| Checklist section  | Default Donetick schedule                       |
| ------------------ | ----------------------------------------------- |
| Chaque semaine     | `interval` / 1 / `weeks`                        |
| Chaque mois        | `interval` / 1 / `months`                       |
| Chaque trimestre   | `interval` / 3 / `months`                       |
| Chaque semestre    | `interval` / 6 / `months`                       |
| Chaque année       | `interval` / 1 / `years`                        |
| Tous les 1 à 2 ans | `interval` / lower bound / `years` (default 1)  |
| Tous les 2 à 5 ans | `interval` / lower bound / `years` (default 2)  |
| Tous les 10 ans    | `interval` / lower bound / `years` (default 10) |

Calendar rules override these defaults with `day_of_the_month` / 15 and explicit months. The simple `monthly` and `yearly` types in Donetick v0.1.83 ignore the frequency multiplier, so interval metadata is required for quarterly, six-monthly, and multi-year work.

Ranges such as “3–5 ans” use the lower bound and retain the original wording in the description. Year counts are read only under multi-year headings, so “3 à 6 mois” under Chaque semestre stays six months.

## Migration and idempotency

The job lists `GET /api/v1/chores/?includeArchived=true`. Chores are identified by `[Entretien] ` plus their checklist text, or their replacement name for a split entry.

Existing chores containing `Géré par donetick-entretien-sync.` receive a one-time schedule and date repair. The successful PUT saves the due date and `Planning entretien : v2.` together. Subsequent runs preserve completion progress and valid overdue dates. Changes to schedule type, interval, metadata, or rolling behavior repair the schedule again; description-only updates preserve dates.

For a combined entry, the first replacement reuses the original ID and its history. Other replacements inherit assignment, notification preferences, points, priority, project, privacy, approval, and completion-window settings. New siblings receive fresh descriptions and do not duplicate history, labels, subtasks, or thing triggers. Retries find the renamed first replacement and create only missing siblings.

- Creates missing chores via `POST /api/v1/chores/` using the `secretkey` header.
- Updates drifted managed chores via `PUT /api/v1/chores/`.
- Leaves archived chores inactive; an archived combined entry also suppresses new replacements.
- Leaves descriptions without the sync marker untouched.
- Leaves unrelated chores untouched and logs removed checklist names as `left`; nothing is deleted.

Updates preserve the existing ID, history, assignment, notifications, points, priority, project, privacy, approval, completion window, and thing trigger. Labels and subtasks are omitted from PUT, which preserves them in Donetick. Removing the managed prefix breaks matching; removing the description marker opts an existing chore out of updates.

New chores without an existing combined entry are unassigned, active, and notify one day before the due time and when due. The API token's user must be able to edit managed chores.

## 1Password

Add a field to the existing item `donetick` (the same item as `DONETICK_JWT_SECRET`):

| Item       | Field                | Value                 |
| ---------- | -------------------- | --------------------- |
| `donetick` | `DONETICK_API_TOKEN` | Donetick access token |

In Donetick: Settings → Access tokens → Generate new token. Copy the `dt_…` value once. The ExternalSecret reads only that field from the `onepassword-connect` ClusterSecretStore. The Donetick app secret is unchanged and does not need this field.

Until the field exists, the ExternalSecret stays unready and the CronJob cannot start.

The job calls Donetick in-cluster at `http://donetick.default.svc.cluster.local:2021`, not the public URL.

## Dry-run and local parse

Self-tests (no external network; includes a temporary localhost mock API server):

```bash
python3 kubernetes/apps/default/donetick/entretien-sync/resources/sync.py --self-test
```

Print schedules, metadata, and initial due dates without calling Donetick:

```bash
python3 kubernetes/apps/default/donetick/entretien-sync/resources/sync.py --print
```

`ENTRETIEN_FILE` reads a local markdown file instead of GitHub.

In the cluster, `DRY_RUN=true` lists chores and logs `dry-run create` / `dry-run update` with old/new due dates and without POST or PUT. Review this output before the first applying run:

```bash
kubectl -n default create job donetick-entretien-sync-dry-run \
  --from=cronjob/donetick-entretien-sync \
  --dry-run=client -o json \
| python3 -c 'import json,sys; job=json.load(sys.stdin); c=job["spec"]["template"]["spec"]["containers"][0]; c.setdefault("env", []).append({"name":"DRY_RUN","value":"true"}); json.dump(job, sys.stdout)' \
| kubectl apply -f -
kubectl -n default logs -f job/donetick-entretien-sync-dry-run
```

The summary line is `donetick-entretien-sync: created=… updated=… skipped=… archived=… left=… errors=…`. Any hard failure (fetch, parse, auth, HTTP) exits non-zero. A single create or update error is counted and the job still exits non-zero after attempting the rest.
