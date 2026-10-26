-- CW source database audit for the Supabase migration. READ-ONLY.
--
-- Answers: what exactly has to move, and what will collide with Supabase's
-- managed environment (reserved roles, superuser-only objects, extensions,
-- collation, size).
--
--   psql "$SOURCE_URL" -X -q -v ON_ERROR_STOP=0 -f source-audit.sql > source-audit-<date>.txt
--
-- Safe as cw_agent (catalog queries only, each well under its 60 s timeout);
-- sections that need more privilege print "(not visible to <role>)" instead of
-- failing. Run once more as the source superuser (owner) for the full picture.

\pset footer off
\pset null '-'
set default_transaction_read_only = on;
set statement_timeout = '50s';

\echo '=== 1. Server, database, size'
select current_user as connected_as,
       (select rolsuper from pg_roles where rolname = current_user) as is_superuser,
       version() as version,
       current_setting('server_version_num') as version_num;
select datname, pg_encoding_to_char(encoding) as encoding, datcollate, datctype,
       datlocprovider, pg_size_pretty(pg_database_size(datname)) as size
  from pg_database where datname = current_database();
select name, setting, unit from pg_settings
 where name in ('max_connections','shared_buffers','effective_cache_size','work_mem',
                'maintenance_work_mem','wal_level','max_wal_senders','max_replication_slots',
                'ssl','data_checksums','password_encryption','timezone','DateStyle',
                'default_toast_compression','standard_conforming_strings')
 order by name;

\echo '=== 2. Schemas (non-system) with object counts and size'
select n.nspname as schema, pg_get_userbyid(n.nspowner) as owner,
       count(c.oid) filter (where c.relkind in ('r','p')) as tables,
       count(c.oid) filter (where c.relkind = 'v') as views,
       count(c.oid) filter (where c.relkind = 'm') as matviews,
       count(c.oid) filter (where c.relkind = 'S') as sequences,
       count(c.oid) filter (where c.relkind = 'f') as foreign_tables,
       count(c.oid) filter (where c.relkind = 'i') as indexes,
       pg_size_pretty(coalesce(sum(pg_total_relation_size(c.oid)) filter (where c.relkind in ('r','p','m')), 0)) as total_size
  from pg_namespace n left join pg_class c on c.relnamespace = n.oid
 where n.nspname !~ '^pg_' and n.nspname <> 'information_schema'
 group by n.oid, n.nspname order by n.nspname;
select n.nspname as schema, count(*) as functions
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname !~ '^pg_' and n.nspname <> 'information_schema'
 group by 1 order by 1;

\echo '=== 3. Largest tables (cw, cw_recovery)'
select n.nspname || '.' || c.relname as "table",
       pg_size_pretty(pg_relation_size(c.oid)) as heap,
       pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid) - pg_indexes_size(c.oid)) as toast,
       pg_size_pretty(pg_indexes_size(c.oid)) as indexes,
       c.reltuples::bigint as est_rows
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r','p') and n.nspname in ('cw','cw_recovery')
 order by pg_total_relation_size(c.oid) desc limit 15;

\echo '=== 4. Primary keys / replica identity (logical replication + upsert readiness)'
select n.nspname as schema,
       count(*) as tables,
       count(*) filter (where exists (select 1 from pg_constraint k where k.conrelid = c.oid and k.contype = 'p')) as with_pk,
       count(*) filter (where c.relreplident = 'f') as replident_full,
       count(*) filter (where c.relrowsecurity) as rls_enabled,
       count(*) filter (where c.relkind = 'p') as partitioned,
       count(*) filter (where c.relpersistence = 'u') as unlogged
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r','p') and n.nspname in ('cw','cw_recovery')
 group by 1 order by 1;

\echo '=== 5. Indexes and constraints other than primary keys'
select n.nspname || '.' || c.relname as "table", i.relname as index, pg_size_pretty(pg_relation_size(i.oid)) as size
  from pg_index x join pg_class i on i.oid = x.indexrelid join pg_class c on c.oid = x.indrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname in ('cw','cw_recovery') and not x.indisprimary
 order by 1, 2;
select n.nspname as schema, k.contype, count(*)
  from pg_constraint k join pg_namespace n on n.oid = k.connamespace
 where n.nspname in ('cw','cw_recovery') group by 1, 2 order by 1, 2;

\echo '=== 6. Objects that need superuser or special handling on Supabase'
select 'extension' as kind, extname as name, extversion as detail from pg_extension
union all select 'event_trigger', evtname, evtevent from pg_event_trigger
union all select 'publication', pubname, 'alltables=' || puballtables from pg_publication
union all select 'fdw', fdwname, '' from pg_foreign_data_wrapper
union all select 'foreign_server', srvname, '' from pg_foreign_server
union all select 'tablespace', spcname, '' from pg_tablespace where spcname not in ('pg_default','pg_global')
union all select 'large_objects', count(*)::text, '' from pg_largeobject_metadata having count(*) > 0
union all select 'trigger', tgrelid::regclass::text, tgname from pg_trigger where not tgisinternal
union all select 'language', lanname, '' from pg_language where lanname not in ('internal','c','sql','plpgsql')
union all select 'cast', castsource::regtype || '->' || casttarget::regtype, '' from pg_cast where oid >= 16384
union all select 'user_type', n.nspname || '.' || t.typname, t.typtype::text
  from pg_type t join pg_namespace n on n.oid = t.typnamespace
 where n.nspname in ('cw','cw_recovery') and t.typtype in ('e','d','c','r') and t.typrelid = 0
