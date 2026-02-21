#!/usr/bin/env bash
set -euo pipefail

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
: "${DB_DATA_DIR:?DB_DATA_DIR is required (reference path to DB data/config)}}"
: "${BACKUP_PATH:?BACKUP_PATH is required (NAS backup root)}}"
: "${POSTGRES_CONTAINER:?POSTGRES_CONTAINER is required (Docker container name)}}"
: "${DB_USER:?DB_USER is required (Postgres user)}}"

# Optional: Healthchecks URL
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

# =========
# HELPERS
# =========
ts() { date +"%Y-%m-%d %H:%M:%S"; }

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

DB_DUMP_DIR="$BACKUP_PATH/database"
REPO="$BACKUP_PATH/files
DB_DUMP_FILE="$DB_DUMP_DIR/immich-database.sql"

mkdir -p "$DB_DUMP_DIR" "$REPO" "$UPLOAD_LOCATION"

# Tools
command -v docker >/dev/null 2>&1 || { echo "$(ts) [ERROR] docker not found in PATH"; exit 1; }
command -v borg   >/dev/null 2>&1 || { echo "$(ts) [ERROR] borg not found in PATH";   exit 1; }

# =========
# LOG CONTEXT
# =========
echo "$(ts) [INFO] Library path:  $UPLOAD_LOCATION"
echo "$(ts) [INFO] DB data dir:   $DB_DATA_DIR   (reference only)"
echo "$(ts) [INFO] Backup root:   $BACKUP_PATH"
echo "$(ts) [INFO] Borg repo:     $REPO"
echo "$(ts) [INFO] DB dump file:  $DB_DUMP_FILE"
echo "$(ts) [INFO] Container:     $POSTGRES_CONTAINER"
echo "$(ts) [INFO] DB user:       $DB_USER"

# =========
# DATABASE DUMP
# =========
echo "$(ts) [INFO] Dumping Postgres from container '$POSTGRES_CONTAINER' to '$DB_DUMP_FILE'"
docker exec -t "$POSTGRES_CONTAINER" \
  pg_dumpall --clean --if-exists --username="$DB_USER" > "$DB_DUMP_FILE"

# NOTE: Avoid gzip for better dedup with Borg. If you prefer compression:
# docker exec -t "$POSTGRES_CONTAINER" pg_dumpall --clean --if-exists --username="$DB_USER" \
#   | gzip --rsyncable > "${DB_DUMP_FILE}.gz"

# =========
# BORG BACKUP
# =========
echo "$(ts) [INFO] Creating Borg archive"
borg create \
  --stats \
  "$REPO::{now}" \
  "$UPLOAD_LOCATION" \
  "$DB_DUMP_DIR" \
  --exclude "$UPLOAD_LOCATION/thumbs" \
  --exclude "$UPLOAD_LOCATION/encoded-video"

echo "$(ts) [INFO] Pruning old archives (keep weekly=4, monthly=3)"
borg prune \
  --keep-weekly=4 \
  --keep-monthly=3 \
  "$REPO"

echo "$(ts) [INFO] Compacting repository"
borg compact "$REPO"

echo "$(ts) [INFO] Immich backup completed successfully"
ping_hc "" "Immich backup OK at $(ts)"
