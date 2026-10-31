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

import calendar
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
PLANNING_VERSION = "Planning entretien : v2."
DEFAULT_PREFIX = "[Entretien] "
DEFAULT_SOURCE_URL = (
    "https://raw.githubusercontent.com/auricom/docs/main/content/docs/maison/entretien.md"
)
DEFAULT_BASE_URL = "http://donetick.default.svc.cluster.local:2021"
USER_AGENT = "donetick-entretien-sync"

# (frequencyType, frequency, item text may override the year count)
# Multi-year sections use the lower bound when the checklist gives a range.
# Converted to interval schedules below: simple monthly/yearly ignore frequency.
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

# Explicit rules for the frequency checklist, following the seasonal calendar.
# Update these when the document's seasonal guidance changes. No prose inference.
CALENDAR_MONTHS = {
    "Gouttières (printemps + fin d'automne)": (4, 11),
    "Taille de la haie de laurier (juin + septembre)": (6, 9),
    "Traitements des fruitiers (automne + fin d'hiver)": (2, 11),
    "Purge des radiateurs (septembre–octobre)": (9,),
    "PAC : dégager l'unité extérieure, filtres selon la notice": (9, 11),
    "Station de relevage (fonctionnement, alarme si présente, entretien notice ou pro)": (10,),
    "Nettoyage PV si encrassé": (4,),
    "Portail et porte de garage motorisés": (3,),
    "Alarme / caméras (batteries et capteurs)": (12,),
    "Terrasse carrelage / dalles (nettoyage, anti-mousse)": (4,),
    "Terrasse bois : nettoyage + saturateur": (4,),
    "Mise hors gel des robinets extérieurs": (11,),
}
SEASON_MONTHS = {
    "Piscine (en saison) : skimmers, préfiltre, analyses, robot": (5, 6, 7, 8, 9),
    "Piscine : TAC et ligne d'eau (en saison)": (5, 6, 7, 8, 9),
    "Jardin (en saison) : tonte, fleurs fanées des rosiers": (4, 5, 6, 7, 8, 9, 10),
    "PAC : vérifier la production (saison de chauffe)": (1, 2, 3, 4, 10, 11, 12),
}
SPLITS = {
    "Inspection toiture ; combles depuis la trappe": (
        ("Inspection toiture après l'hiver", (3,)),
        ("Inspection des combles depuis la trappe", (12,)),
    ),
    "Inspection toiture et combles": (
        ("Inspection toiture après l'hiver", (3,)),
        ("Inspection des combles depuis la trappe", (12,)),
    ),
    "Remise en route + hivernage piscine": (
        ("Remise en route piscine", (4,)),
        ("Hivernage piscine", (10,)),
    ),
    "Taille des rosiers, fruitiers, arbustes, élagage des arbres": (
        ("Élagage des arbres (hors gel)", (1,)),
        ("Taille des fruitiers (hors gel)", (2,)),
        ("Taille en vert des fruitiers", (7,)),
        ("Taille des rosiers", (3,)),
        ("Taille des arbustes à floraison estivale", (3,)),
        ("Taille des arbustes à floraison printanière", (5,)),
    ),
}


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
        self.unit = {"weekly": "weeks", "monthly": "months", "yearly": "years"}[frequency_type]
        self.months: Tuple[int, ...] = ()
        self.season: Tuple[int, ...] = ()
        self.source_name = name
        self.first_split_name = name
        self.reuse_source = False
        self.timezone = os.environ.get("DUE_TIMEZONE", "Europe/Paris")
        try:
            self.hour = int(os.environ.get("DUE_HOUR", "9"))
        except ValueError as exc:
            raise SyncError("DUE_HOUR must be an integer from 0 to 23") from exc
        if not 0 <= self.hour <= 23:
            raise SyncError("DUE_HOUR must be an integer from 0 to 23")


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
            "Donetick n'a pas d'intervalle variable : interval / {0} years (borne basse)."
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
                    "Donetick : interval / {1} years (borne basse de la section)."
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
    return schedule_specs(specs, prefix)


