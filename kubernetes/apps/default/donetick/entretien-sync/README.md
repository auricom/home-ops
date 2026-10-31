# Donetick entretien sync

Weekly CronJob that copies the house maintenance frequency checklist into Donetick chores.

## Schedule

Sunday 07:00 Europe/Paris (`0 7 * * 0`). If the cluster misses that minute, Kubernetes still starts the job within the next 6 hours. A second run cannot overlap (`concurrencyPolicy: Forbid`).

New chores get a first due time of 09:00 Europe/Paris on the run day, or the next day when the job runs after that hour. Later due dates are left to Donetick.

## What is synced

Source: `https://raw.githubusercontent.com/auricom/docs/main/content/docs/maison/entretien.md`, section **Récapitulatif par fréquence** only. "À chaque utilisation" is skipped. Checkboxes outside that section (the "à confirmer" list, the seasonal calendar) are ignored.

| Checklist section | Donetick |
|---|---|
| Chaque semaine | `weekly` / 1 |
| Chaque mois | `monthly` / 1 |
| Chaque trimestre | `monthly` / 3 |
| Chaque semestre | `monthly` / 6 |
| Chaque année | `yearly` / 1 |
| Tous les 1 à 2 ans | `yearly` / 1, unless the line names a year count |
| Tous les 2 à 5 ans | `yearly` / lower bound of the line (section default 2) |
| Tous les 10 ans | `yearly` / lower bound of the line (section default 10) |

A range such as "3–5 ans" or "10–15 ans" becomes the lower bound, and the original wording is stored in the description. Donetick has no variable interval. Year counts are read only under the three multi-year headings, so "3 à 6 mois" under Chaque semestre stays `monthly` / 6.

An unknown `###` heading inside the récapitulatif fails the job, so a new cadence is not dropped silently.

## Idempotency

Managed chores are named `[Entretien] ` plus the checkbox text. The job lists `GET /api/v1/chores/?includeArchived=true`, then:

- creates a missing active chore (`POST /api/v1/chores/`, header `secretkey`)
- updates an active chore when `frequencyType`, `frequency`, or the generated description changed (`PUT /api/v1/chores/`)
- skips a chore that already matches
- leaves an inactive chore inactive (archive is not undone, and no duplicate is created)
- does not delete anything, including `[Entretien]` chores that disappeared from the checklist (those are logged as `left`)

Chores whose names do not start with `[Entretien] ` are never read for updates. Renaming a managed chore breaks the match and the next run creates a new one.

On update, assignment, notification, points, project, labels, subtasks, privacy, and the due date are copied back so the PUT does not wipe them. A description that no longer contains `Géré par donetick-entretien-sync.` is treated as edited by hand and is not replaced. A thing trigger linked to the chore is sent again with the update.

New chores are unassigned (`no_assignee`), active, and notify one day before the due time and when due. Assign them in the UI afterwards; the sync keeps that assignment.

The API token's user must be able to edit the chores. Chores are created by that user, which is enough. A circle admin token also passes Donetick's edit check.

## 1Password

Add a field to the existing item `donetick` (the same item as `DONETICK_JWT_SECRET`):

| Item | Field | Value |
|---|---|---|
| `donetick` | `DONETICK_API_TOKEN` | Donetick access token |

In Donetick: Settings → Access tokens → Generate new token. Copy the `dt_…` value once. The ExternalSecret reads only that field from the `onepassword-connect` ClusterSecretStore. The Donetick app secret is unchanged and does not need this field.

Until the field exists, the ExternalSecret stays unready and the CronJob cannot start.

The job calls Donetick in-cluster at `http://donetick.default.svc.cluster.local:2021`, not the public URL.

## Dry-run and local parse

Parser self-test, no network:

```bash
python3 kubernetes/apps/default/donetick/entretien-sync/resources/sync.py --self-test
```

Print the chores that would be synced, without calling Donetick:

```bash
python3 kubernetes/apps/default/donetick/entretien-sync/resources/sync.py --print
```

`ENTRETIEN_FILE` reads a local markdown file instead of GitHub.

In the cluster, `DRY_RUN=true` lists chores and logs `dry-run create` / `dry-run update` without POST or PUT:

```bash
kubectl -n default create job donetick-entretien-sync-dry-run \
  --from=cronjob/donetick-entretien-sync \
  --dry-run=client -o json \
| python3 -c 'import json,sys; job=json.load(sys.stdin); c=job["spec"]["template"]["spec"]["containers"][0]; c.setdefault("env", []).append({"name":"DRY_RUN","value":"true"}); json.dump(job, sys.stdout)' \
| kubectl apply -f -
kubectl -n default logs -f job/donetick-entretien-sync-dry-run
```

The summary line is `donetick-entretien-sync: created=… updated=… skipped=… archived=… left=… errors=…`. Any hard failure (fetch, parse, auth, HTTP) exits non-zero. A single create or update error is counted and the job still exits non-zero after attempting the rest.
