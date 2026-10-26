#!/usr/bin/env bash
# Dump the SOURCE cw-postgres for migration. Read-only against the source.
#
# Run by the SOURCE owner (Ivan/Paul) on a machine with a PostgreSQL 17 client
# that can reach the source as a superuser (e.g. on the source host:
#   docker run --rm --network container:<source-pg-container> -v "$PWD:/out" \
#     -e SOURCE_URL postgres:17.11 bash /out/source-dump.sh
# ). Never put the password on the command line: use SOURCE_URL in the
# environment or ~/.pgpass.
#
#   SOURCE_URL=postgresql://postgres@<host>:5432/postgres  (required, superuser)
#   OUT_DIR=/out                                            (default: current dir)
#   FINAL=1   -> also exact row counts (ONLY with the loader paused)
#
# Produces in OUT_DIR:
#   globals-<ts>.sql        roles + memberships (contains SCRAM hashes: SECRET, mode 600)
#   cw-<ts>.dump            pg_dump custom format of database "postgres"
#   cw-<ts>.toc             pg_restore --list output (archive validation)
#   cw-<ts>.sha256          checksums for transfer verification
#   inventory-source-<ts>.txt  structure (+ row counts when FINAL=1)
set -euo pipefail
: "${SOURCE_URL:?set SOURCE_URL (superuser connection, password via env/.pgpass)}"
OUT_DIR=${OUT_DIR:-.}
ts=$(date -u +%Y%m%dT%H%M%SZ)
here=$(cd "$(dirname "$0")" && pwd)
umask 077
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

major=$(pg_dump --version | sed -E 's/.* ([0-9]+)\..*/\1/')
[ "$major" = "17" ] || { echo "pg_dump major is $major, need 17"; exit 1; }
srv=$(psql "$SOURCE_URL" -XAtc "select current_setting('server_version_num')::int/10000")
[ "$srv" = "17" ] || { echo "source major is $srv, expected 17"; exit 1; }
su=$(psql "$SOURCE_URL" -XAtc "select rolsuper from pg_roles where rolname = current_user")
[ "$su" = "t" ] || { echo "connect as a superuser (needed for roles and cw_recovery)"; exit 1; }

log "free space in $OUT_DIR:"; df -h . | tail -1
log "database size: $(psql "$SOURCE_URL" -XAtc "select pg_size_pretty(pg_database_size('postgres'))")"

log "globals (roles, no tablespaces) -> globals-$ts.sql"
pg_dumpall -d "$SOURCE_URL" --globals-only --no-tablespaces -f "globals-$ts.sql"

log "pg_dump -Fc database postgres -> cw-$ts.dump"
start=$(date +%s)
pg_dump -d "$SOURCE_URL" -Fc -Z 6 --no-sync -f "cw-$ts.dump"
log "dump took $(( $(date +%s) - start ))s, size $(du -h "cw-$ts.dump" | cut -f1)"

log "validating archive"
pg_restore --list "cw-$ts.dump" > "cw-$ts.toc"
# TOC line: "<id>; <catalog> <oid> <TYPE...> <schema> <name> <owner>"
echo "  archive entries by type:"
awk '!/^;/ && NF { t=$4; if ($4=="TABLE" && $5=="DATA") t="TABLE DATA"; print t }' "cw-$ts.toc" \
  | sort | uniq -c | sed 's/^/   /'

log "inventory"
counts=(); [ "${FINAL:-0}" = "1" ] && counts=(-v counts=on)
psql "$SOURCE_URL" -X -A -t -q -v ON_ERROR_STOP=1 "${counts[@]}" -c 'set statement_timeout = 0' \
  -f "$here/db-inventory.sql" > "inventory-source-$ts.txt"
echo "  $(wc -l < "inventory-source-$ts.txt") inventory lines"

sha256sum "globals-$ts.sql" "cw-$ts.dump" "cw-$ts.toc" "inventory-source-$ts.txt" > "cw-$ts.sha256"
log "done. Transfer cw-$ts.* globals-$ts.sql inventory-source-$ts.txt; verify with: sha256sum -c cw-$ts.sha256"
