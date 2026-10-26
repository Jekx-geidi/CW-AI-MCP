# CW MCP — server deployment (gc-gei-ollama)

Moves the CW MCP off Reil's laptop onto the always-on GEIDI Docker host
`gc-gei-ollama`, in two stages:

| Stage | Scope | Status |
|---|---|---|
| **1** | CW MCP (`postgres-mcp`) + Octelium sidecar → gc-gei-ollama. Keeps using the existing live `cw-postgres` mirror through Octelium. | Artifacts ready, **not deployed** |
| **2** | 14 GB `cw-postgres` (PG 17.11) → gc-gei-ollama; JDBC loader + PostgREST follow it, mirror kept in sync | Config + scripts prepared and rehearsed on the laptop (`db/`, `scripts/`). **Restore blocked** by gates in [MIGRATION.md](MIGRATION.md) §0: host/loader discovery, dedicated disk, swap check, approvals |

Start with **[DISCOVERY.md](DISCOVERY.md)** (read-only checks), then
[MIGRATION.md](MIGRATION.md) (plan, capacity, decisions), then
[DEPLOYMENT.md](DEPLOYMENT.md) (manual commands).

## What Stage 1 deploys

```
Janus (janus.scale.au/cw-postgres-mcp)
  → Octelium Service "cw-postgres-mcp"        (unchanged, host-independent)
    → cw-mcp-octelium  (octelium connect --serve cw-postgres-mcp)
        shared network namespace
      → cw-mcp-server  (postgres-mcp 1.6.0, SSE :8000, restricted mode)
        → cw-postgres.default.local.access.geidi.com:5432 (live mirror, via Octelium)
```

Same design and same images as the working laptop stack (`../docker-compose.yml`),
so tool behaviour is unchanged. Differences, all deliberate:

| Change | Why |
|---|---|
| Images pinned by digest (`octelium` 0.42.0, `postgres-mcp` 1.6.0) | Exactly what was tested; `latest` could change under us |
| **No host ports** | Janus reaches the MCP through the Octelium Service. The laptop's `0.0.0.0:8000` publish exposed an unauthenticated SQL endpoint to the LAN and is not needed |
| Octelium token from `secrets/octelium_auth_token` → process env | Laptop compose interpolated the token into the container command (visible in `docker inspect` and host `ps`). Now it is in neither |
| **New** Octelium credential | The laptop token was exposed (see Security). It is not reused |
| `postgres-mcp` hardened: `cap_drop: ALL`, read-only root FS, `no-new-privileges`, PID/CPU/memory limits | Shared server |
| Unique names: project `cw-mcp`, containers `cw-mcp-octelium` / `cw-mcp-server`, network `cw-mcp-net` | No collision with other workloads |
| Log rotation (10 MB × 5) | Disk safety on a shared host |

No custom application code: `postgres-mcp` is the upstream image, so there is
no Dockerfile to maintain.

## Files

| File | Purpose |
|---|---|
| `compose.yaml` | Stage 1 stack |
| `.env.example` | Non-secret config (copy to `.env` on the server) |
| `secrets/octelium_auth_token` | **Created on the server only**, mode 600, never in Git/OneDrive |
| `DEPLOYMENT.md` | Manual execution checklist (PowerShell + PuTTY, step by step) |
| `VALIDATION.md` | What "working" means, with the laptop baseline |
| `ROLLBACK.md` | How to go back to the laptop stack |
| `MIGRATION.md` | Stage 2 discovery plan (database) |
| `scripts/verify-destination.sh` | Server pre-flight (read-only) |
| `scripts/validate-stack.sh` | Server post-deploy validation |
| `scripts/mcp_smoke.py` | MCP end-to-end test (stdlib only; runs inside the container) |
| `scripts/verify-source.ps1` | Laptop-side state check |
| `DISCOVERY.md` | Read-only checks for gc-gei-ollama (Reil) and the source host (owners) |
| `db/compose.yaml` | Stage 2: `cw-postgres` (17.11, pinned) + Octelium sidecar (profile `serve`). **Not deployed** |
| `db/.env.example` | Stage 2 non-secret config (`CW_PG_ROOT` = dedicated disk) |
| `scripts/db-inventory.sql` | Deterministic structure (+ optional exact row count) inventory; diff source vs destination |
| `scripts/source-dump.sh` | Run by the source owner: globals + `pg_dump -Fc` + TOC check + checksums + inventory |
| `scripts/restore.sh` | Restore into the new, empty cluster only (refuses to overwrite) + analyze + inventory |
| `scripts/db-backup.sh` | Nightly backup after cutover (local + optional encrypted off-host) |

## Verified locally (2026-10-19)

- Laptop baseline via `mcp_smoke.py --cw`: postgres-mcp **1.6.0**, **9 tools**,
  `SELECT 1` OK, `UPDATE` refused, session user `cw_agent`, `cw."Company"` = 492 rows.
- `postgres-mcp` with this compose's hardening (cap_drop ALL, read-only FS,
  tmpfs /tmp, limits) starts, passes the healthcheck and the full smoke test.
- The Octelium sidecar from this exact compose file reads the token from the
  secret file into its environment; the token is absent from `docker inspect`
  and from the rendered compose config. (Tested offline with a fake token.)
- `docker compose config` renders with no published ports; scripts pass `bash -n`.

Not verifiable from the laptop: anything on gc-gei-ollama, the new Octelium
credential, whether Octelium allows two concurrent sessions of the workload.

## Security notes

- The current laptop Octelium token was exposed via `docker inspect` (and in a
  Claude Code session transcript). Ivan should mint a new credential for the
  server and revoke the old one at cutover. See DEPLOYMENT.md §0.
- The laptop `.env` sits in a OneDrive-synced folder. Do not create
  `secrets/` inside OneDrive; for a laptop rollback use a non-synced copy
  (ROLLBACK.md).
- Docker group membership on the server is root-equivalent; anyone in it can
  read the token from the container. Keep the group small.

## Operations (Stage 1)

The MCP is stateless — nothing to back up except this directory's config and
the secret (which Ivan can re-issue).

| Task | Command (Ubuntu, in the deployment dir) |
|---|---|
| Status | `docker compose ps` |
| Logs | `docker compose logs --tail 100 postgres-mcp` / `octelium-connect` |
| Resource use | `docker stats --no-stream cw-mcp-octelium cw-mcp-server` |
| Full check | `bash scripts/validate-stack.sh` |
| Restart | `docker compose restart` |
| Rotate token | Write the new token to `secrets/octelium_auth_token` (see DEPLOYMENT.md step 5), then `docker compose up -d --force-recreate octelium-connect postgres-mcp`; Ivan revokes the old one |

Restart behaviour: both containers `restart: unless-stopped`, so they come back
after a server reboot. Known Docker caveat with `network_mode: service:` — if the
sidecar restarts on its own, `cw-mcp-server` can keep a stale network namespace.
Symptom: validation fails "connected to cw-postgres"/smoke test while both
containers show running. Fix: `docker compose up -d --force-recreate postgres-mcp`.
VALIDATION.md includes a test for this.
