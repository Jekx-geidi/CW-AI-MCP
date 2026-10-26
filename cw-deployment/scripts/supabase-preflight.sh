#!/usr/bin/env bash
# Read-only pre-flight against a Supabase project before any restore.
# Changes nothing. Prints no secrets.
#
#   TARGET_URL='postgresql://postgres@db.<ref>.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=/path/supabase-ca.crt'
#   PGPASSWORD=...  (or ~/.pgpass)    PROJECT_REF=<ref>    TARGET_ENV=rehearsal|production
#   bash scripts/supabase-preflight.sh
#
# Exit 0 = safe to restore into this target. Used by supabase-restore.sh.
set -u
: "${TARGET_URL:?set TARGET_URL (postgres role, no password in the URL)}"
: "${PROJECT_REF:?set PROJECT_REF (the Supabase project ref)}"
: "${TARGET_ENV:?set TARGET_ENV=rehearsal or production}"

fail=0
pass() { echo "[PASS] $*"; }
warn() { echo "[WARN] $*"; }
bad()  { echo "[FAIL] $*"; fail=1; }
q() { psql "$TARGET_URL" -X -A -t -v ON_ERROR_STOP=1 -c "$1" 2>&1; }

echo "== target identity"
case "$TARGET_ENV" in rehearsal|production) pass "TARGET_ENV=$TARGET_ENV" ;; *) bad "TARGET_ENV must be rehearsal or production" ;; esac
case "$TARGET_URL" in
  *"$PROJECT_REF"*) pass "TARGET_URL refers to project $PROJECT_REF" ;;
  *) [ "$PROJECT_REF" = "local" ] && warn "PROJECT_REF=local (laptop rehearsal container)" || bad "TARGET_URL does not contain PROJECT_REF=$PROJECT_REF" ;;
esac
echo "$TARGET_URL" | grep -qE '^[a-z]+://[^/@]*:[^/@]*@' && bad "TARGET_URL contains a password - use PGPASSWORD or ~/.pgpass"

echo "== client tools"
for t in psql pg_restore vacuumdb; do
  v=$($t --version 2>/dev/null | sed -E 's/.* ([0-9]+)\..*/\1/')
  [ "$v" = "17" ] && pass "$t 17" || bad "$t major is '${v:-missing}', need 17"
done

echo "== connection"
if ! out=$(q "select 1"); then bad "cannot connect: $(echo "$out" | head -1)"; echo; echo "PRE-FLIGHT: FAILED"; exit 1; fi
pass "connected"
[ "$(q "select current_user")" = "postgres" ] && pass "connected as postgres" || bad "connected as $(q "select current_user"), expected postgres"
[ "$(q "select exists (select 1 from pg_roles where rolname = 'supabase_admin')")" = "t" ] \
  && pass "target is a Supabase project" || bad "target is not Supabase (no supabase_admin role)"
[ "$(q "select rolsuper from pg_roles where rolname = current_user")" = "f" ] \
  && pass "postgres is not superuser (expected on Supabase)" || warn "postgres is superuser - not a Supabase-managed project?"
ver=$(q "select current_setting('server_version')")
[ "$(q "select current_setting('server_version_num')::int/10000")" = "17" ] && pass "server $ver" || bad "server $ver is not 17"
ssl=$(q "select coalesce((select ssl from pg_stat_ssl where pid = pg_backend_pid())::text, 'unknown')")
if [ "$ssl" = "true" ]; then pass "connection uses TLS"
elif [ "$PROJECT_REF" = "local" ]; then warn "no TLS (local rehearsal container only)"
else bad "connection is not TLS - add sslmode=verify-full to TARGET_URL"; fi
case "$TARGET_URL" in *sslmode=verify-full*) pass "sslmode=verify-full" ;; *) [ "$PROJECT_REF" = "local" ] || warn "sslmode is not verify-full (server identity not verified)" ;; esac
case "$TARGET_URL" in *:6543*) bad "port 6543 is transaction pooling - use the direct connection or session pooler (5432)" ;; esac

echo "== target must be empty of CW objects (never overwrite)"
n=$(q "select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname in ('cw','cw_recovery')")
[ "$n" = "0" ] && pass "no relations in cw / cw_recovery" || bad "target already has $n relations in cw/cw_recovery - this pipeline never overwrites (ROLLBACK.md)"

echo "== settings that matter for the restore"
st=$(PGOPTIONS="-c statement_timeout=0" q "show statement_timeout")
[ "$st" = "0" ] && pass "session statement_timeout can be lifted for the restore" \
  || bad "statement_timeout stays '$st' - PGOPTIONS not honoured (pooler?) - use the direct connection"
echo "     max_connections=$(q "show max_connections"), in use=$(q "select count(*) from pg_stat_activity")"
echo "     database size now: $(q "select pg_size_pretty(pg_database_size(current_database()))")"
echo "     collation: $(q "select datcollate || ' provider=' || datlocprovider::text from pg_database where datname = current_database()")"
for r in cw_reader cw_agent cw_authenticator cw_loader; do
  [ "$(q "select exists (select 1 from pg_roles where rolname = '$r')")" = "t" ] && echo "     role $r: exists" || echo "     role $r: will be created"
done
warn "disk: Supabase does not expose provisioned disk size to SQL. Confirm in the dashboard (Settings > Compute and Disk) that it is >= 40 GB BEFORE restoring (SUPABASE_MIGRATION.md §3)"

if [ "$TARGET_ENV" = "production" ]; then
  echo "== production guard"
  [ "${CONFIRM_PRODUCTION_RESTORE:-}" = "$PROJECT_REF" ] \
    && pass "CONFIRM_PRODUCTION_RESTORE matches the project ref" \
    || bad "production restore needs CONFIRM_PRODUCTION_RESTORE=$PROJECT_REF (explicit, per run)"
fi

echo
[ "$fail" -eq 0 ] && echo "PRE-FLIGHT: OK" || echo "PRE-FLIGHT: FAILED - nothing was changed"
exit "$fail"
