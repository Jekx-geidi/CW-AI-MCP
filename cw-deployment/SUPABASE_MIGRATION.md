# CW PostgreSQL → Supabase Cloud: migration plan

**Status (2026-10-19): planned and rehearsed on the laptop. Nothing has been
created in Supabase, and nothing on the source, the loader or Octelium has changed.**

This replaces the self-hosted plan (now in `archive/self-hosted-postgres/`). The
14 GB CW mirror moves to a **managed Supabase project**. gc-gei-ollama hosts **only**
the CW MCP and its Octelium sidecar (Stage 1, unchanged). No PostgreSQL container or
data volume is created there.

Related: [SUPABASE_VALIDATION.md](SUPABASE_VALIDATION.md) (validation procedure),
[SUPABASE_SECURITY.md](SUPABASE_SECURITY.md), [SUPABASE_COST.md](SUPABASE_COST.md),
[ROLLBACK.md](ROLLBACK.md), [MIGRATION.md](MIGRATION.md) (program overview and gates).

---

## 1. Target architecture

```
                         ┌──────────────── Supabase Cloud, project "cw-mirror" (ap-southeast-2, Sydney) ────────────────┐
                         │  PostgreSQL 17.11 · schemas cw (108 tables) + cw_recovery (10)                             │
                         │  roles: cw_agent (MCP, read-only) · cw_reader + cw_authenticator (PostgREST) · cw_loader   │
                         │  Network Restrictions: allow-list only · TLS enforced · Data API does NOT expose cw        │
                         └───────▲───────────────────────────▲──────────────────────────────▲─────────────────────────┘
                                 │ TLS verify-full            │ TLS verify-full               │ TLS verify-full
                                 │ user cw_agent (injected)   │ user cw_loader                │ user cw_authenticator
   Octelium Service "cw-postgres"│ (secretless)       JDBC loader (Kafka Connect sink) │   existing PostgREST 14.x
   upstream repointed to Supabase│                    destination URL changed          │   db-uri changed
                                 │
 Janus ─► Octelium Service "cw-postgres-mcp" ─► gc-gei-ollama: cw-mcp-octelium ⇄ cw-mcp-server (postgres-mcp, restricted)
          (unchanged)                            (Stage 1 compose.yaml, unchanged; connects to cw-postgres.default.local.access.geidi.com)
```

What changes for each component:

| Component | Change | Who |
|---|---|---|
| CW MCP (gc-gei-ollama) | **None.** It keeps connecting to the Octelium name `cw-postgres…`; Octelium decides where that goes | — |
| Octelium Service `cw-postgres` | Upstream URL → Supabase, `sslMode: VERIFY_FULL` + Supabase CA, new `cw_agent` password secret, `database: postgres` | Ivan |
| JDBC loader | New destination URL, user `cw_loader`, TLS, password (§7) | Joshua / Paul |
| PostgREST | `db-uri` → Supabase as `cw_authenticator` (was `authenticator`) | Owner of PostgREST |
| Janus | None | — |
| Source cw-postgres | None until decommission. Stays authoritative until cutover is signed off | — |

## 2. Verified current state (2026-10-19)

Read-only audit as `cw_agent` via the laptop Octelium session (`scripts/source-audit.sql`,
output kept outside the repo). Supabase facts from the Supabase docs, the Geidi IT
organisation (read-only listing), and the `supabase/postgres:17.11.0.002` image.

