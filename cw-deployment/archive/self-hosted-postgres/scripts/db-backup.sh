#!/usr/bin/env bash
# Nightly logical backup of the NEW cw-postgres (after cutover only).
# Run from cw-deployment/db (reads CW_PG_ROOT from .env). Cron example:
#   15 2 * * * cd ~/deployments/cw-db && bash ../scripts/db-backup.sh >> backup.log 2>&1
#
#   KEEP=3                         local dumps kept on the CW disk
#   BACKUP_AGE_RECIPIENT=age1...   optional: encrypt with `age` before off-host copy
#   BACKUP_RSYNC_TARGET=user@host:/path   optional: off-host copy (agreed target, MIGRATION.md Q9)
set -euo pipefail
cd "$(dirname "$0")/../db"
# shellcheck disable=SC1091
set -a; . ./.env; set +a
KEEP=${KEEP:-3}
dir="$CW_PG_ROOT/dumps/backups"
ts=$(date -u +%Y%m%dT%H%M%SZ)
f="cw-backup-$ts.dump"
log() { echo "[$(date -u +%FT%TZ)] $*"; }

docker exec cw-postgres mkdir -p /dumps/backups
avail_kb=$(df -Pk "$CW_PG_ROOT" | awk 'NR==2 {print $4}')
db_kb=$(docker exec cw-postgres psql -U postgres -XAtc "select pg_database_size('postgres')/1024")
[ "$avail_kb" -gt $(( db_kb / 2 )) ] || { log "ABORT: less free space than half the DB size"; exit 1; }

log "dump -> $f"
docker exec cw-postgres pg_dump -U postgres -d postgres -Fc -Z 6 -f "/dumps/backups/$f"
docker exec cw-postgres pg_restore --list "/dumps/backups/$f" > /dev/null
(cd "$dir" && sha256sum "$f" > "$f.sha256")
log "ok, $(du -h "$dir/$f" | cut -f1)"

if [ -n "${BACKUP_RSYNC_TARGET:-}" ]; then
  src="$dir/$f"
  if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
    age -r "$BACKUP_AGE_RECIPIENT" -o "$src.age" "$src"; src="$src.age"
  fi
  rsync -a "$src" "$dir/$f.sha256" "$BACKUP_RSYNC_TARGET/"
  log "copied off-host"
  rm -f "$dir/$f.age"
else
  log "WARNING: no off-host target configured (BACKUP_RSYNC_TARGET) - local copy only"
fi

ls -1t "$dir"/cw-backup-*.dump | tail -n +$(( KEEP + 1 )) | while read -r old; do
  rm -f "$old" "$old.sha256"; log "pruned $(basename "$old")"
done