def schedule_specs(specs: List[ChoreSpec], prefix: str) -> List[ChoreSpec]:
    scheduled = []
    names = set()
    for original in specs:
        label = original.name[len(prefix):]
        replacements = SPLITS.get(label, ((label, CALENDAR_MONTHS.get(label, ())),))
        for index, (replacement, months) in enumerate(replacements):
            spec = ChoreSpec(
                prefix + replacement, original.section, original.frequency_type,
                original.frequency, original.description, original.cadence_note,
            )
            spec.source_name = original.name
            spec.first_split_name = prefix + replacements[0][0]
            spec.reuse_source = label in SPLITS and index == 0
            spec.season = SEASON_MONTHS.get(label, ())
            if ("en saison" in label or "saison de chauffe" in label) and not spec.season:
                raise SyncError("seasonal checklist item needs an explicit rule: " + label)
            if label.startswith(("Démoussage de la toiture", "Média filtrant piscine")):
                months = (4,)
            spec.months = months
            if spec.season and spec.unit == "months":
                spec.months = spec.season
            spec.frequency_type = "interval"
            if spec.months and not (spec.unit == "years" and spec.frequency > 1):
                spec.frequency_type = "day_of_the_month"
                spec.frequency = 15
            note = "Source checklist : {0}.\nUnité : {1}.".format(label, spec.unit)
            if spec.months:
                note += "\nMois planifiés : {0}, le 15.".format(", ".join(map(str, spec.months)))
            if spec.season:
                note += "\nMois de saison : {0}.".format(", ".join(map(str, spec.season)))
            note += "\nHoraire : {0}:00 {1}.".format(spec.hour, spec.timezone)
            spec.description = build_description(
                spec.section, spec.frequency_type, spec.frequency, spec.cadence_note,
            ) + "\n" + note + "\n" + PLANNING_VERSION
            if spec.name in names:
                raise SyncError("duplicate planned chore: " + spec.name)
            names.add(spec.name)
            scheduled.append(spec)
    return scheduled


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


def local_date(spec: ChoreSpec, year: int, month: int, day: int) -> datetime:
    # Resolve the offset at the target date, including when tzdata is absent.
    probe = datetime(year, month, day, 12, tzinfo=timezone.utc)
    return datetime(year, month, day, spec.hour, tzinfo=resolve_timezone(spec.timezone, probe))