| Area | Source (cw-postgres) | Supabase | Consequence |
|---|---|---|---|
| Version | PostgreSQL **17.11** (Debian) | New projects in org "Geidi IT" are created on **17.11.0.003** (e.g. `wtw-prod`, 2026-10-08) | Same major and minor: plain `pg_dump`/`pg_restore`, no upgrade |
| Size | 14 GB. `SR_Detail` 6.5 GB heap + 0.66 GB TOAST, `SR_Service` 2.6 GB, `Time_Entry` 0.9 GB | Pro: 8 GB disk included; autoscale +50% at 90% full, max 4 resizes per 24 h; read-only at 95% | **Pre-provision 40 GB** before restoring (§3) |
| Schemas | `cw`: 108 tables, 2 views, 16 SQL functions, 108 PK indexes only, no sequences, triggers, FKs or types. `cw_recovery`: 10 tables, no PKs, 408 kB. `public`: empty | Separate namespace; no collision with `public`, `auth`, `storage`… | Dump just `cw` + `cw_recovery` |
| Extensions | `plpgsql` only | Pre-installed (`plpgsql`, `pgcrypto`, `pg_stat_statements`, …) | Nothing to enable |
| Types | text, integer, boolean, timestamp (no tz), numeric, smallint, date, time, **bytea** (10 cols), bigint, float8 | All standard | Portable |
| Collation | libc `en_US.utf8`; 2 columns `COLLATE "C"` (`cw.report_catalog`) | **ICU** `en-US` | Indexes are rebuilt, so nothing breaks; text `ORDER BY` may differ in edge cases. Rehearsal: all row hashes identical |
| Roles | `postgres` (superuser, owns all), `cw_agent` (login, limit 10, `statement_timeout=60s`, `default_transaction_read_only=on`, `search_path=cw, public`, direct SELECT grants), `cw_reader` (nologin, SELECT on cw), **`authenticator`** (login, NOINHERIT, member of `cw_reader` with SET) | **No superuser.** `postgres` is CREATEROLE but not superuser. **`authenticator`, `anon`, `authenticated`, `service_role`, `supabase_*`… are reserved** | **BLOCKER (resolved by design):** source `authenticator` collides and becomes `cw_authenticator`. Roles are recreated, never imported |
| Writers | 5 × `postgres` superuser, "PostgreSQL JDBC Driver" | Customers cannot have a superuser | Loader **must** change user. New least-privilege `cw_loader` (§7) |
| Readers | PostgREST 14.17 (`authenticator`), CW MCP (`cw_agent`, 4 sessions) | — | Both follow the DB (§8, §9) |
| Ownership | Everything owned by `postgres` | `pg_restore --no-owner` → owned by Supabase `postgres` | Same owner name. Verified |
| Default privileges | `postgres` in `cw`: SELECT to `cw_reader`, `cw_agent` | Supabase auto-grants **all** to `anon`/`authenticated`/`service_role` in `public`, `storage`, `graphql` — **not** in new schemas | Re-applied explicitly + defensive revokes (`supabase-grants.sql`) |
| Replication | `wal_level=logical`, no slots, no publications, no subscriptions | Logical replication into Supabase needs the source reachable from Supabase | Not used by default (§6) |
| Network | Behind Octelium; `ssl=off` on the source | Direct endpoint **IPv6 only** unless IPv4 add-on; Shared Pooler IPv4; Network Restrictions apply to direct + pooler, not to HTTPS APIs | Allow-list + TLS (§4) |
| Octelium | MCP reaches `cw-postgres` as `cw_agent` (password injected; user/database forced by the Service) | Octelium POSTGRES Services support public upstreams, `sslMode: VERIFY_FULL`, custom `tls.trustedCAs` | MCP needs no change (§9) |

**Laptop rehearsal (2026-10-19), `supabase/postgres:17.11.0.002` (same image family as the cloud):**
synthetic source with the audited shape (same roles, settings, default privileges, 108+10 tables, views, functions, bytea, `COLLATE "C"`)
→ `source-dump.sh` → `supabase-restore.sh`:

