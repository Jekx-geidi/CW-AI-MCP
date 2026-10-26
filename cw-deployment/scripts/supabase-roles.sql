-- Create the CW roles on a Supabase project. Run as "postgres" BEFORE the restore.
-- Idempotent: re-running only updates attributes, settings and (if given) passwords.
--
--   psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 \
--        -v cw_agent_verifier="$(python3 -I scripts/scram-verifier.py < secrets/cw_agent_password)" \
--        [-v cw_authenticator_verifier=...] [-v cw_loader_verifier=...] \
--        -f scripts/supabase-roles.sql
--
-- Passwords are passed as SCRAM verifiers, never plaintext. A role whose verifier is
-- not supplied is created without a password (it cannot log in until one is set).
--
-- Mapping from the source (audit 2026-10-19):
--   cw_reader      NOLOGIN, SELECT on cw                      -> same
--   cw_agent       LOGIN, conn limit 10, 60 s, read-only      -> same (+ new password)
--   authenticator  PostgREST login, NOINHERIT, SET cw_reader  -> cw_authenticator
--                  ("authenticator" is RESERVED by Supabase for its own Data API:
--                   never CREATE/ALTER/DROP it)
--   postgres       superuser, JDBC loader                     -> cw_loader (new,
--                  least privilege; Supabase has no superuser for customers)
--
-- Never touches Supabase-managed roles (anon, authenticated, authenticator,
-- service_role, supabase_*, dashboard_user, pgbouncer, ...).

\set ON_ERROR_STOP 1
set statement_timeout = '30s';

-- Guard: must be a Supabase project, connected as postgres, PostgreSQL 17.
select (current_user = 'postgres') as is_postgres,
       exists (select 1 from pg_roles where rolname = 'supabase_admin') as is_supabase,
       current_setting('server_version_num')::int / 10000 = 17 as is_pg17
\gset
\if :is_postgres
\else
  \echo 'STOP: connect as postgres'
  \quit 1
\endif
\if :is_supabase
\else
  \echo 'STOP: target is not a Supabase project (no supabase_admin role)'
  \quit 1
\endif
\if :is_pg17
\else
  \echo 'STOP: target is not PostgreSQL 17'
  \quit 1
\endif

select format('create role %I', r) from unnest(array['cw_reader','cw_agent','cw_authenticator','cw_loader']) r
 where not exists (select 1 from pg_roles where rolname = r)
\gexec

-- Attributes (explicit, so a re-run converges)
alter role cw_reader        nologin inherit;
alter role cw_agent         login   inherit   connection limit 10;
alter role cw_authenticator login   noinherit connection limit -1;  -- parity with source
alter role cw_loader        login   inherit   connection limit 15;

-- cw_agent behaviour, identical to the source
alter role cw_agent set statement_timeout = '60s';
alter role cw_agent set default_transaction_read_only = on;
alter role cw_agent set search_path = cw, public;
-- Loader sessions should never hang on an idle transaction
alter role cw_loader set idle_in_transaction_session_timeout = '15min';

-- PostgREST pattern from the source: authenticator may SET ROLE cw_reader, does not inherit it
select 'grant cw_reader to cw_authenticator with inherit false, set true'
 where not pg_has_role('cw_authenticator', 'cw_reader', 'MEMBER')
\gexec

-- Passwords (SCRAM verifiers)
\if :{?cw_agent_verifier}
  alter role cw_agent password :'cw_agent_verifier';
  \echo 'cw_agent password set'
\endif
\if :{?cw_authenticator_verifier}
  alter role cw_authenticator password :'cw_authenticator_verifier';
  \echo 'cw_authenticator password set'
\endif
\if :{?cw_loader_verifier}
  alter role cw_loader password :'cw_loader_verifier';
  \echo 'cw_loader password set'
\endif

select rolname, rolcanlogin as login, rolinherit as inherit, rolconnlimit as connlimit,
       array_to_string(rolconfig, ', ') as settings
  from pg_roles where rolname in ('cw_reader','cw_agent','cw_authenticator','cw_loader') order by 1;
