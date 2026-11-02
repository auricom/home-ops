#!/usr/bin/env bash
# Logical dump/restore helper for the CNPG migration.
# Read docs/cnpg-migration.md before running this. It does not scale apps,
# delete objects, drop databases, or touch PVCs.
#
# Run it from a pod whose client major matches the server (PostgreSQL 18),
# or any host that has pg_dump, pg_restore, and psql on PATH.
#
# Required environment (never pass passwords on the command line):
#   SOURCE_HOST SOURCE_USER SOURCE_DB SOURCE_PASSWORD
#   TARGET_HOST TARGET_USER TARGET_DB TARGET_PASSWORD   # dump is source-only
# Optional:
#   SOURCE_PORT TARGET_PORT   default 5432
#   DUMP_DIR                  default ./cnpg-dumps (must not be the source PVC)
#   DUMP_FILE                 reuse one archive; dump skips a non-empty file
#   FORCE_DUMP=1              overwrite DUMP_FILE
set -euo pipefail

LIVE_SERVICES=(
  immich-database.default.svc.cluster.local
  silo-database.default.svc.cluster.local
  bookorbit-database.default.svc.cluster.local
)

usage() {
  cat <<'EOF'
Usage: logical-copy.sh dump|restore|inventory

  dump       pg_dump -Fc from SOURCE_* into DUMP_DIR. Read-only on the source.
  restore    pg_restore that archive into an empty TARGET_* database.
             Refuses a target that is one of the live StatefulSet services.
             Refuses a target that already has user tables.
             Extensions are left to the CloudNativePG Database CR: their TOC
             entries are commented out before restore.
  inventory  Print version, size, extensions, and exact table counts for
             SOURCE_*. Read-only. Diff this output before and after restore.

A dump taken while the app is still writing is a rehearsal archive.
The cutover archive is the one taken after writers are stopped.
EOF
}

die() {
  printf 'logical-copy: %s\n' "$*" >&2
  exit 2
}

need() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "set ${name}"
  fi
}

normalize_host() {
  local host="$1"
  host="${host%.}"
  printf '%s' "$host"
}

require_bin() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "missing ${bin} on PATH (use the PostgreSQL 18 client)"
  done
}

reject_same_host() {
  local source_host target_host
  source_host="$(normalize_host "$SOURCE_HOST")"
  target_host="$(normalize_host "$TARGET_HOST")"
  if [[ "$source_host" == "$target_host" && "${SOURCE_PORT:-5432}" == "${TARGET_PORT:-5432}" ]]; then
    die "SOURCE_HOST and TARGET_HOST are the same (${source_host}). Refusing."
  fi
}

reject_live_target() {
  local target_host="$1"
  local live
  for live in "${LIVE_SERVICES[@]}"; do
    if [[ "$target_host" == "$live" ]]; then
      die "refusing to restore into live StatefulSet service ${target_host}"
    fi
  done
}

psql_of() {
  local prefix="$1"
  local host_var="${prefix}_HOST"
  local port_var="${prefix}_PORT"
  local user_var="${prefix}_USER"
  local db_var="${prefix}_DB"
  local pass_var="${prefix}_PASSWORD"
  need "$host_var"
  need "$user_var"
  need "$db_var"
  need "$pass_var"
  PGPASSWORD="${!pass_var}" \
    PGHOST="$(normalize_host "${!host_var}")" \
    PGPORT="${!port_var:-5432}" \
    PGUSER="${!user_var}" \
    PGDATABASE="${!db_var}" \
    psql -v ON_ERROR_STOP=1 -X "$@"
}

dump_path() {
  if [[ -n "${DUMP_FILE:-}" ]]; then
    printf '%s' "$DUMP_FILE"
    return
  fi
  local dir="${DUMP_DIR:-./cnpg-dumps}"
  mkdir -p "$dir"
  printf '%s/%s-%s.dump' "$dir" "$(normalize_host "$SOURCE_HOST")" "$(date -u +%Y%m%dT%H%M%SZ)"
}

