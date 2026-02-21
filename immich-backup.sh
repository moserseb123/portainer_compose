#!/usr/bin/env bash
set -euo pipefail

# Basis für das Backup ist https://docs.immich.app/guides/template-backup-script/

# =========
# LOCATE SCRIPT DIR & LOAD .env
# =========
resolve_dir() {
  local src="$0"
  while [ -h "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(resolve_dir)"

ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  # export everything defined in .env
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
else
  echo "[WARN] No .env found at: $ENV_FILE; proceeding with current env."
fi

# =========
# REQUIRED VARS FROM .env
# =========
: "${UPLOAD_LOCATION:?UPLOAD_LOCATION is required (path to Immich library)}}"
: "${BACKUP_PATH:?BACKUP_PATH is required (NAS backup root)}}"
: "${POSTGRES_CONTAINER:?POSTGRES_CONTAINER is required (Docker container name)}}"
: "${DB_USER:?DB_USER is required (Postgres user)}}"

# Optional: Healthchecks URL
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
# Container running the Immich server (used for maintenance mode)
IMMICH_CONTAINER="${IMMICH_CONTAINER:-immich_server}"

# =========
# HELPERS
# =========
ts() { date +"%Y-%m-%d %H:%M:%S"; }

# Track whether we successfully enabled maintenance mode so on_error can undo it
MAINT_MODE_ENABLED=0

enable_maintenance() {
  echo "$(ts) [INFO] Enabling Immich maintenance mode in container: $IMMICH_CONTAINER"
  if ! docker exec -t "$IMMICH_CONTAINER" immich-admin enable-maintenance-mode >/dev/null 2>&1; then
    echo "$(ts) [ERROR] Failed to enable maintenance mode in container $IMMICH_CONTAINER"
    return 1
  fi
  MAINT_MODE_ENABLED=1
  echo "$(ts) [INFO] Immich maintenance mode enabled"
}

disable_maintenance() {
  # Only attempt disable if we enabled it
  if [[ "${MAINT_MODE_ENABLED:-0}" -ne 1 ]]; then
    return 0
  fi
  echo "$(ts) [INFO] Disabling Immich maintenance mode in container: $IMMICH_CONTAINER"
  if ! docker exec -t "$IMMICH_CONTAINER" immich-admin disable-maintenance-mode >/dev/null 2>&1; then
    echo "$(ts) [WARN] Failed to disable maintenance mode in container $IMMICH_CONTAINER"
    return 1
  fi
  MAINT_MODE_ENABLED=0
  echo "$(ts) [INFO] Immich maintenance mode disabled"
}

cleanup_db_dump() {
  if [[ -n "${DB_DUMP_FILE:-}" && -f "$DB_DUMP_FILE" ]]; then
    echo "$(ts) [INFO] Removing temporary DB dump: $DB_DUMP_FILE"
    rm -f "$DB_DUMP_FILE" || echo "$(ts) [WARN] Failed to remove DB dump $DB_DUMP_FILE"
  fi
}

ping_hc() {
  # $1 = suffix ("", "/start", "/fail")
  # $2 = optional payload message
  local suffix="${1:-}"
  local msg="${2:-}"
  [[ -z "$HEALTHCHECK_URL" ]] && return 0
  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$msg" ]]; then
      curl -fsS -m 10 --retry 2 -H "Content-Type: text/plain" \
        -X POST --data "$msg" "${HEALTHCHECK_URL}${suffix}" >/dev/null || true
    else
      curl -fsS -m 10 --retry 2 "${HEALTHCHECK_URL}${suffix}" >/dev/null || true
    fi
  else
    echo "$(ts) [WARN] curl not found; skipping Healthchecks ping to ${HEALTHCHECK_URL}${suffix}"
  fi
}

on_error() {
  local ec=$?
  # Try to disable maintenance mode if we set it
  if [[ "${MAINT_MODE_ENABLED:-0}" -eq 1 ]]; then
    echo "$(ts) [WARN] Error occurred; attempting to disable Immich maintenance mode"
    disable_maintenance || echo "$(ts) [WARN] disable_maintenance failed"
  fi
  # Clean up DB dump on error
  cleanup_db_dump
  ping_hc "/fail" "Immich backup FAILED with exit code ${ec} at $(ts)"
  echo "$(ts) [ERROR] Backup failed (exit ${ec})"
  exit "$ec"
}
trap on_error ERR

echo "$(ts) [INFO] Starting Immich backup"
ping_hc "/start" "Immich backup started at $(ts)"

# =========
# PRE-FLIGHT CHECKS
# =========
if [[ ! -d "$BACKUP_PATH" ]]; then
  echo "$(ts) [ERROR] Backup path '$BACKUP_PATH' not found or not mounted"
  exit 1
fi

DB_DUMP_DIR="$UPLOAD_LOCATION/my-database-backup"
REPO="$BACKUP_PATH"

# Determine Immich version (try immich-admin, then container image tag)
IMMICH_VERSION=""
if docker exec -t "$IMMICH_CONTAINER" immich-admin --version >/dev/null 2>&1; then
  IMMICH_VERSION="$(docker exec -t "$IMMICH_CONTAINER" immich-admin --version 2>/dev/null | awk '{print $NF}')"
else
  image="$(docker inspect --format '{{.Config.Image}}' "$IMMICH_CONTAINER" 2>/dev/null || true)"
  if [[ -n "$image" && "$image" == *:* ]]; then
    IMMICH_VERSION="${image##*:}"
  fi
fi
IMMICH_VERSION="${IMMICH_VERSION#v}"
IMMICH_VER_OUT="${IMMICH_VERSION:+v${IMMICH_VERSION}}"

# Determine Postgres version (try postgres binary, then psql, then image tag)
PG_VERSION=""
if docker exec -t "$POSTGRES_CONTAINER" postgres --version >/dev/null 2>&1; then
  pg_full="$(docker exec -t "$POSTGRES_CONTAINER" postgres --version 2>/dev/null)"
  PG_VERSION="$(echo "$pg_full" | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
elif docker exec -t "$POSTGRES_CONTAINER" psql --version >/dev/null 2>&1; then
  pg_full="$(docker exec -t "$POSTGRES_CONTAINER" psql --version 2>/dev/null)"
  PG_VERSION="$(echo "$pg_full" | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
else
  pg_image="$(docker inspect --format '{{.Config.Image}}' "$POSTGRES_CONTAINER" 2>/dev/null || true)"
  if [[ -n "$pg_image" && "$pg_image" == *:* ]]; then
    tag="${pg_image##*:}"
    PG_VERSION="$(echo "$tag" | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
  fi
fi
PG_VER_OUT="${PG_VERSION:+pg${PG_VERSION}}"

# Build DB dump filename using schema: restore-point-immich-db-backup-vX.Y.Z-pgM.N.sql
DB_DUMP_FILE="$DB_DUMP_DIR/restore-point-immich-db-backup-${IMMICH_VER_OUT:-vUNKNOWN}-${PG_VER_OUT:-pgUNKNOWN}.sql"

# Tools
command -v docker >/dev/null 2>&1 || { echo "$(ts) [ERROR] docker not found in PATH"; exit 1; }
command -v borg   >/dev/null 2>&1 || { echo "$(ts) [ERROR] borg not found in PATH";   exit 1; }

# =========
# LOG CONTEXT
# =========
echo "$(ts) [INFO] Library path:  $UPLOAD_LOCATION"
echo "$(ts) [INFO] Backup root:   $BACKUP_PATH"
echo "$(ts) [INFO] Borg repo:     $REPO"
echo "$(ts) [INFO] Container:     $POSTGRES_CONTAINER"
echo "$(ts) [INFO] DB user:       $DB_USER"

# =========
# DATABASE DUMP
# =========
#
# Enable maintenance mode before dumping the DB
enable_maintenance

echo "$(ts) [INFO] Dumping Postgres from container '$POSTGRES_CONTAINER' to '$DB_DUMP_FILE'"
docker exec -t "$POSTGRES_CONTAINER" \
  pg_dump --username="$DB_USER" --no-owner --no-privileges immich > "$DB_DUMP_FILE"

# NOTE: Avoid gzip for better dedup with Borg. If you prefer compression:
# docker exec -t "$POSTGRES_CONTAINER" pg_dumpall --clean --if-exists --username="$DB_USER" \
#   | gzip --rsyncable > "${DB_DUMP_FILE}.gz"

# =========
# BORG BACKUP
# =========
echo "$(ts) [INFO] Creating Borg archive"
ARCHIVE_NAME="$(date +"backup.%Y-%m-%d %H:%M:%S")"
borg create \
  --stats \
  "$REPO::${ARCHIVE_NAME}" \
  "$UPLOAD_LOCATION" \
  --exclude "$UPLOAD_LOCATION/thumbs" \
  --exclude "$UPLOAD_LOCATION/encoded-video"

echo "$(ts) [INFO] Pruning old archives (keep weekly=4, monthly=3)"
borg prune \
  --keep-daily=7 \
  --keep-weekly=4 \
  "$REPO"

echo "$(ts) [INFO] Compacting repository"
borg compact "$REPO"

# On success: remove temporary DB dump and disable maintenance mode
cleanup_db_dump
disable_maintenance || echo "$(ts) [WARN] disable_maintenance failed on success path"

echo "$(ts) [INFO] Immich backup completed successfully"
ping_hc "" "Immich backup OK at $(ts)"