- pre-flight OK; production guard refuses without confirmation; a password in the URL is refused
- roles created with SCRAM verifiers (no plaintext); `cw_agent` logs in with its new password
- `supabase-verify.sql` **22/22 PASS**; inventory **identical** after the documented mappings, including exact row counts and 107 row-content hashes
- one tampered row → comparison reports DIFFERENT (negative test)
- second restore **refused** (never-overwrite guard); roles script re-run is idempotent
- `cw_agent`: UPDATE refused (read-only, and no privilege); no access to `cw_recovery`
- `cw_loader`: upsert + delete OK; `CREATE TABLE` and `cw_recovery` refused
- `anon`, `authenticated`, `service_role`: permission denied on `cw`
- **postgres-mcp 1.6.0 (pinned digest)** against it as `cw_agent`: 9 tools, `SELECT 1`, UPDATE refused, `cw."Company"` = 492 → `RESULT: ALL PASSED`
- **PostgREST** (`cw_authenticator` → `cw_reader`): GET 200, DELETE 401 (permission denied)

Not verifiable from the laptop: the real cloud project (disk, compute, network
restrictions, TLS chain), Octelium → Supabase, the loader, real data volume/timings.

## 3. Blockers and open items

| # | Blocker | Type | Resolution | Owner |
|---|---|---|---|---|
| B1 | Source role `authenticator` collides with Supabase's reserved role | Hard, **verified** | Rename to `cw_authenticator`; PostgREST `db-uri` user changes (§8) | Design ✅ / PostgREST owner |
| B2 | Loader writes as superuser; Supabase has none | Hard, **verified** | New `cw_loader` (DML on cw). Loader config must change (§7) | Joshua / Paul |
| B3 | Loader type, location and config unknown (Kafka Connect JDBC sink is likely, unconfirmed) | Decides method | DISCOVERY.md B3 (updated) | Joshua / Paul |
| B4 | Egress IPs of the Octelium cluster gateway, loader host and PostgREST host, and whether they have IPv6 | Decides network design | Needed for Network Restrictions and the IPv4 add-on decision (§4) | Ivan |
| B5 | **Data governance:** the CW mirror holds customer PII (contacts, ticket notes, time entries, billing). Moving it to a third-party cloud needs explicit approval. Pro plan has no SOC 2 report access (Team plan) | Approval | Paul decides; region `ap-southeast-2` keeps data in Australia (SUPABASE_SECURITY.md §1) | Paul |
| B6 | Compromised Octelium token (laptop `cw-postgres-mcp` workload) | Security, urgent | Mint new credential → deploy Stage 1 → **revoke old the same day** (SUPABASE_SECURITY.md §5) | Ivan |
| B7 | Budget + project creation (Supabase org Owner/Admin) | Approval | ≈ USD 68/month steady state (SUPABASE_COST.md) | Paul |
| B8 | Octelium: can the cluster gateway reach a public upstream with `VERIFY_FULL` + custom CA? Does `cw-postgres` use `dynamicConfig` today? | Technical | Ivan confirms; test on a **separate** Service first (§6.1 R6) | Ivan |
| B9 | MCP concurrency: 1 of 3 parallel smoke sessions timed out (laptop, 2026-10-19) | Open risk | Re-measure on Supabase (SUPABASE_VALIDATION.md V-S12) | Reil |

## 4. Decisions

Each: **decision — why — implications — rollback.**

**D1. One dedicated production project, `cw-mirror`, in org "Geidi IT", region `ap-southeast-2` (Sydney); plus a temporary rehearsal project `cw-mirror-rehearsal`.**
Why: a dedicated project isolates compute, disk, connections, backups and access from the
30+ other Geidi projects, and Sydney keeps the data in Australia with the lowest latency from
Perth/AU hosts. A region cannot be changed after creation. A separate rehearsal project
is used instead of Supabase branching because branches are created from migrations, not
from 14 GB of data. — Implications: one more project to administer; org members with
Owner/Admin can see it (SUPABASE_SECURITY.md §4). — Rollback: delete the project
(irreversible, including its backups; only after the source is confirmed authoritative).

