# Source → Supabase migration validation procedure

Run in full on the **rehearsal** project (SUPABASE_MIGRATION.md §6.1 R9) and again on
**production** at cutover (§6.2 P5/P9 or §6.3 A5/A9). Cutover is accepted only if every
check marked **gate** passes. Record the outputs (sanitised) on the Plane ticket.

All checks are read-only, except V-S5's write test (it runs inside a transaction that is
rolled back) and V-S13 (rehearsal project only).

## Inputs

| Item | Where |
|---|---|
| `inventory-source-<ts>.txt`, `cw-<ts>.meta` | `source-dump.sh` output (with `FINAL=1` for the exact comparison) |
| `inventory-dest-<ts>.txt` | `supabase-restore.sh` output, or re-run `db-inventory.sql` on Supabase |
| `TARGET_URL` + `PGPASSWORD` | Supabase `postgres` (from Bitwarden; never on the command line) |
| Laptop Octelium session | for V-S8 via the test Service (rehearsal) or `cw-postgres` (production) |

## Checks

| # | Check | How | Pass criteria | Gate |
|---|---|---|---|---|
| V-S1 | Target pre-flight | `bash scripts/supabase-preflight.sh` (before restore) | `PRE-FLIGHT: OK`; TLS in use; `verify-full`; server 17; target empty; port ≠ 6543 | gate |
| V-S2 | Dump integrity | `sha256sum -c cw-<ts>.sha256`; `pg_restore --list` | all `OK`; TOC has 2 SCHEMA, 118 TABLE, 118 TABLE DATA, 108 CONSTRAINT, 16 FUNCTION, 2 VIEW, and **no** ACL/OWNER entries | gate |
| V-S3 | Structure + grants | `bash scripts/compare-inventory.sh inventory-source-<ts>.txt inventory-dest-<ts>.txt` | `INVENTORY: IDENTICAL (after documented mappings)`; `plpgsql: present` | gate |
| V-S4 | Exact data | Same comparison with `FINAL=1` inventories taken at a **quiescent point** (Method A: loader paused; Method B: both sinks paused at lag 0) | identical `rows|` lines (count + max `Last_Update_UTC` for all 118 tables) and `hash|` lines (row-content md5 for every cw table < 64 MB) | gate |
| V-S5 | Security posture | `psql "$TARGET_URL" -X -A -t -q -f scripts/supabase-verify.sql` | every line `PASS` (22 checks: role attributes, cw_agent read-only/60 s/limit 10, no cw_recovery access, loader DML-only, no anon/authenticated/service_role/authenticator access, reserved roles untouched) | gate |
| V-S6 | Supabase project settings | Dashboard (screenshot or note) | Region `ap-southeast-2`; SSL **enforced**; Network Restrictions **applied** and listing only the agreed IPs; `cw` **not** in Data API exposed schemas (or Data API off); compute/disk as planned | gate |
| V-S7 | Logins work only as designed | As each role (passwords from Bitwarden, via `PGPASSWORD`): `cw_agent` → `select count(*) from cw."Company"` OK; `begin read write; update cw."Company" set "Company_Name"="Company_Name" where false; rollback;` → **permission denied**; `cw_loader` → `create table cw.x(i int)` → **permission denied**; any login from an IP **not** in the allow-list → connection refused | as stated | gate |
| V-S8 | MCP end-to-end through Octelium | Rehearsal: on the laptop, a temporary postgres-mcp pointed at `cw-postgres-supabase-test` (R6) + `mcp_smoke.py --cw`. Production: `bash scripts/validate-stack.sh` on gc-gei-ollama after P7 | `RESULT: ALL PASSED`: **9 tools** (analyze_db_health, analyze_query_indexes, analyze_workload_indexes, execute_sql, explain_query, get_object_details, get_top_queries, list_objects, list_schemas), `SELECT 1`, **UPDATE refused**, session user `cw_agent`, Company count > 0 | gate |
| V-S9 | DB identity behind the Octelium name | From the MCP netns: `psql "postgresql://cw_agent@cw-postgres.default.local.access.geidi.com:5432/cw" -XAtc "select current_user, current_database(), current_setting('server_version'), exists(select 1 from pg_roles where rolname='supabase_admin')"` | `cw_agent|postgres|17.11…|t` (production: only after P7) | gate |
| V-S10 | Through Janus | Laptop, `Daily Tasks` folder: `claude mcp get cw-postgres-mcp`; ask *"Using cw-postgres-mcp, how many rows are in cw.Company?"* | ✓ Connected; a number matching V-S4 (± live drift) | gate |
| V-S11 | Freshness (loader) | On Supabase as `postgres`: `select max("Last_Update_UTC") from cw."SR_Service"` now and again after 15 min; compare with the source | advances; lag vs source ≤ the agreed staleness (DISCOVERY B5.5) | gate |
| V-S12 | Concurrency (open risk B9) | 3 parallel `mcp_smoke.py --cw` runs | all 3 `ALL PASSED`; if a timeout repeats, record it and investigate before wider rollout | record |
| V-S13 | Remaining MCP tools exercised | Rehearsal only: through the MCP call `list_schemas`, `list_objects` (cw), `get_object_details` (cw.Company), `explain_query`, `get_top_queries`, `analyze_db_health` | each returns without error; `get_top_queries` works (Supabase has `pg_stat_statements`, the source did not) | record |
| V-S14 | Collation impact | `select "Description" from cw.report_catalog order by "Description" limit 50` on both sides; and one `ORDER BY` on a non-C text column of a small table | identical (C-collated columns must match exactly; differences on ICU vs libc columns are recorded, not blocking) | record |
| V-S15 | PostgREST | Through the existing PostgREST after P8: one GET per consumer endpoint actually used; one write attempt | GET 200 with data; write denied | gate |
| V-S16 | Nothing still uses the source | On the source (owner): `select usename, application_name, client_addr, count(*) from pg_stat_activity where datname='postgres' group by 1,2,3` | Method B: only the old sink (until P11). Method A: no `cw_agent`/`authenticator` sessions after the repoint | gate |
| V-S17 | Neighbours unaffected | gc-gei-ollama: VALIDATION.md V11 | only `cw-mcp-*` changed | gate |
| V-S18 | Backups exist | Dashboard → Database → Backups after the first night | one daily backup listed | after 24 h |