cmd_inventory() {
  require_bin psql
  need SOURCE_HOST
  need SOURCE_USER
  need SOURCE_DB
  need SOURCE_PASSWORD
  printf 'host=%s db=%s\n' "$(normalize_host "$SOURCE_HOST")" "$SOURCE_DB"
  psql_of SOURCE -c 'SELECT version();'
  psql_of SOURCE -c 'SELECT pg_database_size(current_database()) AS bytes;'
  psql_of SOURCE -c '\dx'
  psql_of SOURCE <<'SQL'
SELECT n.nspname AS schema,
       c.relname AS table,
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text AS rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2;
SQL
}

cmd_dump() {
  require_bin pg_dump pg_restore
  need SOURCE_HOST
  need SOURCE_USER
  need SOURCE_DB
  need SOURCE_PASSWORD
  local out
  out="$(dump_path)"
  if [[ -s "$out" && "${FORCE_DUMP:-0}" != "1" ]]; then
    printf 'logical-copy: dump already present, skipping (%s)\n' "$out"
    printf '%s\n' "$out"
    return
  fi
  printf 'logical-copy: dumping %s/%s (writers still running means this is a rehearsal)\n' \
    "$(normalize_host "$SOURCE_HOST")" "$SOURCE_DB" >&2
  PGPASSWORD="$SOURCE_PASSWORD" \
    pg_dump \
      --host="$(normalize_host "$SOURCE_HOST")" \
      --port="${SOURCE_PORT:-5432}" \
      --username="$SOURCE_USER" \
      --dbname="$SOURCE_DB" \
      --format=custom \
      --no-owner \
      --no-privileges \
      --verbose \
      --file="$out"
  [[ -s "$out" ]] || die "dump file is empty: ${out}"
  pg_restore --list "$out" >/dev/null
  printf '%s\n' "$out"
}

filter_extension_toc() {
  local archive="$1"
  local toc="$2"
  pg_restore --list "$archive" >"$toc"
  local tmp
  tmp="$(mktemp)"
  awk '
    $0 ~ / EXTENSION / && $0 !~ /^;/ { print ";" $0; next }
    { print }
  ' "$toc" >"$tmp"
  mv "$tmp" "$toc"
}

target_table_count() {
  # Extension objects (deptype e) are created by the Database CR before restore
  # and are not a reason to refuse. Any other user table means a previous load.
  psql_of TARGET -At <<'SQL'
SELECT count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND NOT EXISTS (
    SELECT 1 FROM pg_depend d
    WHERE d.objid = c.oid AND d.deptype = 'e'
  );
SQL
}

cmd_restore() {
  need SOURCE_HOST
  need TARGET_HOST
  need TARGET_USER
  need TARGET_DB
  need TARGET_PASSWORD
  need DUMP_FILE
  reject_same_host
  local target_host
  target_host="$(normalize_host "$TARGET_HOST")"
  reject_live_target "$target_host"
  [[ -s "$DUMP_FILE" ]] || die "DUMP_FILE is missing or empty: ${DUMP_FILE}"
  require_bin pg_restore psql

  local tables
  tables="$(target_table_count | tr -d '[:space:]')"
  if [[ "$tables" != "0" ]]; then
    die "target ${target_host}/${TARGET_DB} already has ${tables} user tables. Refusing to load on top of them. Delete the new CloudNativePG Cluster (its own PVCs only) and recreate it empty."
  fi

  local toc status
  toc="$(mktemp)"
  filter_extension_toc "$DUMP_FILE" "$toc"
  printf 'logical-copy: restoring into %s/%s\n' "$target_host" "$TARGET_DB" >&2
  set +e
  PGPASSWORD="$TARGET_PASSWORD" \
    pg_restore \
      --host="$target_host" \
      --port="${TARGET_PORT:-5432}" \
      --username="$TARGET_USER" \
      --dbname="$TARGET_DB" \
      --no-owner \
      --no-privileges \
      --exit-on-error \
      --verbose \
      --use-list="$toc" \
      "$DUMP_FILE"
  status=$?
  set -e
  rm -f "$toc"
  [[ "$status" -eq 0 ]] || exit "$status"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    dump) cmd_dump ;;
    restore) cmd_restore ;;
    inventory) cmd_inventory ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
