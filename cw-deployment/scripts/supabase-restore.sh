#!/usr/bin/env bash
# Restore a source dump (source-dump.sh) into an EMPTY Supabase project.
#
# Never overwrites: pre-flight refuses if cw/cw_recovery already contain anything.
# Never touches Supabase-managed roles. Production needs an explicit per-run
# confirmation (CONFIRM_PRODUCTION_RESTORE=<project ref>).
#
# Run from the cw-deployment directory, on a host that has the dump and a
# PostgreSQL 17 client + python3 (preferred: the source host; see SUPABASE_MIGRATION.md §5):
#
#   export TARGET_URL='postgresql://postgres@db.<ref>.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=/path/supabase-ca.crt'
#   export PGPASSWORD=...            # Supabase postgres password (never on the command line)
#   export PROJECT_REF=<ref> TARGET_ENV=rehearsal
#   bash scripts/supabase-restore.sh <ts>          # e.g. 20261021T010000Z
#
#   DUMP_DIR=./dumps   where cw-<ts>.* and inventory-source-<ts>.txt are
#   SECRETS_DIR=./secrets   optional files cw_agent_password, cw_authenticator_password,
#                           cw_loader_password (mode 600). Missing file = role created without password.
#   JOBS=2             parallel restore workers (match Supabase compute cores, see §3)
#   FINAL=1            also compare exact row counts + content hashes (source dump taken with FINAL=1)
set -euo pipefail
ts=${1:?usage: supabase-restore.sh <timestamp of cw-<ts>.dump>}
cd "$(dirname "$0")/.."
DUMP_DIR=${DUMP_DIR:-./dumps}
SECRETS_DIR=${SECRETS_DIR:-./secrets}
JOBS=${JOBS:-2}
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
umask 077

log "pre-flight"
bash scripts/supabase-preflight.sh

log "verifying dump checksums and archive"
(cd "$DUMP_DIR" && sha256sum -c "cw-$ts.sha256")
pg_restore --list "$DUMP_DIR/cw-$ts.dump" > /dev/null

log "roles (supabase-roles.sql)"
vars=()
for r in cw_agent cw_authenticator cw_loader; do
  f="$SECRETS_DIR/${r}_password"
  if [ -s "$f" ]; then
    [ "$(stat -c '%a' "$f")" = "600" ] || { echo "STOP: $f must be mode 600"; exit 1; }
    v=$(python3 -I scripts/scram-verifier.py < "$f")
    vars+=(-v "${r}_verifier=$v")
  else
    echo "  no $f - $r gets no password (cannot log in until set)"
  fi
done
psql "$TARGET_URL" -X -q -v ON_ERROR_STOP=1 "${vars[@]}" -f scripts/supabase-roles.sql
unset vars v

log "restoring with $JOBS jobs (no owner, no privileges)"
start=$(date +%s)
PGOPTIONS="-c statement_timeout=0 -c lock_timeout=0 -c idle_in_transaction_session_timeout=0 -c maintenance_work_mem=512MB" \
  pg_restore -d "$TARGET_URL" -j "$JOBS" --no-owner --no-privileges --exit-on-error "$DUMP_DIR/cw-$ts.dump"
log "restore took $(( $(date +%s) - start ))s"

log "analyze (cw, cw_recovery)"
PGOPTIONS="-c statement_timeout=0" vacuumdb -d "$TARGET_URL" --analyze-in-stages -n cw -n cw_recovery -j "$JOBS" -q

log "grants (supabase-grants.sql)"
psql "$TARGET_URL" -X -q -v ON_ERROR_STOP=1 -f scripts/supabase-grants.sql

log "security and structure checks (supabase-verify.sql)"
out=$(psql "$TARGET_URL" -X -A -t -q -v ON_ERROR_STOP=1 -f scripts/supabase-verify.sql)
echo "$out" | sed 's/^/  /'
if echo "$out" | grep -q '^FAIL'; then echo "VERIFY: FAILED"; verify_ok=0; else echo "VERIFY: OK"; verify_ok=1; fi

log "inventory (destination)"
counts=(); [ "${FINAL:-0}" = "1" ] && counts=(-v counts=on -v hashes=on)
PGOPTIONS="-c statement_timeout=0" psql "$TARGET_URL" -X -A -t -q -v ON_ERROR_STOP=1 "${counts[@]}" \
  -f scripts/db-inventory.sql > "$DUMP_DIR/inventory-dest-$ts.txt"
bash scripts/compare-inventory.sh "$DUMP_DIR/inventory-source-$ts.txt" "$DUMP_DIR/inventory-dest-$ts.txt" && cmp_ok=1 || cmp_ok=0

log "database size: $(psql "$TARGET_URL" -X -A -t -c "select pg_size_pretty(pg_database_size(current_database()))")"
[ "$verify_ok$cmp_ok" = "11" ] && { echo "RESTORE: OK"; exit 0; }
echo "RESTORE: FINISHED WITH FAILURES - do not cut over; see SUPABASE_VALIDATION.md"; exit 1