## Expected, documented differences (not failures)

| Difference | Why |
|---|---|
| Role `authenticator` (source) = `cw_authenticator` (Supabase) | Supabase reserves `authenticator` |
| `cw_loader` exists only on Supabase | New least-privilege writer (D7) |
| Extra extensions on Supabase (`pgcrypto`, `pg_stat_statements`, `supabase_vault`, `uuid-ossp`, …) | Pre-installed by Supabase; only the source's `plpgsql` must be present |
| Database collation `en_US.UTF-8` (ICU) vs `en_US.utf8` (libc) | Supabase default; indexes rebuilt on restore |
| Objects owned by Supabase's non-superuser `postgres` | `--no-owner`; same role name |
| Row counts differ in a non-quiescent (Method B pre-convergence) comparison | Loader is live; only V-S4 at a quiescent point is the gate |

## Sign-off record

| Field | Value |
|---|---|
| Project ref / region | |
| Dump ts / method (A/B) | |
| V-S1…V-S18 results | |
| Dump / restore / freeze durations | |
| Signed off by (Paul) / date | |

## 7. Monthly backup restore test (after cutover)

Restore the latest `supabase-backup.sh` dump (or a Supabase "restore to new project") into the
rehearsal project or a local `supabase/postgres:17.11` container with `supabase-restore.sh`
(`TARGET_ENV=rehearsal`), then V-S3 and V-S5. Record the date and result.
