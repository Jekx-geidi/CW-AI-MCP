-- CW Postgres inventory: deterministic, read-only, diffable.
--
-- Run the SAME script on source and destination and diff the outputs:
--   psql "$URL" -X -A -t -q -v ON_ERROR_STOP=1 -f db-inventory.sql > inventory-<side>.txt
--   diff inventory-source.txt inventory-dest.txt
--
-- Structure-only by default (cheap, safe on a live mirror).
-- Exact row counts: add  -v counts=on  — this runs count(*) on every table
-- (~14 GB scan). Only do that with the loader PAUSED, as a role without the
-- 60s statement_timeout (cw_agent will time out on the big tables).
--
-- Content hashes: add  -v hashes=on  — md5 over every row (ordered by primary
-- key) for each cw table under 64 MB, i.e. all but the ~9 largest; those are
-- covered by exact counts + max(Last_Update_UTC). Same loader rule as counts.
--
-- Schemas compared: cw (and cw_recovery when the role can read it).

\set ON_ERROR_STOP 1
\pset footer off
set default_transaction_read_only = on;
-- Fixed search_path: view/function definitions print schema-qualified names
-- relative to it, so it must not depend on the connecting role's default.
set search_path = pg_catalog;
-- Fixed value rendering, so row hashes match across hosts (source vs Supabase)
set datestyle = 'ISO, MDY';
set timezone = 'UTC';
set intervalstyle = 'postgres';
set bytea_output = 'hex';
set extra_float_digits = 1;

-- server / database
select 'server|major|' || current_setting('server_version_num')::int / 10000;
select 'db|encoding|' || pg_encoding_to_char(encoding) || '|' || datcollate || '|' || datctype
  from pg_database where datname = current_database();
select 'ext|' || extname || '|' || extversion from pg_extension order by extname;

-- tables: column count, primary key columns
select 'table|' || n.nspname || '.' || c.relname
       || '|cols=' || (select count(*) from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)
       || '|pk=' || coalesce((select string_agg(a.attname, ',' order by a.attnum)
                              from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
                              where k.conrelid = c.oid and k.contype = 'p'), '-')
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r', 'p') and n.nspname in ('cw', 'cw_recovery')
 order by 1;

-- column definitions (hash per table: name, type, nullability, default)
select 'coldef|' || n.nspname || '.' || c.relname || '|'
       || md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull
                         || ':' || coalesce(pg_get_expr(d.adbin, d.adrelid), ''), ',' order by a.attnum))
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
 where c.relkind in ('r', 'p') and n.nspname in ('cw', 'cw_recovery')
 group by n.nspname, c.relname order by 1;

-- indexes and constraints (definitions, name-independent order)
select 'index|' || schemaname || '.' || tablename || '|' || md5(indexdef)
  from pg_indexes where schemaname in ('cw', 'cw_recovery') order by 1;
select 'constraint|' || n.nspname || '.' || c.relname || '|' || k.contype::text || '|' || md5(pg_get_constraintdef(k.oid))
  from pg_constraint k join pg_class c on c.oid = k.conrelid join pg_namespace n on n.oid = c.relnamespace
 where n.nspname in ('cw', 'cw_recovery') order by 1;

-- functions and views (definition hashes)
select 'function|' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|'
       || md5(pg_get_functiondef(p.oid))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('cw', 'cw_recovery') order by 1;
select 'view|' || n.nspname || '.' || c.relname || '|' || md5(pg_get_viewdef(c.oid))
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('v', 'm') and n.nspname in ('cw', 'cw_recovery') order by 1;

-- roles, role settings, memberships, privileges
-- CW roles only. The source's PostgREST login is "authenticator"; Supabase
-- reserves that name, so on Supabase it is "cw_authenticator"
-- (compare-inventory.sh maps the name). Supabase's own "authenticator" is
-- excluded (detected by the presence of supabase_admin). cw_loader is new on
-- Supabase and compared separately.
\set cwroles '(r.rolname in (''cw_agent'', ''cw_reader'', ''cw_authenticator'', ''cw_loader'') or (r.rolname = ''authenticator'' and not exists (select 1 from pg_roles s where s.rolname = ''supabase_admin'')))'
select 'role|' || r.rolname || '|login=' || r.rolcanlogin || '|super=' || r.rolsuper || '|inherit=' || r.rolinherit
       || '|connlimit=' || r.rolconnlimit
  from pg_roles r where :cwroles order by 1;
select 'roleconfig|' || r.rolname || '|' || array_to_string(s.setconfig, ',')
  from pg_db_role_setting s join pg_roles r on r.oid = s.setrole where :cwroles order by 1;
select 'member|' || r.rolname || '|' || g.rolname
  from pg_auth_members m join pg_roles r on r.oid = m.member join pg_roles g on g.oid = m.roleid
 where :cwroles and g.rolname !~ '^pg_' order by 1;
select 'grant|' || r.rolname || '|' || n.nspname || '|select=' || count(*) filter (where has_table_privilege(r.oid, c.oid, 'SELECT'))
       || '|write=' || count(*) filter (where has_table_privilege(r.oid, c.oid, 'INSERT,UPDATE,DELETE'))
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 cross join pg_roles r
 where c.relkind in ('r', 'p', 'v', 'm') and n.nspname in ('cw', 'cw_recovery') and :cwroles
 group by r.rolname, n.nspname order by 1;

-- exact row counts + newest change timestamp (only with -v counts=on)
\if :{?counts}
select format('select %L || count(*)%s from %I.%I',
              'rows|' || n.nspname || '.' || c.relname || '|',
              case when exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'Last_Update_UTC' and not a.attisdropped)
                   then ' || ''|last_update_utc='' || coalesce(max("Last_Update_UTC")::text, ''-'')' else '' end,
              n.nspname, c.relname)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r', 'p') and n.nspname in ('cw', 'cw_recovery')
   and has_table_privilege(c.oid, 'SELECT')
 order by n.nspname, c.relname
\gexec
\endif

-- row-content hashes for cw tables < 64 MB (only with -v hashes=on)
\if :{?hashes}
select format('select %L || count(*) || ''|md5='' || md5(coalesce(string_agg(md5(t::text), '''' order by %s), '''')) from %I.%I t',
              'hash|' || n.nspname || '.' || c.relname || '|rows=',
              (select string_agg(format('t.%I', a.attname), ', ' order by array_position(k.conkey, a.attnum))
                 from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
                where k.conrelid = c.oid and k.contype = 'p'),
              n.nspname, c.relname)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r', 'p') and n.nspname = 'cw'
   and pg_relation_size(c.oid) < 64 * 1024 * 1024
   and exists (select 1 from pg_constraint k where k.conrelid = c.oid and k.contype = 'p')
   and has_table_privilege(c.oid, 'SELECT')
 order by n.nspname, c.relname
\gexec
\endif
