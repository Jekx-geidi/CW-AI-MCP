#!/usr/bin/env bash
# Restore a source dump into the NEW, EMPTY cw-postgres container on gc-gei-ollama.
#
# Refuses to run if the target already contains CW tables — it never overwrites.
# Run from cw-deployment/db with the dump files in ${CW_PG_ROOT}/dumps:
#   bash ../scripts/restore.sh <ts>        e.g. 20261020T010000Z
#
#   JOBS=4      parallel restore workers (default 4; host has 16 CPUs, DB limit 4)
set -euo pipefail
ts=${1:?usage: restore.sh <timestamp of cw-<ts>.dump>}
JOBS=${JOBS:-4}
C=cw-postgres
here=$(cd "$(dirname "$0")" && pwd)
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
psql_c() { docker exec -i "$C" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 "$@"; }

[ "$(docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null)" = "healthy" ] \
  || { echo "container $C is not healthy"; exit 1; }

n=$(psql_c -Atc "select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname in ('cw','cw_recovery')")
[ "$n" = "0" ] || { echo "STOP: target already has $n CW relations. This script never overwrites. See ROLLBACK/MIGRATION."; exit 1; }

log "verifying checksums"
docker exec -w /dumps "$C" sha256sum -c "cw-$ts.sha256"

log "validating archive"
docker exec "$C" pg_restore --list "/dumps/cw-$ts.dump" > /dev/null

log "applying globals (roles), keeping this cluster's own superuser"
docker exec "$C" sh -c "grep -vE '^(CREATE|ALTER) ROLE postgres( |;)' /dumps/globals-$ts.sql" | psql_c -q

log "restoring with $JOBS jobs"
start=$(date +%s)
docker exec -e PGOPTIONS="-c maintenance_work_mem=1GB" "$C" \
  pg_restore -U postgres -d postgres -j "$JOBS" --exit-on-error "/dumps/cw-$ts.dump"
log "restore took $(( $(date +%s) - start ))s"

log "analyze"
docker exec "$C" vacuumdb -U postgres -d postgres --analyze-in-stages -j "$JOBS" -q

log "inventory (destination)"
counts=(); [ "${FINAL:-0}" = "1" ] && counts=(-v counts=on)
psql_c -A -t -q "${counts[@]}" < "$here/db-inventory.sql" > "inventory-dest-$ts.txt"
echo "  $(wc -l < "inventory-dest-$ts.txt") lines -> inventory-dest-$ts.txt"
log "compare:  diff <(grep -v '^roleconfig' inventory-source-$ts.txt) <(grep -v '^roleconfig' inventory-dest-$ts.txt)"
log "(roleconfig compared separately: quoting of search_path may differ textually)"
log "database size: $(psql_c -Atc "select pg_size_pretty(pg_database_size('postgres'))")"
