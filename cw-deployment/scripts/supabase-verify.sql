-- Post-restore security and structure checks on the Supabase project. READ-ONLY.
-- Run as "postgres". Every check line is PASS or FAIL (INFO lines are context);
-- supabase-restore.sh fails the run if any FAIL line appears.
--
--   psql "$TARGET_URL" -X -A -t -q -f scripts/supabase-verify.sql

\set ON_ERROR_STOP 1
set default_transaction_read_only = on;
set statement_timeout = '60s';

with
rel as (
  select c.oid, n.nspname, c.relkind
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('cw', 'cw_recovery') and c.relkind in ('r','p','v','m')
),
cfg as (select r.rolname, coalesce(array_to_string(r.rolconfig, ','), '') as c from pg_roles r),
checks(name, ok, detail) as (
  values
  ('server is PostgreSQL 17',
     current_setting('server_version_num')::int / 10000 = 17, current_setting('server_version')),
  ('target is Supabase (supabase_admin exists)',
     exists (select 1 from pg_roles where rolname = 'supabase_admin'), ''),
  ('cw has 108 tables',
     (select count(*) from rel where nspname = 'cw' and relkind in ('r','p')) = 108,
     (select count(*) from rel where nspname = 'cw' and relkind in ('r','p'))::text),
  ('cw has 2 views',
     (select count(*) from rel where nspname = 'cw' and relkind = 'v') = 2, ''),
  ('cw_recovery has 10 tables',
     (select count(*) from rel where nspname = 'cw_recovery') = 10, ''),
  ('every cw table has a primary key',
     not exists (select 1 from rel where nspname = 'cw' and relkind in ('r','p')
                 and not exists (select 1 from pg_constraint k where k.conrelid = rel.oid and k.contype = 'p')), ''),
  ('cw has 16 functions',
     (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cw') = 16, ''),
  ('cw objects owned by postgres',
     not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname in ('cw','cw_recovery') and pg_get_userbyid(c.relowner) <> 'postgres'), ''),
  -- cw_agent (the MCP identity)
  ('cw_agent: login, connection limit 10',
     exists (select 1 from pg_roles where rolname = 'cw_agent' and rolcanlogin and rolconnlimit = 10), ''),
  ('cw_agent: statement_timeout=60s',
     (select c from cfg where rolname = 'cw_agent') like '%statement_timeout=60s%', (select c from cfg where rolname = 'cw_agent')),
  ('cw_agent: default_transaction_read_only=on',
     (select c from cfg where rolname = 'cw_agent') like '%default_transaction_read_only=on%', ''),
  ('cw_agent: SELECT on all 110 cw relations',
     (select count(*) from rel where nspname = 'cw' and has_table_privilege('cw_agent', oid, 'SELECT')) = 110, ''),
  ('cw_agent: no write privilege anywhere in cw/cw_recovery',
     not exists (select 1 from rel where has_table_privilege('cw_agent', oid, 'INSERT,UPDATE,DELETE,TRUNCATE')), ''),
  ('cw_agent: no access to cw_recovery',
     not has_schema_privilege('cw_agent', 'cw_recovery', 'USAGE'), ''),
  ('cw_agent: not a member of any Supabase role',
     not exists (select 1 from pg_auth_members m join pg_roles g on g.oid = m.roleid
                 where m.member = 'cw_agent'::regrole and g.rolname !~ '^pg_'), ''),
  -- cw_reader / cw_authenticator (PostgREST pattern)
  ('cw_reader: nologin, SELECT on all 110 cw relations',
     exists (select 1 from pg_roles where rolname = 'cw_reader' and not rolcanlogin)
     and (select count(*) from rel where nspname = 'cw' and has_table_privilege('cw_reader', oid, 'SELECT')) = 110, ''),
  ('cw_authenticator: noinherit, may SET ROLE cw_reader, no direct table access',
     exists (select 1 from pg_roles where rolname = 'cw_authenticator' and not rolinherit)
     and pg_has_role('cw_authenticator', 'cw_reader', 'SET')
     and not exists (select 1 from rel where has_table_privilege('cw_authenticator', oid, 'SELECT')), ''),
  -- cw_loader
  ('cw_loader: DML on all 108 cw tables, nothing on cw_recovery, no DDL on schema',
     (select count(*) from rel where nspname = 'cw' and relkind in ('r','p')
        and has_table_privilege('cw_loader', oid, 'INSERT,UPDATE,DELETE')) = 108
     and not has_schema_privilege('cw_loader', 'cw_recovery', 'USAGE')
     and not has_schema_privilege('cw_loader', 'cw', 'CREATE'), ''),
  -- Supabase Data API roles must not reach CW data
  ('anon/authenticated/service_role/authenticator: no USAGE on cw or cw_recovery',
     not exists (select 1 from unnest(array['anon','authenticated','service_role','authenticator']) r,
                       unnest(array['cw','cw_recovery']) s where has_schema_privilege(r, s, 'USAGE')), ''),
  ('anon/authenticated/service_role/authenticator: no table privilege in cw/cw_recovery',
     not exists (select 1 from rel, unnest(array['anon','authenticated','service_role','authenticator']) r
                 where has_table_privilege(r, rel.oid, 'SELECT,INSERT,UPDATE,DELETE')), ''),
  ('PUBLIC has no USAGE on cw / cw_recovery',
     not exists (select 1 from pg_namespace where nspname in ('cw','cw_recovery')
                 and coalesce(nspacl::text, '') ~ '(^|[{,])=[A-Za-z]*U'), ''),
  ('Supabase reserved roles untouched (authenticator still noinherit login)',
     exists (select 1 from pg_roles where rolname = 'authenticator' and rolcanlogin and not rolinherit)
     and not pg_has_role('authenticator', 'cw_reader', 'MEMBER'), '')
)
select case when ok then 'PASS' else 'FAIL' end || ' ' || name || case when detail <> '' then ' (' || detail || ')' else '' end
  from checks;

select 'INFO database collation: ' || datcollate || ' / provider ' || datlocprovider::text
       || coalesce(' / icu ' || datlocale, '') from pg_database where datname = current_database();
select 'INFO database size: ' || pg_size_pretty(pg_database_size(current_database()));
select 'INFO max_connections: ' || current_setting('max_connections');
