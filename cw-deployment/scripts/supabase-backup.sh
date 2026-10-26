#!/usr/bin/env bash
# Off-platform logical backup of the CW schemas on Supabase (supplements Supabase's
# own daily physical backups; see SUPABASE_SECURITY.md §6 for when it is needed).
#
# Runs on any host with a PostgreSQL 17 client that is allowed through the Supabase
# network restrictions. NOT on gc-gei-ollama by default (its Docker disk is 90% full
# and it must host only the MCP + Octelium containers).
#
#   export BACKUP_URL='postgresql://postgres@db.<ref>.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=/path/supabase-ca.crt'
#   export PGPASSWORD=...                      # or ~/.pgpass
#   BACKUP_DIR=/srv/cw-backups  KEEP=3  bash scripts/supabase-backup.sh
#
#   BACKUP_AGE_RECIPIENT=age1...       optional: encrypt with `age` (recommended: CW data has customer PII)
#   BACKUP_RSYNC_TARGET=user@host:/p   optional: copy off-host (the agreed target, gate G6)
#
# Restore test (monthly): supabase-restore.sh into a REHEARSAL project, or into a
# local supabase/postgres container, then supabase-verify.sql (SUPABASE_VALIDATION.md §7).
set -euo pipefail
: "${BACKUP_URL:?set BACKUP_URL}"
: "${BACKUP_DIR:?set BACKUP_DIR}"
KEEP=${KEEP:-3}
ts=$(date -u +%Y%m%dT%H%M%SZ)
f="cw-backup-$ts.dump"
log() { echo "[$(date -u +%FT%TZ)] $*"; }
umask 077
mkdir -p "$BACKUP_DIR"; cd "$BACKUP_DIR"

db_kb=$(psql "$BACKUP_URL" -X -A -t -c "select pg_database_size(current_database())/1024")
avail_kb=$(df -Pk . | awk 'NR==2 {print $4}')
[ "$avail_kb" -gt $(( db_kb / 2 )) ] || { log "ABORT: less free space than half the DB size"; exit 1; }

log "dump -> $f"
PGOPTIONS="-c statement_timeout=0" pg_dump -d "$BACKUP_URL" -Fc -Z 6 \
  --schema=cw --schema=cw_recovery --no-owner --no-privileges -f "$f"
pg_restore --list "$f" > /dev/null
sha256sum "$f" > "$f.sha256"
log "ok, $(du -h "$f" | cut -f1)"

if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  age -r "$BACKUP_AGE_RECIPIENT" -o "$f.age" "$f" && rm -f "$f" && sha256sum "$f.age" > "$f.sha256"
  f="$f.age"; log "encrypted -> $f"
fi
if [ -n "${BACKUP_RSYNC_TARGET:-}" ]; then
  rsync -a "$f" "$f.sha256" "$BACKUP_RSYNC_TARGET/" && log "copied off-host"
else
  log "WARNING: no off-host target (BACKUP_RSYNC_TARGET) - local copy only"
fi

ls -1t cw-backup-*.dump* 2>/dev/null | grep -v '\.sha256$' | tail -n +$(( KEEP + 1 )) | while read -r old; do
  rm -f "$old" "${old%.age}.sha256" "$old.sha256"; log "pruned $old"
done
