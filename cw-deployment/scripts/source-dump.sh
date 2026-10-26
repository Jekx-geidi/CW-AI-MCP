#!/usr/bin/env bash
# Dump the SOURCE cw-postgres for the Supabase migration. Read-only against the source.
#
# Run by the SOURCE owner (Ivan/Paul/Joshua) as a superuser, on (or next to) the
# source host, with a PostgreSQL 17 client, e.g.:
#   docker run --rm --network container:<source-pg-container> -v "$PWD:/out" -w /out \
#     -e SOURCE_URL -e PGPASSWORD postgres:17.11 bash /out/scripts/source-dump.sh
# Never put the password on the command line: PGPASSWORD in the environment or ~/.pgpass.
#
#   SOURCE_URL=postgresql://postgres@<host>:5432/postgres   (required, superuser)
#   OUT_DIR=./dumps                                           (default)
#   FINAL=1   -> also exact row counts + max(Last_Update_UTC) per table, and
#                row-content hashes for every cw table under 64 MB.
#                Only meaningful with the loader paused (cutover, Method A) or for
#                the parallel-run comparison (Method B). ~14 GB scan.
#
# Differences from the self-hosted version (archive/self-hosted-postgres):
#   - NO roles / globals: Supabase roles are recreated by supabase-roles.sql, so no
#     password hashes ever leave the source.
#   - Only schemas cw and cw_recovery; --no-owner --no-privileges (Supabase manages
#     ownership; grants are re-applied explicitly by supabase-grants.sql).
#
# Produces in OUT_DIR:
#   cw-<ts>.dump               pg_dump custom format (schemas cw, cw_recovery)
#   cw-<ts>.toc                pg_restore --list output (archive validation)
#   cw-<ts>.meta               dump start time (UTC), source WAL LSN, write counters
#   inventory-source-<ts>.txt  structure (+ row counts when FINAL=1)
#   cw-<ts>.sha256             checksums for transfer verification
set -euo pipefail
: "${SOURCE_URL:?set SOURCE_URL (superuser connection, password via PGPASSWORD/.pgpass)}"
OUT_DIR=${OUT_DIR:-./dumps}
ts=$(date -u +%Y%m%dT%H%M%SZ)
here=$(cd "$(dirname "$0")" && pwd)
umask 077
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
q() { psql "$SOURCE_URL" -X -A -t -v ON_ERROR_STOP=1 -c "$1"; }

major=$(pg_dump --version | sed -E 's/.* ([0-9]+)\..*/\1/')
[ "$major" = "17" ] || { echo "pg_dump major is $major, need 17"; exit 1; }
[ "$(q "select current_setting('server_version_num')::int/10000")" = "17" ] || { echo "source is not PostgreSQL 17"; exit 1; }
[ "$(q "select rolsuper from pg_roles where rolname = current_user")" = "t" ] \
  || { echo "connect as a superuser (cw_recovery is not readable otherwise)"; exit 1; }
[ "$(q "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','p','v','m','S','f')")" = "0" ] \
  || echo "WARNING: schema public is not empty on the source; this dump only carries cw and cw_recovery"

log "free space in $OUT_DIR:"; df -h . | tail -1
log "database size: $(q "select pg_size_pretty(pg_database_size(current_database()))")"

# T0: anything the loader wrote before this moment is in the dump. Used to choose
# the replay start point for the parallel sink connector (SUPABASE_MIGRATION.md §6, Method B).
{
  echo "dump_started_utc=$(date -u +%FT%TZ)"
  echo "source_lsn=$(q "select pg_current_wal_lsn()")"
  echo "source_writes=$(q "select sum(n_tup_ins + n_tup_upd + n_tup_del) from pg_stat_user_tables where schemaname = 'cw'")"
} > "cw-$ts.meta"

log "pg_dump -Fc schemas cw, cw_recovery -> cw-$ts.dump"
start=$(date +%s)
pg_dump -d "$SOURCE_URL" -Fc -Z 6 --no-sync \
  --schema=cw --schema=cw_recovery \
  --no-owner --no-privileges --no-publications --no-subscriptions \
  -f "cw-$ts.dump"
log "dump took $(( $(date +%s) - start ))s, size $(du -h "cw-$ts.dump" | cut -f1)"
echo "dump_finished_utc=$(date -u +%FT%TZ)" >> "cw-$ts.meta"

log "validating archive"
pg_restore --list "cw-$ts.dump" > "cw-$ts.toc"
echo "  archive entries by type:"
awk '!/^;/ && NF { t=$4; if ($4=="TABLE" && $5=="DATA") t="TABLE DATA"; print t }' "cw-$ts.toc" \
  | sort | uniq -c | sed 's/^/   /'
if grep -qE ' (ACL|OWNER|ROLE|EXTENSION|PUBLICATION|SUBSCRIPTION) ' "cw-$ts.toc"; then
  echo "  WARNING: archive contains ACL/owner/role/extension entries - check the flags"
fi

log "inventory"
counts=(); [ "${FINAL:-0}" = "1" ] && counts=(-v counts=on -v hashes=on)
psql "$SOURCE_URL" -X -A -t -q -v ON_ERROR_STOP=1 "${counts[@]}" -c 'set statement_timeout = 0' \
  -f "$here/db-inventory.sql" > "inventory-source-$ts.txt"
echo "  $(wc -l < "inventory-source-$ts.txt") inventory lines"

sha256sum "cw-$ts.dump" "cw-$ts.toc" "cw-$ts.meta" "inventory-source-$ts.txt" > "cw-$ts.sha256"
log "done: $OUT_DIR/cw-$ts.{dump,toc,meta,sha256} inventory-source-$ts.txt"
log "next: scripts/supabase-restore.sh $ts  (see SUPABASE_MIGRATION.md)"
