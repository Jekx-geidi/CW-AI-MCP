# CW on Supabase: security, retention, network access, credentials, recovery

Scope: the `cw-mirror` Supabase project (and its temporary rehearsal twin), the CW MCP
on gc-gei-ollama, and the Octelium path between them.

## 1. Data and its classification

| Data | Content | Sensitivity |
|---|---|---|
| `cw` (108 tables, 14 GB) | ConnectWise mirror: companies, contacts, service tickets with notes (`SR_Detail` 12 M rows), time entries, schedules, products, purchase orders, billing logs, commissions (`cw.sales_commission`) | **Confidential, contains personal information** (customer contacts, free-text ticket notes) |
| `cw_recovery` (10 tables) | Recovery copies, no PKs, 408 kB | Confidential, owner-only |

**Approval required (blocker B5).** Moving this to a third-party cloud is a data-governance
decision for Paul:
- **Region `ap-southeast-2` (Sydney, AWS)** keeps the data stored in Australia. Supabase
  (US company) staff and support tooling may still access it under Supabase's terms.
- The Pro plan does not include access to Supabase's SOC 2 report (Team plan does). If a
  customer contract or internal policy requires vendor attestation, that decides the plan.
- The org "Geidi IT" already runs 30+ projects on Supabase, so the vendor is not new; this
  dataset is more sensitive than most.

## 2. Network access

| Control | Setting | Why | Rollback |
|---|---|---|---|
| **Network Restrictions** (Postgres + pooler) | Allow-list only: Octelium gateway egress IP(s) (or the O2 connector host), loader (Kafka Connect) host, PostgREST host, and the restore runner **only during the migration** | Credentials alone are not enough; an attacker also needs one of these IPs. Applies to direct and pooled connections | `update --db-allow-cidr` with the previous list (the CLI/API replaces the whole list, so always send the full list) |
| IPv4 vs IPv6 | If the IPv4 add-on is enabled: IPv4 CIDRs only. Without it: **both** IPv4 (pooler) and IPv6 (direct) CIDRs must be listed | Supabase documents this; a missing family silently leaves a path open or closed | — |
| **TLS** | "Enforce SSL" on; every client uses `sslmode=verify-full` + the Supabase CA (Octelium: `VERIFY_FULL` + `tls.trustedCAs`) | Today the source runs `ssl=off`; the new path crosses the public internet | Never disable |
| Data API (HTTPS) | `cw` never exposed; recommended: Data API **disabled** for this project | Network Restrictions do **not** cover HTTPS APIs; defence in depth on top of the revokes | Re-enable in settings |
| Anon/auth roles | `supabase-grants.sql` revokes `anon`, `authenticated`, `service_role`, `PUBLIC` on `cw`/`cw_recovery`; `supabase-verify.sql` proves it | Supabase auto-grants these roles everything in `public`; we never use `public` | — |
| gc-gei-ollama | No host ports; MCP reachable only via Octelium `cw-postgres-mcp` (Stage 1) | Unchanged | — |

Keep a list of the allow-listed IPs and their owners in the Plane ticket. Remove the restore
runner's IP at P11.

## 3. Identities and least privilege

| Identity | Used by | Can | Cannot |
|---|---|---|---|
| `postgres` (Supabase) | Admins, restore runner, backups | Everything Supabase allows a non-superuser | Superuser actions; never given to a service |
| `cw_agent` | CW MCP via Octelium (password injected by Octelium) | SELECT on 110 `cw` relations; 60 s timeout; read-only transactions; 10 connections | Write anything; read `cw_recovery`; DDL |
| `cw_reader` (nologin) | Target role for PostgREST | SELECT on `cw` | Log in |
| `cw_authenticator` | PostgREST | Log in and `SET ROLE cw_reader` | Read anything itself (NOINHERIT) |
| `cw_loader` | JDBC sink | INSERT/UPDATE/DELETE/SELECT on `cw` tables | DDL; `cw_recovery`; 15 connections max |
| Octelium workload `cw-postgres-mcp` | MCP sidecar on gc-gei-ollama | Serve `cw-postgres-mcp`; reach `cw-postgres` (group `cw-data-readers`) | — |
| Supabase org members (Owner/Admin/Developer) | Dashboard, SQL editor | See and query **all** projects in the org at their role level | — |

Actions:
- Review the Geidi IT org member list before the restore: anyone with Developer or higher can
  open this project's SQL editor. If that is too broad, use a separate org for `cw-mirror`
  (another Pro plan fee; see SUPABASE_COST.md) or Supabase project-scoped access, if the plan
  supports it.
- The Supabase connector used by Claude sessions has org-wide rights. Use it only for
  read-only listing and docs; never point it at `cw-mirror` data without an explicit, confirmed step.

## 4. Credentials: inventory and rotation

All secrets live in Bitwarden (team vault) and in the consuming system's secret store, never in
Git, OneDrive, chat, `.env` files or command lines. Passwords are ≥ 32 random characters.

