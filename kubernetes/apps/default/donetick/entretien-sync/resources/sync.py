#!/usr/bin/env python3
"""Sync Donetick chores from the house maintenance frequency checklist.

Source of truth is the "Récapitulatif par fréquence" section of
auricom/docs content/docs/maison/entretien.md. Chores are matched by the
name prefix "[Entretien] ". User chores outside that prefix are never
modified or deleted. Archived (inactive) managed chores are left archived.

Donetick v0.1.83 internal API (secretkey header):
  GET  /api/v1/chores/?includeArchived=true
  POST /api/v1/chores/
  PUT  /api/v1/chores/
The external POST /eapi/v1/chore endpoint only creates one-off tasks, so
it is not used. Labels are not applied: that API rejects the access token.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - toolbox image provides zoneinfo
    ZoneInfo = None  # type: ignore

MARKER = "Géré par donetick-entretien-sync."
DEFAULT_PREFIX = "[Entretien] "
DEFAULT_SOURCE_URL = (
    "https://raw.githubusercontent.com/auricom/docs/main/content/docs/maison/entretien.md"
)
DEFAULT_BASE_URL = "http://donetick.default.svc.cluster.local:2021"
USER_AGENT = "donetick-entretien-sync"

# (frequencyType, frequency, item text may override the year count)
# Multi-year sections use the lower bound when the checklist gives a range.
# Donetick expresses that as yearly + frequency (every N years).
SECTIONS: Dict[str, Tuple[str, int, bool]] = {
    "chaque semaine": ("weekly", 1, False),
    "chaque mois": ("monthly", 1, False),
    "chaque trimestre": ("monthly", 3, False),
    "chaque semestre": ("monthly", 6, False),
    "chaque année": ("yearly", 1, False),
    "tous les 1 à 2 ans": ("yearly", 1, True),
    "tous les 2 à 5 ans": ("yearly", 2, True),
    "tous les 10 ans": ("yearly", 10, True),
}
SKIP_SECTIONS = {"à chaque utilisation"}

H2_OR_H3 = re.compile(r"^(#{2,3})\s+(.+?)\s*$")
CHECKBOX = re.compile(r"^\s*-\s+\[[ xX]\]\s+(.+?)\s*$")
YEAR_RANGE = re.compile(r"(\d+)\s*(?:à|–|—|-)\s*(\d+)\s*ans", re.IGNORECASE)
YEAR_EXACT = re.compile(r"(\d+)\s*ans", re.IGNORECASE)


class SyncError(Exception):
    """Failure that should fail the CronJob."""


class ChoreSpec:
    def __init__(
        self,
        name: str,
        section: str,
        frequency_type: str,
        frequency: int,
        description: str,
        cadence_note: str,
    ) -> None:
        self.name = name
        self.section = section
        self.frequency_type = frequency_type
        self.frequency = frequency
        self.description = description
        self.cadence_note = cadence_note

    def key(self) -> Tuple[str, int, str]:
        return (self.frequency_type, self.frequency, self.description)


def log(message: str) -> None:
    print(message, flush=True)


def env_bool(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def normalize_heading(text: str) -> str:
    text = text.replace("\u00a0", " ")
    text = re.sub(r"\s+", " ", text).strip().casefold()
    return text


def year_override(text: str) -> Optional[Tuple[int, str]]:
    """Return (lower bound years, note) when the checkbox names a year span."""
    ranged = YEAR_RANGE.search(text)
    if ranged:
        lower = int(ranged.group(1))
        upper = int(ranged.group(2))
        if lower < 1 or upper < lower:
            raise SyncError("invalid year range in checklist item: {0}".format(text))
        note = (
            "Cadence du document : tous les {0} à {1} ans. "
            "Donetick n'a pas d'intervalle variable : yearly / {0} (borne basse)."
        ).format(lower, upper)
        return lower, note
    exact = YEAR_EXACT.search(text)
    if exact:
        years = int(exact.group(1))
        if years < 1:
            raise SyncError("invalid year count in checklist item: {0}".format(text))
        note = "Cadence du document : tous les {0} ans.".format(years)
        return years, note
    return None


def build_description(section: str, frequency_type: str, frequency: int, cadence_note: str) -> str:
    lines = [
        MARKER,
        "Source : auricom/docs, content/docs/maison/entretien.md.",
        "Section : {0}.".format(section),
        "Récurrence Donetick : {0} / {1}.".format(frequency_type, frequency),
    ]
    if cadence_note:
        lines.append(cadence_note)
    lines.append(
        "Le préfixe [Entretien] identifie cette tâche. Ne pas le retirer du nom."
    )
    return "\n".join(lines)


def parse_checklist(markdown: str, prefix: str) -> List[ChoreSpec]:
    lines = markdown.splitlines()
    start: Optional[int] = None
    for index, line in enumerate(lines):
        match = H2_OR_H3.match(line)
        if not match or match.group(1) != "##":
            continue
        if "récapitulatif par fréquence" in normalize_heading(match.group(2)):
            start = index + 1
            break
    if start is None:
        raise SyncError("checklist has no 'Récapitulatif par fréquence' section")

    body: List[str] = []
    for line in lines[start:]:
        match = H2_OR_H3.match(line)
        if match and match.group(1) == "##":
            break
        body.append(line)

    specs: List[ChoreSpec] = []
    seen: Dict[str, str] = {}
    section_title: Optional[str] = None
    section_key: Optional[str] = None

    for line in body:
        heading = H2_OR_H3.match(line)
        if heading and heading.group(1) == "###":
            section_title = heading.group(2).strip()
            section_key = normalize_heading(section_title)
            if section_key not in SECTIONS and section_key not in SKIP_SECTIONS:
                known = ", ".join(sorted(list(SECTIONS) + list(SKIP_SECTIONS)))
                raise SyncError(
                    "unknown frequency section {0!r}; known sections: {1}".format(
                        section_title, known
                    )
                )
            continue

        checkbox = CHECKBOX.match(line)
        if not checkbox:
            continue
        if section_key is None or section_title is None:
            raise SyncError("checkbox found before a frequency heading: {0}".format(line))
        if section_key in SKIP_SECTIONS:
            continue

        frequency_type, frequency, variable = SECTIONS[section_key]
        label = re.sub(r"\s+", " ", checkbox.group(1)).strip()
        if not label:
            raise SyncError("empty checkbox under {0}".format(section_title))

        cadence_note = ""
        if variable:
            override = year_override(label)
            if override is not None:
                frequency, cadence_note = override
            else:
                cadence_note = (
                    "Cadence du document : {0}. "
                    "Donetick : yearly / {1} (borne basse de la section)."
                ).format(section_title, frequency)

        name = "{0}{1}".format(prefix, label)
        if name in seen:
            raise SyncError(
                "duplicate checklist chore {0!r} (also under {1})".format(name, seen[name])
            )
        seen[name] = section_title
        specs.append(
            ChoreSpec(
                name=name,
                section=section_title,
                frequency_type=frequency_type,
                frequency=frequency,
                description=build_description(
                    section_title, frequency_type, frequency, cadence_note
                ),
                cadence_note=cadence_note,
            )
        )

    if not specs:
        raise SyncError("checklist section parsed to zero chores")
    return specs


def fetch_text(url: str, timeout: int) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            return response.read().decode(charset)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")[:500]
        raise SyncError("GET {0} failed: HTTP {1} {2}".format(url, exc.code, body)) from exc
    except urllib.error.URLError as exc:
        raise SyncError("GET {0} failed: {1}".format(url, exc.reason)) from exc


def load_checklist(prefix: str) -> List[ChoreSpec]:
    path = os.environ.get("ENTRETIEN_FILE", "").strip()
    if path:
        log("reading checklist from {0}".format(path))
        with open(path, "r", encoding="utf-8") as handle:
            markdown = handle.read()
    else:
        url = os.environ.get("ENTRETIEN_URL", DEFAULT_SOURCE_URL).strip()
        log("fetching checklist {0}".format(url))
        markdown = fetch_text(url, timeout=60)
    specs = parse_checklist(markdown, prefix)
    log("parsed {0} chores from the frequency checklist".format(len(specs)))
    return specs


def api_request(base_url: str, token: str, method: str, path: str, payload: Optional[dict] = None) -> Any:
    url = base_url.rstrip("/") + path
    data = None
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        "secretkey": token,
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8")
            if not raw:
                return {}
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")[:800]
        raise SyncError("{0} {1} failed: HTTP {2} {3}".format(method, path, exc.code, body)) from exc
    except urllib.error.URLError as exc:
        raise SyncError("{0} {1} failed: {2}".format(method, path, exc.reason)) from exc


def list_chores(base_url: str, token: str) -> List[dict]:
    payload = api_request(
        base_url,
        token,
        "GET",
        "/api/v1/chores/?includeArchived=true",
    )
    chores = payload.get("res") if isinstance(payload, dict) else None
    if not isinstance(chores, list):
        raise SyncError("chore list response has no res array")
    return chores


def last_sunday_utc(year: int, month: int) -> datetime:
    if month == 12:
        cursor = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    else:
        cursor = datetime(year, month + 1, 1, tzinfo=timezone.utc)
    last = (cursor - timedelta(days=1)).replace(hour=1, minute=0, second=0, microsecond=0)
    return last - timedelta(days=(last.weekday() + 1) % 7)


def europe_paris_offset(when: datetime) -> timezone:
    """CET/CEST when tzdata is missing. EU rule: last Sunday of March/October at 01:00 UTC."""
    utc = when.astimezone(timezone.utc)
    start = last_sunday_utc(utc.year, 3)
    end = last_sunday_utc(utc.year, 10)
    hours = 2 if start <= utc < end else 1
    return timezone(timedelta(hours=hours), name="Europe/Paris")


def resolve_timezone(name: str, now: datetime) -> Any:
    if ZoneInfo is not None:
        try:
            return ZoneInfo(name)
        except Exception as exc:  # ZoneInfoNotFoundError or missing tzdata
            log("warning: timezone {0} unavailable ({1}); using EU civil-time rules".format(name, exc))
    if name == "Europe/Paris":
        return europe_paris_offset(now)
    log("warning: timezone {0} unavailable; using UTC+1 for the first due time".format(name))
    return timezone(timedelta(hours=1))


def initial_due(now: datetime, tz: Any, hour: int) -> str:
    local_now = now.astimezone(tz)
    due = local_now.replace(hour=hour, minute=0, second=0, microsecond=0)
    if due <= local_now:
        due += timedelta(days=1)
    return due.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def notification_metadata() -> dict:
    return {
        "dueDate": True,
        "predue": True,
        "templates": [{"value": 1, "unit": "d"}],
    }


def create_payload(spec: ChoreSpec, due: str) -> dict:
    return {
        "name": spec.name,
        "description": spec.description,
        "frequencyType": spec.frequency_type,
        "frequency": spec.frequency,
        "assignStrategy": "no_assignee",
        "isActive": True,
        "isPrivate": False,
        "isRolling": False,
        "notification": True,
        "notificationMetadata": notification_metadata(),
        "priority": 0,
        "nextDueDate": due,
    }


def managed_description(chore: dict) -> bool:
    description = chore.get("description") or ""
    return MARKER in description


def needs_update(chore: dict, spec: ChoreSpec) -> bool:
    frequency_changed = (
        chore.get("frequencyType") != spec.frequency_type
        or int(chore.get("frequency") or 0) != spec.frequency
    )
    description_changed = managed_description(chore) and (chore.get("description") or "") != spec.description
    return frequency_changed or description_changed


def description_for_update(chore: dict, spec: ChoreSpec) -> str:
    current = chore.get("description")
    if current and not managed_description(chore):
        return current
    return spec.description


def thing_trigger(chore: dict) -> Optional[dict]:
    link = chore.get("thingChore") or None
    if not isinstance(link, dict):
        return None
    thing_id = link.get("thingId")
    state = link.get("triggerState")
    if thing_id is None or not state:
        return None
    trigger = {"thingID": thing_id, "triggerState": state}
    if link.get("condition"):
        trigger["condition"] = link["condition"]
    return trigger


def update_payload(chore: dict, spec: ChoreSpec) -> dict:
    frequency_changed = (
        chore.get("frequencyType") != spec.frequency_type
        or int(chore.get("frequency") or 0) != spec.frequency
    )
    assignees = []
    for assignee in chore.get("assignees") or []:
        user_id = assignee.get("userId")
        if user_id:
            assignees.append({"userId": user_id})

    payload: Dict[str, Any] = {
        "id": chore["id"],
        "name": spec.name,
        "description": description_for_update(chore, spec),
        "frequencyType": spec.frequency_type,
        "frequency": spec.frequency,
        "assignStrategy": chore.get("assignStrategy") or "no_assignee",
        "assignees": assignees,
        "isRolling": bool(chore.get("isRolling")),
        "isActive": bool(chore.get("isActive", True)),
        "notification": bool(chore.get("notification")),
        "requireApproval": bool(chore.get("requireApproval")),
        "isPrivate": bool(chore.get("isPrivate")),
        "priority": int(chore.get("priority") or 0),
    }
    if chore.get("assignedTo") is not None:
        payload["assignedTo"] = chore["assignedTo"]
    if payload["notification"]:
        payload["notificationMetadata"] = chore.get("notificationMetadata") or notification_metadata()
    if chore.get("points") is not None:
        payload["points"] = chore["points"]
    if chore.get("completionWindow") is not None:
        payload["completionWindow"] = chore["completionWindow"]
    if chore.get("projectId") is not None:
        payload["projectId"] = chore["projectId"]
    # A changed simple weekly/monthly/yearly schedule must not keep interval metadata.
    # Description-only updates keep whatever schedule metadata the user added.
    if not frequency_changed and chore.get("frequencyMetadata") is not None:
        payload["frequencyMetadata"] = chore["frequencyMetadata"]
    trigger = thing_trigger(chore)
    if trigger is not None:
        payload["thingTrigger"] = trigger
    return payload


def active_chores(group: List[dict]) -> List[dict]:
    return [chore for chore in group if chore.get("isActive", True)]


def plan(specs: List[ChoreSpec], chores: List[dict], prefix: str) -> Tuple[list, List[str]]:
    grouped: Dict[str, List[dict]] = {}
    for chore in chores:
        name = chore.get("name") or ""
        grouped.setdefault(name, []).append(chore)

    actions = []
    matched = set()
    for spec in specs:
        matched.add(spec.name)
        group = grouped.get(spec.name, [])
        active = active_chores(group)
        if len(active) > 1:
            raise SyncError("multiple active chores are named {0!r}".format(spec.name))
        if active:
            current = active[0]
            kind = "update" if needs_update(current, spec) else "skip"
            actions.append((kind, spec, current))
            continue
        if group:
            actions.append(("archived", spec, group[0]))
            continue
        actions.append(("create", spec, None))

    left = sorted(
        name
        for name in grouped
        if name.startswith(prefix) and name not in matched
    )
    return actions, left


def apply_actions(
    actions: list,
    base_url: str,
    token: str,
    due: str,
    dry_run: bool,
) -> Dict[str, int]:
    counts = {"created": 0, "updated": 0, "skipped": 0, "archived": 0, "errors": 0}
    for kind, spec, chore in actions:
        detail = "{0} {1}/{2}".format(spec.frequency_type, spec.frequency, spec.name)
        if kind == "skip":
            counts["skipped"] += 1
            log("skip {0}".format(detail))
            continue
        if kind == "archived":
            counts["archived"] += 1
            log("archived {0} (id {1}, left inactive)".format(detail, chore.get("id")))
            continue
        if kind == "create":
            payload = create_payload(spec, due)
            if dry_run:
                counts["created"] += 1
                log("dry-run create {0}".format(detail))
                continue
            try:
                result = api_request(base_url, token, "POST", "/api/v1/chores/", payload)
            except SyncError as exc:
                counts["errors"] += 1
                log("error create {0}: {1}".format(spec.name, exc))
                continue
            counts["created"] += 1
            log("create {0} id={1}".format(detail, result.get("res")))
            warnings = result.get("warnings") if isinstance(result, dict) else None
            if warnings:
                log("warning create {0}: {1}".format(spec.name, warnings))
            continue
        if kind == "update":
            payload = update_payload(chore, spec)
            if dry_run:
                counts["updated"] += 1
                log("dry-run update {0} id={1}".format(detail, chore.get("id")))
                continue
            try:
                api_request(base_url, token, "PUT", "/api/v1/chores/", payload)
            except SyncError as exc:
                counts["errors"] += 1
                log("error update {0}: {1}".format(spec.name, exc))
                continue
            counts["updated"] += 1
            log("update {0} id={1}".format(detail, chore.get("id")))
            continue
        raise SyncError("unknown action {0}".format(kind))
    return counts


def run_sync() -> int:
    prefix = os.environ.get("NAME_PREFIX", DEFAULT_PREFIX)
    if not prefix:
        raise SyncError("NAME_PREFIX is empty")
    dry_run = env_bool("DRY_RUN")
    specs = load_checklist(prefix)
    if "--print" in sys.argv:
        for spec in specs:
            log("{0}/{1}\t{2}".format(spec.frequency_type, spec.frequency, spec.name))
        return 0

    token = os.environ.get("DONETICK_DOCS_API_TOKEN", "").strip()
    if not token:
        raise SyncError("DONETICK_DOCS_API_TOKEN is empty")
    base_url = os.environ.get("DONETICK_BASE_URL", DEFAULT_BASE_URL).strip()
    if not base_url:
        raise SyncError("DONETICK_BASE_URL is empty")

    chores = list_chores(base_url, token)
    log("listed {0} existing chores".format(len(chores)))
    actions, left = plan(specs, chores, prefix)
    hour = int(os.environ.get("DUE_HOUR", "9"))
    now = datetime.now(timezone.utc)
    tz_name = os.environ.get("DUE_TIMEZONE", "Europe/Paris")
    tz = resolve_timezone(tz_name, now)
    due = initial_due(now, tz, hour)
    log("initial due for new chores: {0} ({1} local hour {2})".format(due, tz_name, hour))
    counts = apply_actions(actions, base_url, token, due, dry_run)
    log(
        "donetick-entretien-sync: created={created} updated={updated} skipped={skipped} "
        "archived={archived} left={left} errors={errors} dry_run={dry_run}".format(
            left=len(left),
            dry_run=str(dry_run).lower(),
            **counts,
        )
    )
    for name in left:
        log("left {0} (managed prefix, not in the checklist, not deleted)".format(name))
    if counts["errors"]:
        return 1
    return 0


def assert_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        raise AssertionError("{0}: expected {1!r}, got {2!r}".format(label, expected, actual))


def run_self_test() -> None:
    fixture = """