def format_due(due: datetime) -> str:
    return due.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_due(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("missing timezone")
        return parsed
    except (TypeError, ValueError) as exc:
        raise SyncError("invalid nextDueDate: {0!r}".format(value)) from exc


def next_calendar_date(spec: ChoreSpec, base: datetime, allow_overdue: bool) -> datetime:
    for year in (base.year, base.year + 1):
        for month in spec.months:
            if (year, month) < (base.year, base.month):
                continue
            due = local_date(spec, year, month, 15)
            if allow_overdue or due >= base:
                return due
    raise SyncError("no calendar date for " + spec.name)


def initial_due(spec: ChoreSpec, now: datetime) -> str:
    local_now = now.astimezone(resolve_timezone(spec.timezone, now))
    if spec.frequency_type == "day_of_the_month":
        due = next_calendar_date(spec, local_now, allow_overdue=True)
    elif spec.unit == "weeks":
        target = local_now + timedelta(weeks=spec.frequency)
        due = local_date(spec, target.year, target.month, target.day)
    else:
        months = spec.frequency * (12 if spec.unit == "years" else 1)
        year, month0 = divmod(local_now.year * 12 + local_now.month - 1 + months, 12)
        day = min(local_now.day, calendar.monthrange(year, month0 + 1)[1])
        due = local_date(spec, year, month0 + 1, day)
        if spec.months:
            due = next_calendar_date(spec, due, allow_overdue=False)
    return seasonal_due(spec, format_due(due), now)


def seasonal_due(spec: ChoreSpec, value: str, now: datetime) -> str:
    if not spec.season:
        return value
    due = parse_due(value)
    local_due = due.astimezone(resolve_timezone(spec.timezone, due))
    local_now = now.astimezone(resolve_timezone(spec.timezone, now))
    # Keep valid overdue work in season, but move winter backlog to next season.
    if local_due.month in spec.season and (due >= now or local_now.month in spec.season):
        return value
    base = max(now, due).astimezone(resolve_timezone(spec.timezone, max(now, due)))
    for offset in range(13):
        year, month0 = divmod(base.year * 12 + base.month - 1 + offset, 12)
        if month0 + 1 in spec.season:
            day = 15 if spec.frequency_type == "day_of_the_month" else 1
            candidate = local_date(spec, year, month0 + 1, day)
            if candidate >= base:
                return format_due(candidate)
    raise SyncError("no seasonal date for " + spec.name)


def frequency_metadata(spec: ChoreSpec) -> dict:
    metadata = {
        "timezone": spec.timezone,
        "time": local_date(spec, 2000, 1, 15).isoformat(),
    }
    if spec.frequency_type == "day_of_the_month":
        metadata["months"] = [calendar.month_name[month].lower() for month in spec.months]
    else:
        metadata["unit"] = spec.unit
    return metadata


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
        "frequencyMetadata": frequency_metadata(spec),
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


def schedule_changed(chore: dict, spec: ChoreSpec) -> bool:
    metadata = {
        key: value for key, value in (chore.get("frequencyMetadata") or {}).items()
        if value not in (None, "", [])
    }
    return (
        chore.get("frequencyType") != spec.frequency_type
        or int(chore.get("frequency") or 0) != spec.frequency
        or metadata != frequency_metadata(spec)
        or bool(chore.get("isRolling"))
    )


def repaired_due(chore: dict, spec: ChoreSpec, now: datetime) -> str:
    if PLANNING_VERSION not in (chore.get("description") or "") or schedule_changed(chore, spec):
        return initial_due(spec, now)
    value = chore.get("nextDueDate")
    if not value:
        return initial_due(spec, now)
    return seasonal_due(spec, value, now)


def needs_update(chore: dict, spec: ChoreSpec, now: datetime) -> bool:
    return (
        schedule_changed(chore, spec)
        or chore.get("name") != spec.name
        or (chore.get("description") or "") != spec.description
        or repaired_due(chore, spec, now) != chore.get("nextDueDate")
    )


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


def update_payload(chore: dict, spec: ChoreSpec, now: datetime) -> dict:
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
        "frequencyMetadata": frequency_metadata(spec),
        "nextDueDate": repaired_due(chore, spec, now),
        "assignStrategy": chore.get("assignStrategy") or "no_assignee",
        "assignees": assignees,
        "isRolling": False,
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
    trigger = thing_trigger(chore)
    if trigger is not None:
        payload["thingTrigger"] = trigger
    return payload


def active_chores(group: List[dict]) -> List[dict]:
    return [chore for chore in group if chore.get("isActive", True)]


def plan(specs: List[ChoreSpec], chores: List[dict], prefix: str, now: datetime) -> Tuple[list, List[str]]:
    grouped: Dict[str, List[dict]] = {}
    for chore in chores:
        name = chore.get("name") or ""
        grouped.setdefault(name, []).append(chore)

    for name, group in grouped.items():
        if name.startswith(prefix) and len(active_chores(group)) > 1:
            raise SyncError("multiple active chores are named {0!r}".format(name))
    actions = []
    matched = set()
    for spec in specs:
        matched.add(spec.name)
        matched.add(spec.source_name)
        group = grouped.get(spec.name, [])
        source_group = grouped.get(spec.source_name, [])
        if not source_group and spec.source_name != spec.name:
            source_group = grouped.get(spec.first_split_name, [])
        source = (active_chores(source_group) or source_group or [None])[0]
        if not group and spec.reuse_source and source and source.get("name") == spec.source_name:
            group = [source]
        active = active_chores(group)
        if active:
            current = active[0]
            kind = "update" if managed_description(current) and needs_update(current, spec, now) else "skip"
            actions.append((kind, spec, current))
            continue
        if group:
            actions.append(("archived", spec, group[0]))
            continue
        if source and not source.get("isActive", True):
            actions.append(("archived", spec, source))
        elif source and not managed_description(source):
            actions.append(("skip", spec, source))
        else:
            actions.append(("create", spec, source))

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
    now: datetime,
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
            due = initial_due(spec, now)
            payload = create_payload(spec, due)
            if chore:
                payload = update_payload(chore, spec, now)
                payload.pop("id")
                payload["nextDueDate"] = due
                payload["description"] = spec.description
                # Thing triggers stay on the original ID rather than firing siblings.
                payload.pop("thingTrigger", None)
            detail += " nextDueDate={0}".format(payload["nextDueDate"])
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
            payload = update_payload(chore, spec, now)
            detail += " nextDueDate={0} -> {1}".format(chore.get("nextDueDate"), payload["nextDueDate"])
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
    now = datetime.now(timezone.utc)
    if "--print" in sys.argv:
        for spec in specs:
            log("{0}/{1}\t{2}\t{3}\tnextDueDate={4}".format(
                spec.frequency_type, spec.frequency, spec.name,
                json.dumps(frequency_metadata(spec), ensure_ascii=False), initial_due(spec, now),
            ))
        return 0

    token = os.environ.get("DONETICK_DOCS_API_TOKEN", "").strip()
    if not token:
        raise SyncError("DONETICK_DOCS_API_TOKEN is empty")
    base_url = os.environ.get("DONETICK_BASE_URL", DEFAULT_BASE_URL).strip()
    if not base_url:
        raise SyncError("DONETICK_BASE_URL is empty")

    chores = list_chores(base_url, token)
    log("listed {0} existing chores".format(len(chores)))
    actions, left = plan(specs, chores, prefix, now)
    counts = apply_actions(actions, base_url, token, now, dry_run)
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
    assert_equal("Filtre à peluches et bac du sèche-linge" in by_label, False, "per-use skipped")
    now = datetime(2026, 10, 31, 12, tzinfo=timezone.utc)
    micro = by_label["Micro-ondes"]
    gutter = by_label["Gouttières (printemps + fin d'automne)"]
    assert_equal(initial_due(gutter, now), "2026-11-15T08:00:00Z", "gutters in November")
    assert_equal(initial_due(gutter, datetime(2026, 12, 1, tzinfo=timezone.utc)),
                 "2027-04-15T07:00:00Z", "gutters next April with DST")
    assert_equal(initial_due(gutter, datetime(2026, 11, 20, tzinfo=timezone.utc)),
                 "2026-11-15T08:00:00Z", "current month overdue remains actionable")
    assert_equal(frequency_metadata(gutter)["months"], ["april", "november"], "unequal month gaps")
    for label, unit, frequency in [
        ("Micro-ondes", "weeks", 1),
        ("Tester les détecteurs de fumée", "months", 1),
        ("Bouches de VMC", "months", 3),
        ("Entretien professionnel de la pompe à chaleur (obligatoire, 2 ans)", "years", 2),
        ("Démoussage de la toiture (3–5 ans)", "years", 3),
        ("Contrôle par un couvreur (5 ans)", "years", 5),
        ("Remplacer les détecteurs de fumée", "years", 10),
        ("Remplacement de l'onduleur photovoltaïque (~10–15 ans)", "years", 10),
    ]:
        spec = by_label[label]
        assert_equal((spec.frequency_type, spec.frequency, frequency_metadata(spec)["unit"]),
                     ("interval", frequency, unit), "interval " + label)
    assert_equal(initial_due(micro, now), "2026-11-07T08:00:00Z", "weekly baseline")
    assert_equal(initial_due(by_label["Tester les détecteurs de fumée"],
                             datetime(2028, 1, 31, tzinfo=timezone.utc)),
                 "2028-02-29T08:00:00Z", "month-end clamping in leap year")
    assert_equal(initial_due(by_label["Démoussage de la toiture (3–5 ans)"], now),
                 "2030-04-15T07:00:00Z", "multi-year work retains interval and spring anchor")

    extra = """
## Récapitulatif par fréquence
### Chaque semaine
- [ ] Piscine (en saison) : skimmers, préfiltre, analyses, robot
- [ ] Jardin (en saison) : tonte, fleurs fanées des rosiers
### Chaque mois
- [ ] Piscine : TAC et ligne d'eau (en saison)
- [ ] PAC : vérifier la production (saison de chauffe)
### Chaque semestre
- [ ] Taille de la haie de laurier (juin + septembre)
- [ ] Entrées d'air et moteur VMC
### Chaque année
- [ ] Remise en route + hivernage piscine
- [ ] Inspection toiture ; combles depuis la trappe
- [ ] Taille des rosiers, fruitiers, arbustes, élagage des arbres
"""
    extras = parse_checklist(extra, DEFAULT_PREFIX)
    pool = extras[0]
    assert_equal(initial_due(pool, now), "2027-05-01T07:00:00Z", "pool waits for May")
    assert_equal(initial_due(extras[1], now), "2027-04-01T07:00:00Z", "garden waits for April")
    assert_equal(frequency_metadata(extras[3])["months"],
                 ["january", "february", "march", "april", "october", "november", "december"],
                 "heating season spans year end")
    assert_equal(extras[4].months, (6, 9), "hedge June and September")
    assert_equal((extras[5].frequency, extras[5].unit), (6, "months"), "six-month interval")
    assert_equal(seasonal_due(pool, "2026-10-05T07:00:00Z", now),
                 "2027-05-01T07:00:00Z", "out-of-season completion corrected")
    assert_equal(seasonal_due(pool, "2026-08-01T07:00:00Z",
                              datetime(2026, 8, 20, tzinfo=timezone.utc)),
                 "2026-08-01T07:00:00Z", "in-season overdue work kept")
    assert_equal(seasonal_due(pool, "2026-08-01T07:00:00Z", now),
                 "2027-05-01T07:00:00Z", "summer backlog cleared in winter")
    assert_equal(seasonal_due(pool, "2027-05-01T07:00:00Z", now),
                 "2027-05-01T07:00:00Z", "valid future season kept")
    out_of_season = dict(create_payload(pool, "2026-10-05T07:00:00Z"), id=15)
    assert_equal(plan([pool], [out_of_season], DEFAULT_PREFIX, now)[0][0][0],
                 "update", "daily job detects out-of-season recurrence")
    corrected = update_payload(out_of_season, pool, now)
    assert_equal(corrected["nextDueDate"], "2027-05-01T07:00:00Z", "daily job repairs date")
    assert_equal(needs_update(corrected, pool, now), False, "daily repair is stable")

    current = create_payload(micro, initial_due(micro, now))
    current.update({"id": 4, "assignStrategy": "least_completed", "assignees": [{"userId": 9}],
                    "assignedTo": 9, "notification": False, "priority": 2, "points": 5,
                    "projectId": 7, "completionWindow": 12, "isPrivate": True})
    actions, left = plan([micro], [current, {"id": 9, "name": "Courses"},
                         {"id": 8, "name": DEFAULT_PREFIX + "Ancienne tâche"}], DEFAULT_PREFIX, now)
    assert_equal(actions[0][0], "skip", "second run does nothing")
    assert_equal(left, [DEFAULT_PREFIX + "Ancienne tâche"], "orphan reported")
    legacy = dict(current, frequencyType="weekly", frequencyMetadata=None,
                  description=MARKER + "\nold", nextDueDate="2026-11-01T08:00:00Z")
    payload = update_payload(legacy, micro, now)
    assert_equal(payload["nextDueDate"], "2026-11-07T08:00:00Z", "legacy date repaired")
    for key in ["assignStrategy", "assignees", "assignedTo", "notification", "priority",
                "points", "projectId", "completionWindow", "isPrivate"]:
        assert_equal(payload[key], current[key], "preserve " + key)
    assert_equal("labelsV2" in payload, False, "labels not overwritten")
    migrated = dict(legacy, **payload)
    migrated["nextDueDate"] = "2026-10-01T07:00:00Z"
    assert_equal(needs_update(migrated, micro, now), False, "completion progress and overdue kept")
    edited = dict(migrated, description=micro.description + "\\nOld generated wording")
    assert_equal(update_payload(edited, micro, now)["nextDueDate"], migrated["nextDueDate"],
                 "description-only update preserves date")
    migrated["frequencyMetadata"].update({"days": None, "months": None, "weekPattern": None})
    assert_equal(needs_update(migrated, micro, now), False, "API empty metadata fields ignored")
    archived = dict(legacy, isActive=False)
    assert_equal(plan([micro], [archived], DEFAULT_PREFIX, now)[0][0][0], "archived", "archive kept")
    personal = dict(legacy, description="My personal notes")
    assert_equal(plan([micro], [personal], DEFAULT_PREFIX, now)[0][0][0], "skip", "unmarked untouched")

    split_specs = [spec for spec in extras if "piscine" in spec.name and spec.source_name != spec.name]
    assert_equal(len(split_specs), 2, "pool split into two")
    original = dict(legacy, name=split_specs[0].source_name)
    actions, _ = plan(split_specs, [original], DEFAULT_PREFIX, now)
    assert_equal([action[0] for action in actions], ["update", "create"], "reuse original ID")
    first = dict(original, **update_payload(original, split_specs[0], now))
    retry, _ = plan(split_specs, [first], DEFAULT_PREFIX, now)
    assert_equal([action[0] for action in retry], ["skip", "create"], "partial migration retry")
    assert_equal(retry[1][2]["points"], 5, "retry inherits settings from renamed original")
    inactive = dict(original, isActive=False)
    assert_equal([a[0] for a in plan(split_specs, [inactive], DEFAULT_PREFIX, now)[0]],
                 ["archived", "archived"], "archived original suppresses siblings")

    for broken, message in [
        (fixture.replace("- [ ] Micro-ondes", "- [ ] Micro-ondes\n- [ ] Micro-ondes"), "duplicate"),
        (fixture.replace("### Chaque semaine", "### Tous les matins"), "unknown frequency section"),
        (fixture.replace("Micro-ondes", "Nouvelle tâche (en saison)"), "explicit rule"),
    ]:
        try:
            parse_checklist(broken, DEFAULT_PREFIX)
        except SyncError as exc:
            assert_equal(message in str(exc), True, "parser rejects " + message)
        else:
            raise AssertionError("parser should reject " + message)
    try:
        plan([micro], [current, dict(current, id=5)], DEFAULT_PREFIX, now)
    except SyncError:
        pass
    else:
        raise AssertionError("duplicate active names should fail")

    # The fallback must resolve the target season's offset, not today's offset.
    global ZoneInfo
    saved_zoneinfo = ZoneInfo
    ZoneInfo = None
    try:
        assert_equal(initial_due(gutter, datetime(2026, 12, 1, tzinfo=timezone.utc)),
                     "2027-04-15T07:00:00Z", "DST fallback resolves future offset")
        for stamp, hours in [("2026-03-29T00:59:00Z", 1), ("2026-03-29T01:00:00Z", 2),
                             ("2026-10-25T00:59:00Z", 2), ("2026-10-25T01:00:00Z", 1)]:
            instant = parse_due(stamp)
            assert_equal(europe_paris_offset(instant).utcoffset(instant), timedelta(hours=hours),
                         "EU DST boundary " + stamp)
    finally:
        ZoneInfo = saved_zoneinfo
    test_api_client()
    log("self-test ok")


def test_api_client() -> None:
    import copy
    import threading
    from contextlib import redirect_stdout
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from io import StringIO

    now = datetime(2026, 10, 31, 12, tzinfo=timezone.utc)
    specs = parse_checklist("""
## Récapitulatif par fréquence
### Chaque année
- [ ] Remise en route + hivernage piscine
""", DEFAULT_PREFIX)
    original = {
        "id": 3, "name": specs[0].source_name, "frequencyType": "yearly", "frequency": 1,
        "description": MARKER + " old", "isActive": True, "assignStrategy": "no_assignee",
        "nextDueDate": "2026-11-01T08:00:00Z", "notification": False, "points": 5,
    }

    class Handler(BaseHTTPRequestHandler):
        chores = [copy.deepcopy(original)]
        writes: list = []
        fail_create = False

        def do_GET(self) -> None:  # noqa: N802
            if self.headers.get("secretkey") != "token":
                self.send_response(401)
                self.end_headers()
                return
            if not self.path.startswith("/api/v1/chores/"):
                self.send_response(404)
                self.end_headers()
                return
            self.reply({"res": self.chores})

        def reply(self, body: dict) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(body).encode("utf-8"))

        def do_POST(self) -> None:  # noqa: N802
            if self.fail_create:
                self.send_response(503)
                self.end_headers()
                return
            self.write_chore(create=True)

        def do_PUT(self) -> None:  # noqa: N802
            self.write_chore(create=False)

        def write_chore(self, create: bool) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            self.writes.append(payload)
            if create:
                payload["id"] = 4
                self.chores.append(payload)
            else:
                self.chores[0].update(payload)
            self.reply({"res": payload["id"]})

        def log_message(self, fmt: str, *args: Any) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = "http://127.0.0.1:{0}".format(server.server_address[1])
        chores = list_chores(base, "token")
        actions, _ = plan(specs, chores, DEFAULT_PREFIX, now)
        captured = StringIO()
        with redirect_stdout(captured):
            counts = apply_actions(actions, base, "token", now, dry_run=True)
        assert_equal(len(Handler.writes), 0, "dry-run makes no writes")
        assert_equal(counts["updated"], 1, "dry-run reports migration")
        assert_equal("2026-11-01T08:00:00Z -> 2027-04-15T07:00:00Z" in captured.getvalue(),
                     True, "dry-run shows old and new dates")
        Handler.fail_create = True
        counts = apply_actions(actions, base, "token", now, dry_run=False)
        assert_equal(counts["errors"], 1, "partial create failure reported")
        Handler.fail_create = False
        retry, _ = plan(specs, list_chores(base, "token"), DEFAULT_PREFIX, now)
        counts = apply_actions(retry, base, "token", now, dry_run=False)
        assert_equal((counts["created"], counts["updated"]), (1, 0), "retry only creates missing sibling")
        chores = list_chores(base, "token")
        assert_equal(chores[0]["id"], 3, "original ID retained")
        assert_equal(chores[1]["points"], 5, "sibling inherits settings")
        assert_equal(chores[0]["nextDueDate"], "2027-04-15T07:00:00Z", "pool opens in April")
        assert_equal(chores[1]["nextDueDate"], "2026-10-15T07:00:00Z", "winterizing overdue this month")
        assert_equal([a[0] for a in plan(specs, chores, DEFAULT_PREFIX, now)[0]],
                     ["skip", "skip"], "second successful run is idempotent")
        for token, path, expected in [("token", "/missing", "HTTP 404"),
                                      ("wrong", "/api/v1/chores/", "HTTP 401")]:
            try:
                api_request(base, token, "GET", path)
            except SyncError as exc:
                assert_equal(expected in str(exc), True, "HTTP failure reported")
            else:
                raise AssertionError("HTTP failure should fail")
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