| Credential | Stored in | Rotation trigger / interval | How (no downtime) |
|---|---|---|---|
| **Octelium workload token `cw-postgres-mcp` (laptop) — COMPROMISED** | laptop OneDrive `.env` | **Now** (§5) | New credential → Stage 1 deploy → revoke old the same day |
| Octelium workload token (gc-gei-ollama) | `secrets/octelium_auth_token` on the server, mode 600 | 12 months, staff change, or suspicion | DEPLOYMENT.md "Rotate token" |
| Supabase `postgres` password | Bitwarden | **After the migration** (the restore runner and owners knew it); then 12 months | Dashboard → Database settings → reset (Supabase-managed services update automatically) |
| `cw_agent` password | Octelium Secret only | 12 months / suspicion | New verifier via `supabase-roles.sql` → `octeliumctl` update of the Secret. Brief failures until both match; do it in a quiet hour |
| `cw_authenticator` password | PostgREST config secret | 12 months | Same pattern; restart PostgREST |
| `cw_loader` password | Kafka Connect secret provider | 12 months | Same pattern; restart the connector task |
| Supabase CA certificate | Octelium Service, loader, PostgREST, runner | When Supabase announces a CA change | Add the new CA alongside the old, then remove the old |
| Supabase personal access tokens / API keys | Individuals / not used | Revoke unused; the Data API keys are not used by CW | Dashboard |

Rotation procedure for a CW role password (example `cw_loader`):
```bash
umask 077; openssl rand -base64 36 | tr -d '\n' > secrets/cw_loader_password
psql "$TARGET_URL" -X -v ON_ERROR_STOP=1 \
  -v cw_loader_verifier="$(python3 -I scripts/scram-verifier.py < secrets/cw_loader_password)" \
  -f scripts/supabase-roles.sql
# update the consumer's secret, restart it, confirm it reconnects, then shred the file
shred -u secrets/cw_loader_password
```

Supabase daily backups do not keep custom-role passwords: after any backup restore, re-run
`supabase-roles.sql` with the current passwords (§6).

## 5. The compromised Octelium token

Facts: the laptop stack passes `OCTELIUM_AUTH_TOKEN` on the container command line (visible in
`docker inspect`/`ps`), it sits in a OneDrive-synced `.env`, and it appeared in a Claude Code
session transcript. Whoever holds it can join the mesh as `cw-postgres-mcp`, read the whole
CW mirror as `cw_agent`, and impersonate the MCP for Janus.

| Step | Who | When |
|---|---|---|
| 1. Mint a **new** credential for workload `cw-postgres-mcp` (same user/group/Service) | Ivan | Now |
| 2. Deploy Stage 1 on gc-gei-ollama with it (DEPLOYMENT.md Part A) | Reil | As soon as 1 is done |
| 3. **Revoke the old credential the same day** V7 (Janus) passes. Do not wait for the soak: rollback Path B (ROLLBACK.md) works with the new token | Ivan | Same day |
| 4. Review Octelium audit logs for sessions of `cw-postgres-mcp` from unexpected IPs since 2026-09-15 | Ivan | With step 3 |
| 5. Remove `OCTELIUM_AUTH_TOKEN` from the OneDrive `.env`; `docker compose -p connectwisemcp down` on the laptop | Reil | After step 3 |
| 6. If step 4 shows misuse: treat CW data as exposed. Paul decides on notification; rotate `cw_agent` on the source too | Paul / Ivan | If needed |

Until step 3, the migration must not widen what this token can reach. The Supabase rehearsal
uses a **separate test Service** (R6), and the production repoint (P7) happens only after revocation.

## 6. Backups, retention, recovery

| Layer | What | Retention | RPO | RTO |
|---|---|---|---|---|
| Supabase daily physical backups (Pro, included) | Whole project | 7 days | ≤ 24 h | Project offline during restore; ~tens of minutes for 14 GB (measure once) |
| Loader replay (Kafka) | All CW changes still in topic retention | Topic `retention.ms` (DISCOVERY B3.3) | ~0 | Reset sink offsets; minutes–hours |
| Full re-snapshot from ConnectWise | Everything | n/a | 0 | Hours (owner to estimate, DISCOVERY B3.5) |
| Source cw-postgres (until decommission) | Whole mirror | ≥ 7 days soak + 30 days read-only | Method B: 0 | Octelium repoint back: minutes |
| Optional off-platform logical backup (`supabase-backup.sh`, `age`-encrypted) | `cw`, `cw_recovery` | 3 local / per agreed target | ≤ 1 month (monthly) | Restore into a new project: ~1 h |
| PITR (add-on) | — | not enabled (D12) | would be 2 min | — |

Recovery runbook (Supabase-side loss or corruption):
1. Decide: Supabase backup restore (whole project, ≤ 24 h loss) vs loader replay vs ConnectWise
   re-snapshot. For a mirror, **replay is usually best**.
2. Supabase backup restore: Dashboard → Database → Backups → restore (project offline). Then
   **re-run `supabase-roles.sql` with the current passwords** (backups drop custom-role
   passwords), then `supabase-verify.sql`, then reset the sink offsets to the backup time and let it catch up.
3. Validate with SUPABASE_VALIDATION.md V-S5, V-S8, V-S11.

Retention of migration artefacts: dumps, `inventory-*`, `cw-*.meta` contain CW data or its
fingerprints. Keep them on the runner only, mode 600, and delete them at P11 (`shred -u`). The
source DB is decommissioned only with Paul's sign-off; deleting the source's data is the owner's
decision and is not part of this plan.

## 7. Logging and monitoring

- Supabase keeps API and database logs for 7 days (Pro). `pgaudit` is available. Do not enable
  statement logging for `cw_agent` (query text can contain customer data).
- Watch (weekly, then monthly): disk usage (alert before 80%: autoscale happens at 90%),
  connections by role, `cw_loader` lag (V-S11 query), failed logins in the Postgres logs, and
  the Network Restrictions list.
- `pg_stat_statements` is available on Supabase (it was not on the source), so the MCP's
  `get_top_queries` now returns data. It shows query text by role to Supabase admins.