## Avant
- [ ] Volets roulants qui ne doivent pas être synchronisés

## 📅 Récapitulatif par fréquence

### À chaque utilisation
- [ ] Filtre à peluches et bac du sèche-linge

### Chaque semaine
- [ ] Micro-ondes

### Chaque mois
- [ ] Tester les détecteurs de fumée

### Chaque trimestre
- [ ] Bouches de VMC

### Chaque semestre
- [ ] Gouttières (printemps + fin d'automne)

### Chaque année
- [ ] Purge des radiateurs (septembre–octobre)

### Tous les 1 à 2 ans
- [ ] Terrasse bois : nettoyage + saturateur

### Tous les 2 à 5 ans
- [ ] Entretien professionnel de la pompe à chaleur (obligatoire, 2 ans)
- [ ] Démoussage de la toiture (3–5 ans)
- [ ] Contrôle par un couvreur (5 ans)

### Tous les 10 ans
- [ ] Remplacer les détecteurs de fumée
- [ ] Remplacement de l'onduleur photovoltaïque (~10–15 ans)

## 🗓️ Calendrier saisonnier
- [ ] Cette case est hors section
"""
    specs = parse_checklist(fixture, DEFAULT_PREFIX)
    by_label = {spec.name[len(DEFAULT_PREFIX):]: spec for spec in specs}
    assert_equal(len(specs), 11, "fixture count")
    assert_equal("Volets" in by_label, False, "ignored checkbox outside the section")
    assert_equal("Filtre à peluches et bac du sèche-linge" in by_label, False, "skipped per-use item")
    assert_equal(by_label["Micro-ondes"].key()[:2], ("weekly", 1), "weekly")
    assert_equal(by_label["Tester les détecteurs de fumée"].key()[:2], ("monthly", 1), "monthly")
    assert_equal(by_label["Bouches de VMC"].key()[:2], ("monthly", 3), "quarter")
    assert_equal(by_label["Gouttières (printemps + fin d'automne)"].key()[:2], ("monthly", 6), "semester")
    assert_equal(by_label["Purge des radiateurs (septembre–octobre)"].key()[:2], ("yearly", 1), "yearly")
    assert_equal(by_label["Terrasse bois : nettoyage + saturateur"].frequency, 1, "1-2 years lower bound")
    assert_equal(by_label["Entretien professionnel de la pompe à chaleur (obligatoire, 2 ans)"].frequency, 2, "exact 2 years")
    assert_equal(by_label["Démoussage de la toiture (3–5 ans)"].frequency, 3, "en dash range")
    assert_equal(by_label["Contrôle par un couvreur (5 ans)"].frequency, 5, "exact 5 years")
    assert_equal(by_label["Remplacer les détecteurs de fumée"].frequency, 10, "section default 10")
    assert_equal(by_label["Remplacement de l'onduleur photovoltaïque (~10–15 ans)"].frequency, 10, "10-15 lower bound")
    assert_equal(MARKER in by_label["Micro-ondes"].description, True, "marker")

    micro = by_label["Micro-ondes"]
    existing = [
        {
            "id": 4,
            "name": micro.name,
            "frequencyType": "weekly",
            "frequency": 1,
            "description": micro.description,
            "isActive": True,
            "assignStrategy": "least_completed",
            "assignees": [{"userId": 9}],
            "assignedTo": 9,
            "notification": False,
            "priority": 2,
            "points": 5,
        },
        {
            "id": 8,
            "name": "[Entretien] Ancienne tâche",
            "frequencyType": "weekly",
            "frequency": 1,
            "isActive": True,
        },
        {
            "id": 9,
            "name": "Courses",
            "frequencyType": "weekly",
            "frequency": 1,
            "isActive": True,
        },
    ]
    actions, left = plan(specs, existing, DEFAULT_PREFIX)
    kinds = {spec.name: kind for kind, spec, _chore in actions}
    assert_equal(kinds[micro.name], "skip", "unchanged chore is skipped")
    assert_equal(left, ["[Entretien] Ancienne tâche"], "orphan is reported, not deleted")
    assert_equal(any(chore.get("name") == "Courses" for _k, _s, chore in actions if chore), False, "user chore untouched")

    existing[0]["frequency"] = 2
    existing[0]["description"] = "Note personnelle sans le marqueur."
    actions, _left = plan([micro], existing, DEFAULT_PREFIX)
    assert_equal(actions[0][0], "update", "frequency drift is an update")
    payload = update_payload(existing[0], micro)
    assert_equal(payload["frequency"], 1, "update restores frequency")
    assert_equal(payload["description"], "Note personnelle sans le marqueur.", "user description kept")
    assert_equal(payload["assignStrategy"], "least_completed", "assignment strategy kept")
    assert_equal(payload["assignees"], [{"userId": 9}], "assignees kept")
    assert_equal(payload["assignedTo"], 9, "assignedTo kept")
    assert_equal(payload["notification"], False, "notification preference kept")
    assert_equal(payload["points"], 5, "points kept")
    assert_equal("nextDueDate" in payload, False, "due date is not rewritten")
    assert_equal("labelsV2" in payload, False, "labels are not sent")

    archived = dict(existing[0])
    archived["isActive"] = False
    archived["frequency"] = 1
    archived["description"] = micro.description
    actions, _left = plan([micro], [archived], DEFAULT_PREFIX)
    assert_equal(actions[0][0], "archived", "inactive chore is not recreated")

    created = create_payload(micro, "2026-11-01T08:00:00Z")
    assert_equal(created["notification"], True, "new chores notify")
    assert_equal(created["assignStrategy"], "no_assignee", "new chores are unassigned")
    assert_equal(created["nextDueDate"], "2026-11-01T08:00:00Z", "first due date")

    duplicate = fixture.replace("- [ ] Micro-ondes", "- [ ] Micro-ondes\n- [ ] Micro-ondes", 1)
    try:
        parse_checklist(duplicate, DEFAULT_PREFIX)
    except SyncError as exc:
        assert_equal("duplicate" in str(exc), True, "duplicate names fail")
    else:
        raise AssertionError("duplicate names should fail")

    unknown = fixture.replace("### Chaque semaine", "### Tous les matins", 1)
    try:
        parse_checklist(unknown, DEFAULT_PREFIX)
    except SyncError as exc:
        assert_equal("unknown frequency section" in str(exc), True, "unknown section fails")
    else:
        raise AssertionError("unknown section should fail")

    winter = datetime(2026, 11, 1, 6, 0, tzinfo=timezone.utc)
    summer = datetime(2026, 7, 1, 6, 0, tzinfo=timezone.utc)
    assert_equal(europe_paris_offset(winter).utcoffset(winter), timedelta(hours=1), "CET offset")
    assert_equal(europe_paris_offset(summer).utcoffset(summer), timedelta(hours=2), "CEST offset")
    paris = resolve_timezone("Europe/Paris", winter)
    due = initial_due(winter, paris, 9)
    # 06:00 UTC is 07:00 in Paris (CET). The first due time is 09:00 local, 08:00 UTC.
    assert_equal(due, "2026-11-01T08:00:00Z", "due later the same morning")
    late = initial_due(datetime(2026, 11, 1, 10, 0, tzinfo=timezone.utc), paris, 9)
    assert_equal(late, "2026-11-02T08:00:00Z", "past 09:00 local rolls to the next day")
    summer_due = initial_due(summer, europe_paris_offset(summer), 9)
    assert_equal(summer_due, "2026-07-01T07:00:00Z", "summer due uses CEST")

    test_api_client()
    log("self-test ok")


def test_api_client() -> None:
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Handler(BaseHTTPRequestHandler):
        put_body: dict = {}

        def do_GET(self) -> None:  # noqa: N802
            if self.headers.get("secretkey") != "token":
                self.send_response(401)
                self.end_headers()
                return
            if not self.path.startswith("/api/v1/chores/"):
                self.send_response(404)
                self.end_headers()
                return
            body = json.dumps({
                "res": [{
                    "id": 3,
                    "name": "[Entretien] Micro-ondes",
                    "frequencyType": "monthly",
                    "frequency": 1,
                    "description": MARKER + "\nold",
                    "isActive": True,
                    "assignStrategy": "no_assignee",
                }]
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def do_PUT(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length", "0"))
            Handler.put_body = json.loads(self.rfile.read(length).decode("utf-8"))
            if self.path != "/api/v1/chores/":
                self.send_response(400)
                self.end_headers()
                return
            body = json.dumps({"message": "Chore updated successfully"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt: str, *args: Any) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = "http://127.0.0.1:{0}".format(server.server_address[1])
        chores = list_chores(base, "token")
        assert_equal(chores[0]["id"], 3, "list id")
        spec = ChoreSpec(
            "[Entretien] Micro-ondes",
            "Chaque semaine",
            "weekly",
            1,
            build_description("Chaque semaine", "weekly", 1, ""),
            "",
        )
        api_request(base, "token", "PUT", "/api/v1/chores/", update_payload(chores[0], spec))
        assert_equal(Handler.put_body["frequencyType"], "weekly", "put frequency")
        assert_equal(Handler.put_body["frequency"], 1, "put interval")
        try:
            api_request(base, "token", "GET", "/missing", None)
        except SyncError as exc:
            assert_equal("HTTP 404" in str(exc), True, "http error")
        else:
            raise AssertionError("404 should fail")
    finally:
        server.shutdown()
        server.server_close()


def main() -> int:
    if "--self-test" in sys.argv:
        run_self_test()
        return 0
    try:
        return run_sync()
    except SyncError as exc:
        log("error: {0}".format(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