**D2. Compute: Large during restore and validation, then Medium for steady state.**
Why: Medium (4 GB RAM, 120 direct connections) is the closest to the source's measured
envelope (1 GB shared_buffers, 40 connections) with headroom for a 14 GB working set. Large
(2 dedicated vCPUs, 8 GB, 594 MB/s burst) shortens the restore and the analyze; Supabase
recommends upgrading compute for imports above 6 GB. — Implications: each compute change
has < 2 min downtime, so resize **before** cutover, never after. Small (2 GB, shared CPU,
22 MB/s baseline) would throttle full scans of `SR_Detail`. — Rollback: compute can be
changed either way at any time (hourly billing).

**D3. Disk: pre-provision 40 GB gp3 (default 3,000 IOPS).**
Why: 14 GB data plus restore WAL and temp would trigger repeated autoscaling during the
import, and 4 resizes per 24 h could push the project into read-only mid-restore. 40 GB = 35%
used now, about 70% after a year at 100% growth, then autoscaling takes over. — Implications:
disk **cannot be shrunk**, so do not over-provision; about 4 h cooldown after a manual change.
— Rollback: none needed (cost about USD 4/month).

**D4. Connections: direct connection with TLS `verify-full`; IPv4 add-on only if a client lacks IPv6.**
Why: `pg_restore`, `vacuumdb` and the JDBC sink need session features (startup `PGOPTIONS`,
prepared statements); the transaction pooler (6543) does not support prepared statements, so
it is **forbidden** for the loader and the restore (pre-flight rejects 6543). The direct
endpoint is IPv6-only; if the Octelium gateway or the loader host is IPv4-only (B4), either
add the IPv4 add-on (USD 4/month, dedicated static IPv4, only IPv4 CIDRs needed in Network
Restrictions) or use the Shared Pooler session mode (`aws-0-ap-southeast-2.pooler.supabase.com:5432`,
user `<role>.<project-ref>`). **Recommendation: the IPv4 add-on.** It keeps one endpoint and one
allow-list. — Implications: enabling the add-on swaps the DNS record (under 1 min blip): do it
before any client connects. — Rollback: disable the add-on; clients must then use IPv6 or the pooler.

**D5. Roles are recreated, never imported; every login gets a new password.**
Why: Supabase reserves `authenticator` and forbids superuser attributes, and `pg_dumpall
--globals-only` would carry password hashes off the source. `supabase-roles.sql` creates
exactly `cw_reader`, `cw_agent`, `cw_authenticator`, `cw_loader` with the audited attributes
and settings, and sets passwords as **SCRAM verifiers** computed locally
(`scram-verifier.py`). Plaintext never reaches the server, its logs or `pgaudit`. — Implications:
every consumer gets a new credential (Octelium secret, loader, PostgREST); old credentials keep
working against the source, which makes rollback clean. Supabase daily backups do **not**
keep custom-role passwords: after a backup restore, re-run `supabase-roles.sql` with the
passwords. — Rollback: consumers point back to the source with their old credentials.

**D6. Dump only `cw` + `cw_recovery`, with `--no-owner --no-privileges`; grants re-applied explicitly.**
Why: this is Supabase's own recommendation. It avoids ownership and ACL statements that a
non-superuser cannot run, and every privilege that exists afterwards is written down in
`supabase-grants.sql` and verified by `supabase-verify.sql`. — Implications: none for
behaviour; verified identical effective grants. — Rollback: n/a (source untouched).

**D7. `cw_loader` gets DML on `cw` only: no DDL, no `cw_recovery`.**
Why: least privilege, which replaces superuser writes (B2). — Implications: if the sink
relies on schema evolution (`auto.create`/`auto.evolve`, Debezium `schema.evolution=basic`),
it will fail on a new CW column. Decide after B3: either keep evolution off and apply DDL
manually (recommended: the schema has been stable), or grant `CREATE` on schema `cw` and make
`cw_loader` the table owner (explicit change, documented). — Rollback: grants are
idempotent SQL.