order by 1, 2;
\echo '--- functions: language, security definer, owner'
select n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as function,
       l.lanname, p.prosecdef as security_definer, pg_get_userbyid(p.proowner) as owner
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang
 where n.nspname in ('cw','cw_recovery') order by 1;
\echo '--- columns with a non-default collation (sort-order risk if the target default differs)'
select n.nspname || '.' || c.relname as "table", a.attname, co.collname
  from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
  join pg_collation co on co.oid = a.attcollation
 where n.nspname in ('cw','cw_recovery') and a.attnum > 0 and not a.attisdropped
   and co.collname not in ('default') order by 1, 2;
\echo '--- column data types in use (portability check)'
select format_type(a.atttypid, null) as type, count(*) as columns
  from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
 where n.nspname in ('cw','cw_recovery') and c.relkind in ('r','p') and a.attnum > 0 and not a.attisdropped
 group by 1 order by 2 desc;

\echo '=== 7. Roles (all non-system) and their attributes'
select rolname, rolcanlogin as login, rolsuper as super, rolcreaterole as createrole,
       rolcreatedb as createdb, rolreplication as replication, rolbypassrls as bypassrls,
       rolinherit as inherit, rolconnlimit as connlimit,
       array_to_string(rolconfig, ', ') as settings
  from pg_roles where rolname !~ '^pg_' order by 1;
\echo '--- per-database role settings'
select coalesce(r.rolname, '(all)') as role, coalesce(d.datname, '(all)') as db,
       array_to_string(s.setconfig, ', ') as settings
  from pg_db_role_setting s left join pg_roles r on r.oid = s.setrole
  left join pg_database d on d.oid = s.setdatabase order by 1, 2;
\echo '--- memberships'
select r.rolname as member, g.rolname as member_of, m.admin_option, m.inherit_option, m.set_option
  from pg_auth_members m join pg_roles r on r.oid = m.member join pg_roles g on g.oid = m.roleid
 where r.rolname !~ '^pg_' order by 1, 2;
\echo '--- role names that COLLIDE with roles Supabase creates and manages (must be renamed, never recreated)'
select rolname as colliding_role
  from pg_roles
 where rolname in ('anon','authenticated','authenticator','service_role','supabase_admin',
                   'supabase_auth_admin','supabase_storage_admin','supabase_functions_admin',
                   'supabase_realtime_admin','supabase_replication_admin','supabase_read_only_user',
                   'supabase_etl_admin','supabase_privileged_role','dashboard_user','pgbouncer',
                   'pgsodium_keyholder','pgsodium_keyiduser','pgsodium_keymaker','pgtle_admin')
 order by 1;

\echo '=== 8. Ownership (what pg_restore --no-owner will flatten to the restoring role)'
select n.nspname as schema, pg_get_userbyid(c.relowner) as owner,
       case c.relkind when 'r' then 'table' when 'p' then 'table' when 'v' then 'view'
                      when 'm' then 'matview' when 'S' then 'sequence' when 'i' then 'index' else c.relkind::text end as kind,
       count(*)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname in ('cw','cw_recovery','public') group by 1, 2, 3 order by 1, 2, 3;

\echo '=== 9. Privileges (effective, per role) and default privileges'
select r.rolname as role, n.nspname as schema,
       has_schema_privilege(r.oid, n.oid, 'USAGE') as usage,
       has_schema_privilege(r.oid, n.oid, 'CREATE') as "create",
       count(c.oid) filter (where has_table_privilege(r.oid, c.oid, 'SELECT')) as select_on,
       count(c.oid) filter (where has_table_privilege(r.oid, c.oid, 'INSERT,UPDATE,DELETE')) as write_on,
       count(c.oid) as relations
  from pg_roles r cross join pg_namespace n
  left join pg_class c on c.relnamespace = n.oid and c.relkind in ('r','p','v','m')
 where r.rolname !~ '^pg_' and n.nspname in ('cw','cw_recovery','public')
 group by r.rolname, r.oid, n.nspname, n.oid order by 1, 2;
select pg_get_userbyid(d.defaclrole) as for_role, coalesce(n.nspname, '(all)') as schema,
       d.defaclobjtype as objtype, d.defaclacl::text as acl
  from pg_default_acl d left join pg_namespace n on n.oid = d.defaclnamespace order by 1, 2, 3;

\echo '=== 10. Replication state (anything that pins WAL or depends on this DB)'
select slot_name, plugin, slot_type, active, database from pg_replication_slots;
select subname, subenabled from pg_subscription;

\echo '=== 11. Who is connected (usernames/apps; addresses may be hidden from non-superusers)'
select usename, application_name, client_addr, backend_type, count(*)
  from pg_stat_activity where datname = current_database()
 group by 1, 2, 3, 4 order by 1, 2;

\echo '=== 12. Write activity on cw (run twice a few minutes apart to gauge the load rate)'
select now() as at,
       sum(n_tup_ins) as ins, sum(n_tup_upd) as upd, sum(n_tup_del) as del,
       sum(n_live_tup) as live_rows, max(last_autovacuum) as last_autovacuum
  from pg_stat_user_tables where schemaname = 'cw';
