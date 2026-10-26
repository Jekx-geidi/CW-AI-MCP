-- Re-apply CW privileges on Supabase AFTER the restore. Run as "postgres".
-- Idempotent. The dump is taken with --no-privileges, so every grant that should
-- exist is stated here, explicitly, and nothing else is granted.
--
--   psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 -f scripts/supabase-grants.sql
--
-- Source model (audit 2026-10-19):
--   cw_reader, cw_agent : USAGE on schema cw, SELECT on all 110 cw relations
--                         (direct grants + default privileges for postgres in cw)
--   cw_recovery         : no access for anyone but the owner
--   no PUBLIC/anon access to either schema

\set ON_ERROR_STOP 1
set statement_timeout = '120s';

-- Readers (MCP and PostgREST)
grant usage on schema cw to cw_reader, cw_agent;
grant select on all tables in schema cw to cw_reader, cw_agent;
alter default privileges for role postgres in schema cw grant select on tables to cw_reader, cw_agent;

-- Loader: DML on cw only (no DDL, no cw_recovery). If the sink needs schema
-- evolution (auto-create/alter tables), that is an explicit decision in
-- SUPABASE_MIGRATION.md (D7), not a silent grant here.
grant usage on schema cw to cw_loader;
grant select, insert, update, delete on all tables in schema cw to cw_loader;
alter default privileges for role postgres in schema cw grant select, insert, update, delete on tables to cw_loader;

-- Defence in depth: the CW schemas are never reachable through Supabase's Data API
-- roles, even if someone later adds "cw" to the exposed schemas.
revoke all on schema cw, cw_recovery from public, anon, authenticated, service_role;
revoke all on all tables in schema cw, cw_recovery from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema cw revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema cw_recovery revoke all on tables from public, anon, authenticated, service_role;
-- The 16 cw SQL functions keep PostgreSQL's default EXECUTE-to-PUBLIC (as on the
-- source); without USAGE on schema cw, no Data API role can reach them.

\echo 'grants applied'