**D8. Cutover method: B (parallel sink) if the loader is a Kafka Connect upsert sink; otherwise A (pause, dump, restore).** See §6.
Why B: the source keeps receiving writes the whole time and stays authoritative. Supabase
catches up from Kafka, readers move with one Octelium repoint, and rollback is "repoint back"
with **no data replay**. Why A as fallback: simplest and fully deterministic, at the cost of a
write freeze (~1–2 h, measured in rehearsal) and a replay-based rollback once Supabase has
taken writes.

**D9. Octelium: repoint the existing Service `cw-postgres` to Supabase (O1). Fallback O2: serve it via a connector.**
O1: the Octelium cluster gateway connects to Supabase's public endpoint directly (pattern
documented by Octelium for managed Postgres such as Neon). Every consumer of the
`cw-postgres…` name follows with one change; rollback is the same change back. O2: if the
gateway cannot egress to Supabase or has no stable IP, add `octelium connect --serve
cw-postgres` as a sidecar on a host with a fixed egress IP. — Implications of O2: a third
container on gc-gei-ollama, and DB access depends on that host; avoid unless O1 is impossible.
— MCP: unchanged in both.

**D10. PostgREST: keep the existing PostgREST and repoint it (P1). Do not switch consumers to Supabase's Data API now (P2).**
Why: P1 is proven in rehearsal (`cw_authenticator` → `cw_reader`); consumers keep the same URL,
JWTs and behaviour. Only `db-uri` changes. P2 would change URLs, require the `apikey` header,
need consumer JWTs signed with the Supabase project's keys, and expose `cw` through
Supabase's API gateway: a consumer-facing migration that is out of scope. — Rollback: revert
`db-uri`.

**D11. Supabase Data API: `cw` is never exposed.** `supabase-grants.sql` revokes everything
from `anon`/`authenticated`/`service_role` on `cw`/`cw_recovery` (verified), and `cw` is
not added to "Exposed schemas". Recommended: also turn off the Data API for this project if
nothing uses it (SUPABASE_SECURITY.md §3).

**D12. Backups: Supabase daily physical backups (7 days, included). No PITR at first.**
Why: the mirror is rebuildable (Kafka replay / ConnectWise re-snapshot) and the source is kept
during the soak, so PITR (USD 100/month) buys little. — Implications: worst case RPO 24 h from
Supabase backups, or near-zero via loader replay. Revisit if Supabase becomes the only copy of
anything. Optional monthly off-platform logical backup: `scripts/supabase-backup.sh`. — Rollback: n/a.

**D13. The source stays authoritative until sign-off.** Nothing on the source is changed,
paused or deleted except the loader pause in Method A. Decommission needs ≥ 7 days stable,
one tested Supabase backup restore, and Paul's sign-off.

## 5. Where the restore runs

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Source host** (owner runs dump + restore, same tmux session) | Dump never leaves the source network; no transfer; one allow-list entry (temporary) | Owner needs the Supabase `postgres` password and egress to Supabase | ✅ **Preferred** |
| Transient `postgres:17.11` client container on gc-gei-ollama | Reil can run it | 4–7 GB dump on a host whose Docker disk is 90% full; extra transfer; conflicts with "only MCP + Octelium there" | Only with Paul's OK |
| Reil's laptop | Convenient | Home/office uplink for 4–7 GB; laptop sleep; PII on a laptop | ❌ |

Requirements for the runner: PostgreSQL 17 client (`psql`, `pg_dump`, `pg_restore`, `vacuumdb`), `python3`, `sha256sum`, free disk ≥ 50% of the DB (≈ 7 GB), its egress IP in the project's Network Restrictions for the duration, and `tmux`.

## 6. Procedures

Legend: 🧪 no production impact · 🔶 production change (gate G5 approval) · 👤 owner · 🧑‍💻 Reil · 🔐 Ivan

### 6.1 Rehearsal (non-production project) 🧪

