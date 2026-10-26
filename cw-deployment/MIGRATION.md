# CW PostgreSQL + CW MCP → gc-gei-ollama — migration plan

Scope (agreed in meeting): **both** CW PostgreSQL and CW MCP end up on
gc-gei-ollama. Delivered in two stages that share one integrated sequence (§7):

- **Stage 1 — CW MCP**: artifacts ready (`compose.yaml`, DEPLOYMENT.md). Not deployed.
- **Stage 2 — CW PostgreSQL**: configuration and scripts ready (`db/`, `scripts/`),
  rehearsed on the laptop. **Restore is blocked** by the gates in §0.

## 0. Gates — nothing touches production data until all are green

| Gate | Condition | Status |
|---|---|---|
| G1 Host & owners | Current host, loader, PostgREST identified (DISCOVERY.md B1–B4) | 🔴 open |
| G2 Ingestion continuity | Loader can pause/resume without loss, or replication path agreed (§5) | 🔴 open |
| G3 Storage | Dedicated ≥ 100 GB disk mounted at `/srv/cw-postgres` (§3) | 🔴 open — `/var/lib/docker` has 31 GB free (90% used) |
| G4 Memory | Swap confirmed stale, not active (DISCOVERY.md A1) | 🟡 to verify |
| G5 Approval | Paul approves cutover window; Ivan approves Octelium changes | 🔴 open |
| G6 Backups | Off-host backup target agreed (DISCOVERY.md B5.4) | 🔴 open |
| G7 Rehearsal | Full-data rehearsal restore passes inventory diff (§6.2) | 🔴 open (schema-only rehearsal ✅) |

## 1. Verified facts (read-only, as `cw_agent`, 2026-10-19)

