# Rollback

**Stage 2 (database) rollback** is in MIGRATION.md §6.5. It depends on how far
the cutover got, and needs loader-offset replay once the new database has
received writes. The rest of this file covers Stage 1 (MCP).

# Stage 1 — Rollback

Stage 1 has **no data to reconcile**: the database is not moved and the MCP is
read-only and stateless. Rolling back only changes which host serves the
`cw-postgres-mcp` Octelium Service.

Rule: only **one** stack serves `cw-postgres-mcp` at a time. Always stop one
before starting the other.

Never use `docker compose down -v`, `docker system prune`, `docker volume prune`,
or touch any non-`cw-mcp` container.

## Path A — old laptop stack still exists and the old token is NOT yet revoked
(any time before DEPLOYMENT.md step 11.2)

1. 🐧 `~/deployments/cw-mcp`:
   ```bash
   docker compose stop
   ```
   Expected: `cw-mcp-octelium`, `cw-mcp-server` stopped (not removed).
2. 🪟 `C:\Users\ReilJakeEngaña\OneDrive - Geidi\Documents\ConnectWise MCP`:
   ```powershell
   docker compose -p connectwisemcp start
   powershell -ExecutionPolicy Bypass -File cw-deployment\scripts\verify-source.ps1
   ```
   Expected: smoke test `RESULT: ALL PASSED`.
3. 🪟 `claude mcp get cw-postgres-mcp` (from `Daily Tasks`) → ✓ Connected.

## Path B — old token already revoked

The old laptop stack can no longer authenticate. Run **this** deployment on the
laptop instead, with the new token, from a folder **outside OneDrive** (so the
secret is never synced):

1. 🐧 `docker compose stop` in `~/deployments/cw-mcp`.
2. 🪟
   ```powershell
   New-Item -ItemType Directory -Force C:\cw-mcp-rollback | Out-Null
   Copy-Item -Recurse -Force "$env:USERPROFILE\OneDrive - Geidi\Documents\ConnectWise MCP\cw-deployment\*" C:\cw-mcp-rollback\
   cd C:\cw-mcp-rollback
   Copy-Item .env.example .env
   # Create secrets\octelium_auth_token containing ONLY the new token (no newline), e.g. with Notepad, then:
   docker compose up -d
   Start-Sleep 60
   Get-Content scripts\mcp_smoke.py -Raw | docker exec -i cw-mcp-server python - --cw
   ```
   Expected: `RESULT: ALL PASSED`. Janus works again via the laptop.

## Re-attempting the server after a rollback

1. 🪟 stop whichever laptop stack is running (`docker compose -p connectwisemcp stop`, or `docker compose stop` in `C:\cw-mcp-rollback`).
2. 🐧 `docker compose up -d && sleep 60 && bash scripts/validate-stack.sh`.

## Fully removing the server stack (only if Stage 1 is abandoned)

🐧 in `~/deployments/cw-mcp`:
```bash
docker compose down        # removes cw-mcp-* containers and cw-mcp-net only; no volumes exist
```
Then ask Ivan to revoke the server credential.