| # | Who | Step | Check |
|---|---|---|---|
| R1 | Paul | Approve B5 (data governance) and B7 (budget). Confirm region `ap-southeast-2` | written OK |
| R2 | Paul / org admin | Create project **`cw-mirror-rehearsal`**, org Geidi IT, region `ap-southeast-2`, Postgres 17, strong generated DB password → Bitwarden "cw-mirror-rehearsal postgres" | project ACTIVE_HEALTHY |
| R3 | Org admin | Settings → Compute and Disk: **Large**, disk **40 GB**. Add-ons: IPv4 (if D4 needs it). Database → SSL: **Enforce SSL**, download the CA certificate. Network Restrictions: **only** the restore runner's egress IP. Data API: do not expose `cw` | dashboard shows Large / 40 GB / restrictions applied |
| R4 | 👤 | On the source host: `bash scripts/source-dump.sh` (no FINAL, off-hours, loader running) | `cw-<ts>.dump` + checksums; record dump time/size |
| R5 | 👤 | Same host: create `secrets/cw_{agent,authenticator,loader}_password` (mode 600, ≥ 24 chars, generated, **rehearsal-only** values); then `TARGET_ENV=rehearsal PROJECT_REF=<ref> TARGET_URL=… bash scripts/supabase-restore.sh <ts>` | `PRE-FLIGHT: OK`, `VERIFY: OK`, `INVENTORY: IDENTICAL`; record restore + analyze time |
| R6 | 🔐 | Create a **separate test Service** `cw-postgres-supabase-test` (POSTGRES mode, upstream = rehearsal project, `user: cw_agent`, `database: postgres`, `sslMode: VERIFY_FULL`, `tls.trustedCAs` = Supabase CA, password secret = rehearsal `cw_agent`). Grant `cw-data-readers`. **Do not touch `cw-postgres`.** Add the gateway egress IP(s) to the rehearsal allow-list | `psql` via Octelium works |
| R7 | 🧑‍💻 | Laptop: run postgres-mcp against the test Service and the smoke test (SUPABASE_VALIDATION.md V-S8) | `RESULT: ALL PASSED` |
| R8 | 👤 | If Method B: start a **test** sink connector writing to the rehearsal project with offsets from `dump_started_utc` − 10 min (new consumer group); watch lag reach 0 | lag 0; spot-check rows |
| R9 | 🧑‍💻 | SUPABASE_VALIDATION.md in full; update timings in this file (§10) and costs | all PASS |
| R10 | Org admin | After production cutover is signed off: delete the test connector, the test Octelium Service, and the rehearsal project | — |

### 6.2 Production — Method B (parallel sink, preferred) 🔶

Preconditions: gates G1–G8 green (MIGRATION.md §0); rehearsal passed; loader confirmed as
a Kafka Connect sink with upsert by PK, `delete.enabled` (or equivalent) known, topic
retention ≥ 2× (dump + restore time).

| # | Who | Step | Check |
|---|---|---|---|
| P1 | Org admin | Create **`cw-mirror`** exactly like R2/R3 (Large, 40 GB, SSL enforced, IPv4 per D4, restrictions = restore runner only) | — |
| P2 | 👤 | `bash scripts/source-dump.sh` (no FINAL; loader keeps running) | note `dump_started_utc` (T0) |
| P3 | 👤 | Production secrets (new generated passwords: `cw_agent`, `cw_authenticator`, `cw_loader`) → Bitwarden; `TARGET_ENV=production CONFIRM_PRODUCTION_RESTORE=<ref> … supabase-restore.sh <ts>` | `RESTORE: OK` (rows differ slightly: expected, the loader is live) |
| P4 | 👤 | Create sink connector **`cw-supabase-sink`** (new consumer group, same topics, §7 config) with offsets reset to **T0 − 10 min**; add the Connect host's IP to Network Restrictions | consumer lag → 0; `max("Last_Update_UTC")` on Supabase advances |
| P5 | 👤 + 🧑‍💻 | **Convergence check:** pause **both** sinks when both lags are 0 → `FINAL=1` inventories on source and Supabase → `compare-inventory.sh` → resume both. (Pause ~10–20 min; no data is lost, Kafka buffers) | `INVENTORY: IDENTICAL` incl. counts + hashes |
| P6 | Org admin | Compute → **Medium** (downtime < 2 min; readers still on source) | project healthy |
| P7 | 🔐 | Add gateway egress IP to the allow-list; **repoint `cw-postgres`** upstream → Supabase (`VERIFY_FULL`, CA, new `cw_agent` secret, `database: postgres`). Keep the old config saved for rollback | from the MCP netns: `select inet_server_addr(), current_setting('server_version')` → Supabase |
| P8 | PostgREST owner | `db-uri` → Supabase as `cw_authenticator` (TLS); restart | PostgREST GET OK |
| P9 | 🧑‍💻 | SUPABASE_VALIDATION.md V-S8…V-S12 (MCP through Janus, PostgREST, freshness) | all PASS |
| P10 | All | **Soak ≥ 7 days.** Both sinks keep running: the source stays current and remains the rollback target | daily freshness check |
| P11 | Paul | Sign-off → stop the old sink; source set read-only and kept ≥ 30 days; remove the restore runner from the allow-list; delete dumps | — |