| Area | Finding | Consequence |
|---|---|---|
| Engine | PostgreSQL **17.11** (Debian 17.11-1.pgdg13+2), single DB `postgres` | Target uses the identical image; no version upgrade |
| Size | 14 GB: 13 GB table+TOAST, 1.36 GB indexes. `SR_Detail` 7.6 GB, `SR_Service` 2.7 GB | Drives storage plan (§3) |
| Schema | `cw`: 108 tables (**all have PKs**), 108 indexes (= the PKs), 16 SQL functions, 2 views, no triggers, sequences or identity columns. `cw_recovery`: 10 tables, no PKs, 408 kB. Extensions: `plpgsql` only | Simple, portable schema; logical replication feasible for `cw` |
| Roles | `postgres` (superuser, owns all), `cw_agent` (read-only, 60s, conn limit 10), `cw_reader` (NOLOGIN; SELECT on `cw`), `authenticator` (member of `cw_reader`) | Globals must be migrated with password hashes (Octelium injects `cw_agent`'s password) |
| Privileges | `cw_agent` can read `cw` but **not** `cw_recovery`; cannot dump roles | Final dump must be run by a superuser on the source (§4 D3) |
| Settings | `wal_level=logical`, `max_wal_senders=10`, `max_replication_slots=10`, `max_connections=40`, `shared_buffers=1GB`, `effective_cache_size=3GB`, `work_mem=8MB`, `maintenance_work_mem=256MB`, checksums **off**, `ssl=off`, encoding UTF8 `en_US.utf8` | Target starts at parity (+checksums) |
| Writers | 5 × `postgres` via **PostgreSQL JDBC Driver**; `SR_Service.Last_Update` within minutes of now; no replication slots/publications | Live, continuously loaded mirror |
| Readers | **PostgREST 14.17** (`authenticator`), CW MCP (`cw_agent`) | Both must follow the database |
| Host | Docker bridge `172.18.0.2:5432` on a host behind Octelium Service `cw-postgres`; not seen on gc-gei-ollama yet | DISCOVERY.md A3/B1 to confirm |
| Lineage | Notes: the mirror is the "ConnectWise AI data platform replica" (`cw-ai-data-platform`, owner Paul), which uses **Debezium** | Loader is very likely a Kafka Connect JDBC sink — **unconfirmed** (B3) |

**Schema-only rehearsal (laptop, 2026-10-19):** dump `cw` as `cw_agent` (25 s, 244 kB)
→ restore into `postgres:17.11` with data checksums → inventory diff vs source:
**identical** (108 tables, 108 column sets, 108 indexes, 108 constraints, 16 functions,
2 views, grants). **Script rehearsal:** `source-dump.sh` → `restore.sh` end-to-end
against a simulated source: checksums OK, globals applied without touching the new
superuser, parallel restore, exact row counts identical, `cw_agent` logs in with its
migrated password, second restore **refused** (never-overwrite guard).

## 2. Discovery still required

See **DISCOVERY.md** — Part A for Reil on gc-gei-ollama, Part B for the source
owners. Owners: Ivan (host, Octelium), Paul (data platform, approvals),
Joshua (mirror/loader), Evgeny (disks, backups).

## 3. Capacity assessment for gc-gei-ollama

### 3.1 Server facts (Reil, 2026-10-19)

16 CPUs · 31 GiB RAM, **14 GiB available** · swap 8 GiB, **almost fully used** ·
`/` 196 GB, 84 GB free · `/var/lib/docker` 298 GB, **31 GB free (90% used)** ·
`/dev/net/tun` present · listeners already on 5432, 5433, 8000.

### 3.2 Storage needed for CW PostgreSQL

| Component | Size | Basis |
|---|---:|---|
| Live data (tables + indexes) | 14 GB | measured |
| Growth reserve, 12 months | 14 GB | provisional 100% until growth is measured (B2, 7-day delta); SR_* tables grow continuously |
| WAL | 12 GB | `max_wal_size=4GB` + `max_slot_wal_keep_size=8GB` cap (worst case with an abandoned slot) |
| Local backups | 21 GB | 3 × ~7 GB custom-format dumps (conservative: 50% of DB; real ratio measured at rehearsal) |
| Temp files (sorts, index builds) | 2 GB | largest index ≈ several hundred MB; generous |
| **Steady-state total** | **63 GB** | |
| Migration staging (dump + globals + TOC) | +7 GB | removed after cutover; overlaps backup space before backups start |
| Restore WAL burst / index-build temp | within WAL + temp above | bounded by `max_wal_size` |
| Free-space margin (keep filesystem ≤ 80% full) | ÷ 0.8 | |
| **Required dedicated capacity** | **≈ 80 GB → provision 100 GB** | |
| Bare minimum (no growth reserve, 1 local backup, off-host copies immediately) | ≈ 44 GB | not recommended |

### 3.3 Where to put it — recommendation

| Option | Free now | After steady state (63 GB) | Verdict |
|---|---:|---:|---|
| Docker volume on `/var/lib/docker` | 31 GB | does not fit | ❌ Already 90% full; filling it risks **every** container on the host |
| Bind on `/` | 84 GB | 175/196 GB = **89%** | ❌ Breaches the 80% margin; OS and logs share it |
| **Dedicated virtual disk, 100 GB, ext4/xfs at `/srv/cw-postgres`** | 100 GB | 63% | ✅ **Recommended** |

**Reasoning:** gc-gei-ollama is a VM (GreenCloud/VMware), so adding a virtual disk
is routine for Evgeny/Ivan and isolates CW growth from Ollama/Supabase/Langfuse.
The compose file uses a **named volume bound to `/srv/cw-postgres/data`**, which
keeps the "named volume" model while keeping data off the full Docker disk.

**Risk flagged to owners (not ours to fix):** `/var/lib/docker` at 90% is already a
risk for all current workloads. Stage 1 adds ~0.5 GB of images and ≤ 100 MB of
logs; `postgres:17.11` adds 0.65 GB. Do **not** prune anything to make room —
ask the owners.

### 3.4 Memory and CPU

| Workload | Measured | Limit | Notes |
|---|---|---|---|
| CW MCP `postgres-mcp` | 113–115 MiB, <7% CPU | 512 MiB, 1 CPU, no swap | laptop stack, idle + 3 parallel sessions |
| CW MCP `octelium` | 29 MiB, <0.1% CPU | 256 MiB, 0.5 CPU, no swap | |
| CW PostgreSQL | — (not yet running) | 6 GiB, 4 CPU, no swap | 1 GiB shared_buffers + 40 × 8 MB work_mem + 256 MB maintenance + page cache; parity with source |
| DB Octelium sidecar | ~29 MiB expected | 256 MiB | |

Stage 1 fits easily: ceilings total 768 MiB vs 14 GiB available (measured
peak 144 MiB). Stage 2 adds up to ~6.3 GiB, leaving ~7 GiB available —
acceptable **only if** the full swap is stale (DISCOVERY.md A1). If the host is
actively swapping, the database must not be added until memory is freed or
the VM gets more RAM. All CW containers set `memswap_limit = memory`, so they
can never add to swap.

## 4. Architecture decisions

Each: **decision — reasoning — risk / mitigation.**

**D1. Same PostgreSQL build (17.11, Debian) pinned by digest.**
Same major and minor means plain `pg_dump`/`pg_restore` with no upgrade
step and no behaviour change; Debian (glibc) matches the source's
`en_US.utf8` collation. — Risk: none new; minor upgrades later go through
the normal rehearsal.

**D2. Cutover method: logical dump/restore with the loader paused for the final sync.**
Simplest method that is fully reversible: the source is never modified,
the result is verified by an exact inventory diff, and it is rehearsed
first. — Risk: the loader is paused for dump + transfer + restore
(estimate 1–2 h; measured in rehearsal). Mitigation: Kafka-style loaders
buffer during the pause (B3.4). **Fallback if the window is too long:**
logical replication. It is already feasible: `wal_level=logical`, all 108
`cw` tables have PKs, `max_wal_senders=10`. `cw_recovery` (static, no
PKs, 408 kB) would be copied once by dump. Not the default, because it
requires a publication and a replication login on the source.

**D3. The final dump is taken by the source owner, as superuser, on the source host.**
`cw_agent` cannot read `cw_recovery` or dump roles (verified). Dumping
locally is fastest and puts the least load on the network. `source-dump.sh`
validates the archive, writes checksums and an inventory. — Risk: depends
on owner availability. Mitigation: everything is scripted, so they run one
command.

**D4. Roles migrated with their password hashes (`pg_dumpall --globals-only`).**
Octelium injects `cw_agent`'s real password, and PostgREST uses
`authenticator`'s, so keeping the hashes means no credential changes
anywhere. Rehearsed: `cw_agent` logs in with its migrated password. —
Risk: the globals file contains SCRAM hashes, so treat it as a secret
(mode 600, never in Git, delete after cutover).

**D5. No host port; serve the existing Octelium Service `cw-postgres` from gc-gei-ollama.**
Every consumer keeps the same hostname
(`cw-postgres.default.local.access.geidi.com`). The switch is a single
Octelium repoint (Ivan), and rollback is the same repoint back. It also
removes the need for TLS/pg_hba exposure on the host. — Risk: depends on
how Ivan serves Services (B1). The `db/compose.yaml` sidecar (profile
`serve`) implements the `--serve` pattern already proven by the MCP.

**D6. CW MCP keeps connecting through the Octelium hostname, not the Docker network.**
After D5 the MCP follows the database automatically, with zero MCP
changes at DB cutover, so there is one switch point for both stages. —
Trade-off: an extra hop instead of local Docker networking. Revisit after
cutover (a direct connection would need `cw_agent`'s password as a
secret).

**D7. Data on a dedicated 100 GB disk, named volume bound to it.** See §3.3.

**D8. Data checksums ON in the new cluster (source has them off).**
Detects storage corruption. It costs a few percent of CPU, and the host
has 16 cores. It is invisible to clients. — Risk: none for compatibility,
because checksums are physical, not logical.

**D9. Settings at parity, plus guardrails.**
Parity avoids behaviour changes: `max_connections=40` (a JDBC connection
leak has already exhausted this once, D-16 notes). Additions:
`max_wal_size=4GB`, `max_slot_wal_keep_size=8GB` (an abandoned
replication slot can never fill the disk), `idle_in_transaction_session_timeout=15min`,
slow-query and connection logging. `wal_level=logical` is kept because a
CDC consumer may depend on it (B5.2).

**D10. Least-privilege loader role: AFTER cutover, not during.**
The loader writing as superuser is a real risk, but changing credentials
and destination in the same window doubles what can go wrong. Do it as a
follow-up change once the move is stable.

**D11. Stage 1 (MCP) deploys first.**
It is independent of the database (it uses the same Octelium hostname),
removes the laptop dependency now, and proves the Octelium `--serve`
pattern on gc-gei-ollama before the database depends on it.

## 5. Ingestion: move the loader, or only change its destination?

**Recommendation: do NOT move the loader. Change only its destination, and
preferably not even that, via D5.**

| If discovery (B3) shows… | Then | Why |
|---|---|---|
| Loader connects via the **Octelium hostname** | **No loader change at all.** Pause → cutover → Octelium repoint → resume | Single switch point; nothing to reconfigure |
| Loader connects via **IP / Docker network / localhost** on the old host | **Change `connection.url`** to the Octelium hostname (or gc-gei-ollama's address) during the pause | The loader's state (Kafka offsets, topics) lives with Kafka, not with the DB; moving Kafka/Connect is a separate, larger migration |
| Loader is **bundled in the same compose project** as the DB and cannot reach a remote DB | Move it **as a second step** after the DB is stable, with the platform owner | Moving the pipeline and the store at once multiplies risk |

**Continuity reasoning (to confirm in B3):** a Kafka Connect JDBC sink commits
consumer-group offsets in Kafka. If it is **paused** before the final dump, the
dump equals exactly the state at the committed offset; after restore and
repoint, it resumes from that offset with **no loss and no duplicates**. Upsert
mode by PK (all 108 tables have PKs) also makes replays idempotent, which is
the safety net for rollback (§6.5).

**PostgREST:** stateless. Same rule — if it uses the Octelium hostname, nothing
changes; otherwise update `db-uri` during the window. Co-locate it on
gc-gei-ollama only if it is in the same compose project as the DB today (B4.2).

## 6. Procedures

Legend: 🧪 preparation (no production impact) · 🔶 production change (needs G5 approval).
Commands for Reil are in DEPLOYMENT.md Part B; owner commands in DISCOVERY.md.

### 6.1 Preparation 🧪

1. DISCOVERY.md Part A (Reil) and Part B (owners) answered → gates G1, G2, G4.
2. Evgeny/Ivan add a 100 GB disk, mounted at `/srv/cw-postgres` and owned by `reil` (G3). This is an infra change, but no data changes.
3. Off-host backup target and encryption agreed (G6).
4. `db/.env`, `db/secrets/cw_pg_superuser_password` created on the server; `docker compose pull` in `db/`.

### 6.2 Full-data rehearsal 🧪 (source is only read)

1. Owner runs `source-dump.sh` **without** pausing the loader, off-hours (it reads 14 GB from the live mirror).
2. Transfer to `/srv/cw-postgres/dumps`, then run `sha256sum -c`.
3. Reil: `docker compose up -d` in `db/` (no `serve` profile, so nothing is exposed) → `restore.sh <ts>`.
4. Compare inventories. Structure must be identical; row counts will differ slightly (the loader was live).
5. Record: dump time, transfer time, restore time, dump size, final DB size. These replace the estimates in §3.2 and give the real pause length for D2.
6. Run the Stage 1 smoke test against it from inside the network (optional).
7. **Discard the rehearsal cluster** (only CW-owned, new resources): `docker compose down` in `db/`, then remove `/srv/cw-postgres/data/*`. This is the only deletion in the plan, scoped to the rehearsal data on the new disk.

### 6.3 Final sync and cutover 🔶

| # | Who | Step | Check |
|---|---|---|---|
| C1 | Paul | Announce window (mirror stale for ~rehearsal time + 30 min) | — |
| C2 | Owner | **Pause loader** (e.g. `PUT /connectors/<name>/pause`) | Write counters stop: run the query below twice, 2 min apart — values equal |
| C3 | Owner | `FINAL=1 source-dump.sh` on source | Exits OK; `inventory-source` has `rows|` lines |
| C4 | Owner/Reil | Transfer to `/srv/cw-postgres/dumps` | `sha256sum -c` all OK |
| C5 | Reil | `db/`: `docker compose up -d` (fresh, empty data dir), then `FINAL=1 restore.sh <ts>` | Script OK; inventory diff **identical** incl. row counts |
| C6 | Ivan | Stop serving `cw-postgres` from the old host; Reil: `docker compose --profile serve up -d` in `db/` (or Ivan repoints upstream) | From gc-gei-ollama MCP netns: `select inet_server_addr()` shows the new container |
| C7 | Owner | Update loader / PostgREST destination **only if** they don't use the Octelium name (§5); **resume loader** | `max("Last_Update_UTC")` advances on the NEW DB within minutes |
| C8 | Reil | `bash scripts/validate-stack.sh` (MCP) + PostgREST spot check + Janus query | All pass |
| C9 | Owner | Old DB: leave running, loader detached; do **not** delete | — |
| C10 | Reil | Enable `db-backup.sh` cron; first backup + test restore into a scratch container | Restore OK |

Write-quiescence check (C2), as any role with stats access (`cw_agent` works):
```sql
select sum(n_tup_ins + n_tup_upd + n_tup_del) from pg_stat_user_tables where schemaname = 'cw';
```

### 6.4 Validation criteria

- Inventory diff source vs destination: **identical**, including exact row counts and max `Last_Update_UTC` per table (at the paused point).
- `cw_agent`: logs in through Octelium; read-only; `statement_timeout=60s`; connection limit 10.
- MCP smoke (`--cw`): 9 tools, `SELECT 1`, UPDATE refused, Company count > 0.
- Loader writing to new DB (C7), PostgREST responding, Janus query OK.
- `data_checksums=on`; no host port; neighbours unaffected (VALIDATION.md V11).

### 6.5 Rollback

| When | Action | Data reconciliation |
|---|---|---|
| Before C6 | Stop/discard new cluster; resume loader on old | None — old DB never stopped being authoritative |
| After C6, before C7 | Ivan repoints Octelium back; resume loader on old | None — nothing wrote to the new DB |
| After C7 (loader writing to new) | Pause loader → repoint Octelium/loader back → **replay** changes since cutover into the old DB: reset the sink's consumer offsets to the C2 timestamp (idempotent upserts by PK) → resume | Requires Kafka retention ≥ time since cutover (B3.3). If the loader is not Kafka-based or retention is too short, use a full re-snapshot from ConnectWise (B3.5) |
| Point of no return | Old DB decommissioned — only after ≥ 7 days stable, ≥ 1 verified backup restore on the new host, and Paul's sign-off | — |

### 6.6 Backups, monitoring and operations (after cutover)

- **Backups:** `scripts/db-backup.sh` nightly. Custom-format dump, archive check, sha256, 3 local copies, optional `age` encryption and rsync off-host (G6). **Monthly restore test** into a scratch container plus inventory diff.
- **Retention (proposal):** 7 daily, 4 weekly, 3 monthly off-host; 3 local.
- **Health:** container healthcheck (`pg_isready`), `restart: unless-stopped`, logs rotated (10 MB × 5), slow queries > 5 s logged.
- **Watch:** disk `df -h /srv/cw-postgres` (alert at 80%), `pg_database_size`, WAL dir size, `docker stats cw-postgres`, swap activity (`vmstat`).
- **Credential rotation:** superuser password via `ALTER ROLE` + secret file; Octelium tokens re-minted by Ivan; `cw_agent` and `authenticator` rotation coordinated with Octelium and PostgREST config.

## 7. Integrated deployment sequence (MCP + DB)

| Phase | Type | What | Depends on |
|---|---|---|---|
| P0 | 🧪 | DISCOVERY.md Part A (Reil) + Part B (owners) | — |
| P1 | 🔶 | **Stage 1: deploy CW MCP** on gc-gei-ollama (DEPLOYMENT.md Part A) | new Octelium token, Paul OK |
| P2 | 🧪 | Dedicated 100 GB disk at `/srv/cw-postgres` | Evgeny/Ivan |
| P3 | 🧪 | Prepare `db/` on server, pull image (DEPLOYMENT.md Part B, steps B1–B4) | P2 |
| P4 | 🧪 | Full-data rehearsal (§6.2) → real timings; discard rehearsal | P3, owner runs dump |
| P5 | 🔶 | DB cutover C1–C10 (§6.3). MCP needs **no change** (D6) | G1–G7 green |
| P6 | 🔶 | Backups live, 7-day soak, then decommission old DB (Paul) | P5 |
| P7 | 🔶 | Follow-ups: least-privilege loader role (D10); optional direct MCP→DB path (D6) | P6 |

## 8. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Docker disk (90%) fills, affecting all workloads | Medium (already high) | High | CW data on dedicated disk; flag to owners; no prune |
| Host actively swapping → DB degrades neighbours | Unknown (A1) | High | Gate G4; `memswap_limit`; 6 GiB cap |
| Loader cannot pause without loss | Unknown (B3) | High | Gate G2; logical-replication fallback (D2) |
| Unknown consumer still pointed at old host | Medium | Medium | B2 `pg_stat_activity` survey; old DB kept running (C9) |
| Pause longer than planned | Medium | Low–Medium | Rehearsal timings; replication fallback |
| Globals file (hashes) leaks | Low | High | Mode 600, never in Git/OneDrive, deleted after cutover |
| Octelium serve/repoint misconfigured | Medium | Medium | Rollback = repoint back; validated with `inet_server_addr()` |
| MCP concurrency: 1 of 3 parallel smoke sessions timed out on `SELECT 1` (laptop, 2026-10-19) | Observed once | Medium | Investigate before wide rollout (postgres-mcp pool / Octelium path); VALIDATION.md V12 |
| Restore over an existing DB | Low | High | `restore.sh` refuses if any CW relation exists (tested) |