Write freeze in Method B: **none** for the loader. The only pause is P5 (both sinks paused
together for an exact comparison).

### 6.3 Production — Method A (pause, dump, restore) 🔶 — fallback

| # | Who | Step | Check |
|---|---|---|---|
| A1 | Paul | Announce the window: the mirror is frozen for rehearsal time + 30 min | — |
| A2 | Org admin | Project ready as in P1 | — |
| A3 | 👤 | **Write freeze:** pause the loader (`PUT /connectors/<name>/pause`). Verify quiescence: run `select sum(n_tup_ins+n_tup_upd+n_tup_del) from pg_stat_user_tables where schemaname='cw'` twice, 2 min apart → equal | counters equal |
| A4 | 👤 | `FINAL=1 bash scripts/source-dump.sh` | `rows|` and `hash|` lines present |
| A5 | 👤 | `FINAL=1 TARGET_ENV=production CONFIRM_PRODUCTION_RESTORE=<ref> … supabase-restore.sh <ts>` | `RESTORE: OK`, inventory **identical** incl. counts + hashes |
| A6 | Org admin | Compute → Medium | healthy |
| A7 | 🔐 / PostgREST owner | Repoint Octelium `cw-postgres` (P7) and PostgREST (P8) | as P7/P8 |
| A8 | 👤 | Change the loader destination to Supabase (§7) → **resume** | `max("Last_Update_UTC")` advances on Supabase |
| A9 | 🧑‍💻 | SUPABASE_VALIDATION.md | all PASS |
| A10 | All | Soak ≥ 7 days; source untouched (now stale, but intact) | — |

### 6.4 Final synchronisation and validation

The cutover is accepted only when SUPABASE_VALIDATION.md passes, specifically:
inventory identical (structure, grants, exact counts, content hashes) at a quiescent point;
`supabase-verify.sql` all PASS; MCP smoke through Janus; PostgREST read; loader freshness on
Supabase; no other consumer still writing to or reading from the source (`pg_stat_activity`
on the source shows only expected sessions).

### 6.5 Rollback → [ROLLBACK.md](ROLLBACK.md) Part 2.

## 7. JDBC loader: required destination changes

Identified from the source: 5 sessions as `postgres`, application "PostgreSQL JDBC Driver",
continuous upserts (`Last_Update` within minutes). Lineage notes: `cw-ai-data-platform`
(Paul) with Debezium, so most likely a **Kafka Connect JDBC sink** (Confluent or Debezium).
**Unconfirmed: DISCOVERY.md B3.**

| Setting | Today (presumed) | On Supabase |
|---|---|---|
| Host | Docker network / IP of the source host | `db.<ref>.supabase.co:5432` (direct; IPv4 add-on if IPv4-only), or session pooler `aws-0-ap-southeast-2.pooler.supabase.com:5432`. **Never 6543** (no prepared statements in transaction mode) |
| Database | `postgres` | `postgres` |
| User | `postgres` (superuser) | `cw_loader` (pooler: `cw_loader.<ref>`) |
| Password | source superuser | new, generated; stored in the Connect secret provider, never inline |
| TLS | none (`ssl=off` on source) | `sslmode=verify-full&sslrootcert=<Supabase CA path>` |
| Schema evolution | ? | **off** (`auto.create=false`, `auto.evolve=false` / Debezium `schema.evolution=none`) unless D7 decides otherwise |
| Network | local | Connect worker egress IP in Supabase Network Restrictions |
| Latency | local | ~50 ms RTT Perth→Sydney: keep batching (`batch.size`) as is; watch consumer lag in rehearsal |

Template (Confluent JDBC sink property names; Debezium uses `connection.username`):

```properties
connection.url=jdbc:postgresql://db.<ref>.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=/etc/kafka/secrets/supabase-ca.crt&ApplicationName=cw-supabase-sink&tcpKeepAlive=true
connection.user=cw_loader
connection.password=${file:/etc/kafka/secrets/cw-supabase.properties:password}
insert.mode=upsert
auto.create=false
auto.evolve=false
```

Connections: the loader uses 5 today; `cw_loader` is capped at 15; Medium allows 120 direct.

## 8. PostgREST

Today: PostgREST 14.17 → `authenticator` → `SET ROLE cw_reader`. On Supabase: same
PostgREST, `db-uri=postgres://cw_authenticator:<pw>@db.<ref>.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=…`,
`db-schemas=cw`, anon/JWT role `cw_reader` unchanged. Rehearsed: reads work, writes denied.
Its host's egress IP goes in the allow-list. Unknown: where it runs and who calls it (DISCOVERY.md B4).

## 9. Octelium routing and authentication

| Item | Requirement |
|---|---|
| Service | `cw-postgres` (existing), mode POSTGRES. **Only its upstream config changes** at P7/A7 |
| Upstream | `url: postgres://db.<ref>.supabase.co:5432` (or the pooler host with `user: cw_agent.<ref>`) |
| Forced identity | `postgres.user: cw_agent`, `postgres.database: postgres` (Octelium forces both; this is why the MCP URL's `/cw` database name is ignored today) |
| Secret | New Octelium Secret holding the **new** `cw_agent` password (`octeliumctl create secret --file …`). Keep the old secret for rollback |
| TLS | `sslMode: VERIFY_FULL`, `tls.trustedCAs: [<Supabase CA PEM>]` (Supabase's server certificate chains to Supabase's own CA, downloadable in Database settings) |
| Egress | Gateway egress IP(s) in Supabase Network Restrictions **before** the repoint (else the MCP loses the DB) |
| Authorization | Unchanged: workload `cw-postgres-mcp` → group `cw-data-readers` → Service `cw-postgres` |
| MCP | **No change.** `CW_POSTGRES_URL=postgresql://cw_agent@cw-postgres.default.local.access.geidi.com:5432/cw` stays; postgres-mcp never sees a password |
| Test first | R6: separate Service `cw-postgres-supabase-test`; production Service untouched until P7 |
| Compromised token | The laptop workload token must be replaced **before** any of this (B6); the Supabase project trusts whoever Octelium lets through as `cw_agent` |

## 10. Timings and sizes (fill in from the rehearsal)

| Metric | Estimate | Rehearsal (real) |
|---|---|---|
| Dump size (`-Z 6`) | 4–7 GB | |
| Dump time | 10–20 min | |
| Restore + analyze (Large, `JOBS=2`) | 20–40 min (Supabase guide: ~15 min per 10 GB; `SR_Detail` is one table, so parallelism helps little) | |
| Supabase DB size after restore | ~14 GB | |
| Method A freeze (dump + restore + checks) | 1–1.5 h | |
| Method B catch-up from T0 | minutes | |
