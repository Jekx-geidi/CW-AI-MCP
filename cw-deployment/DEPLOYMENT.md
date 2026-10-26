# Manual execution checklist

- **Part A — Stage 1: CW MCP** (ready to execute once §0 is green)
- **Part B — Stage 2 preparation: CW PostgreSQL** (preparation only; cutover is MIGRATION.md §6.3)
- Read-only discovery that comes first: **DISCOVERY.md**

Every server command is run **by Reil, manually, in PuTTY**. Claude does not
SSH or deploy. Paste sanitized output back after each step marked 📋.

## Capacity check for Stage 1 (measured, 2026-10-19)

| | Measured (laptop stack) | Limit in `compose.yaml` | Server has |
|---|---|---|---|
| RAM | 113–115 MiB + 29 MiB | 512 MiB + 256 MiB, **no swap** (`memswap_limit`) | 14 GiB available |
| CPU | < 7% of one core under 3 parallel sessions | 1.0 + 0.5 CPU | 16 CPUs |
| Disk | images 414 MB + 73 MB; logs ≤ 2 × 50 MB | — | `/var/lib/docker` 31 GB free |
| Ports | none needed | none published | 8000/5432/5433 already taken — **no conflict** |

**Verdict: Stage 1 fits.** Worst case it uses 5% of the available RAM and about 0.6 GB of
the Docker disk. Because `memswap_limit` equals the memory limit, these containers can
never add to the full swap. Run DISCOVERY.md A1 first anyway, so that we know whether
the host is actively swapping before adding anything.

# Part A — Stage 1: CW MCP

Labels: 🪟 = Windows PowerShell on the laptop · 🐧 = Ubuntu shell on
gc-gei-ollama (PuTTY). Never paste one into the other.

Server deployment directory: `~/deployments/cw-mcp` (owned by `reil`, no sudo).

---

## 0. Prerequisites (people, not commands)

Do not start step 1 until all are ✅.

| # | Who | What | Status |
|---|---|---|---|
| 0.1 | **Ivan** | Mint a **new** auth-token Credential for WORKLOAD user `cw-postgres-mcp` (same user, same `cw-data-readers` group, same served Service). Do **not** revoke the old one yet — revoke at step 10. Deliver it via a secure channel, not chat history/email | ☐ |
| 0.2 | **Ivan** | Answer: can two sessions of `cw-postgres-mcp` run at once? (Decides whether we can pre-test the server before stopping the laptop.) Optional hardening: can the session be limited with `--scope` to `cw-postgres` + serving `cw-postgres-mcp`? | ☐ |
| 0.3 | **Chris Jane** | Confirm Janus's Proxy URL for `cw-postgres-mcp` points at the Octelium Service (host-independent), so no Janus change is needed. This does **not** change any admin-approval requirement for registrations | ☐ |
| 0.4 | **Paul** | Approve the cutover and a short window (expect < 15 min of MCP downtime) | ☐ |
| 0.5 | Reil | Server inspection: resources ✅, `/dev/net/tun` ✅, docker access ✅ (2026-10-19). Swap check (DISCOVERY.md A1/A2) | ☐ |

---

## 1. 🪟 Build the transfer bundle (no secrets)

**Dir:** `C:\Users\ReilJakeEngaña\OneDrive - Geidi\Documents\ConnectWise MCP`

```powershell
tar -czf "$env:TEMP\cw-mcp-bundle.tar.gz" --exclude=".env" --exclude="secrets/octelium_auth_token" -C . cw-deployment
tar -tzf "$env:TEMP\cw-mcp-bundle.tar.gz"
```

- **Purpose:** package the deployment files only.
- **Expected:** listing shows `cw-deployment/compose.yaml`, `.env.example`, `scripts/*`, docs, `secrets/.gitkeep` — and **no** `.env` or `octelium_auth_token`.
- **Errors:** `tar: not recognized` → Windows 10 1803+ ships `tar.exe`; use 7-Zip as fallback.
- **Recovery:** delete the bundle and rerun.

## 2. 🪟 Copy the bundle to the server

```powershell
scp "$env:TEMP\cw-mcp-bundle.tar.gz" reil@gc-gei-ollama:/home/reil/
# PuTTY-only alternative:
# pscp "$env:TEMP\cw-mcp-bundle.tar.gz" reil@gc-gei-ollama:/home/reil/
```

- **Expected:** `cw-mcp-bundle.tar.gz 100%`.
- **Errors:** host not found → Tailscale not connected on the laptop; permission denied → wrong user/key.
- **Recovery:** re-copy; nothing on the server changes besides this file.

## 3. 🐧 Unpack into the deployment directory 📋

```bash
mkdir -p ~/deployments
test -e ~/deployments/cw-mcp && echo "STOP: ~/deployments/cw-mcp already exists" || \
  { tar -xzf ~/cw-mcp-bundle.tar.gz -C ~/deployments && mv ~/deployments/cw-deployment ~/deployments/cw-mcp; }
cd ~/deployments/cw-mcp && ls -la && ls -la secrets
```

- **Purpose:** place the files without overwriting anything.
- **Expected:** files listed; `secrets/` contains only `.gitkeep`.
- **Errors:** `STOP: ... already exists` → a previous attempt exists; report back, do not delete it blindly.
- **Recovery:** `rm -rf ~/deployments/cw-mcp` is safe **only** if no containers named `cw-mcp*` exist (`docker ps -a | grep cw-mcp`).

## 4. 🐧 Create `.env`

**Dir:** `~/deployments/cw-mcp`

```bash
cp -n .env.example .env && cat .env
```

- **Expected:** the three non-secret values (domain, service name, `CW_POSTGRES_URL`). No token.
- **Recovery:** edit with `nano .env`.

## 5. 🐧 Store the NEW Octelium token (from Ivan, step 0.1)

```bash
umask 077
read -rsp 'Paste the NEW Octelium token, then press Enter: ' T; echo
printf '%s' "$T" > secrets/octelium_auth_token; unset T
chmod 600 secrets/octelium_auth_token
ls -l secrets/octelium_auth_token
```

- **Purpose:** write the token without it appearing on screen or in shell history.
- **Expected:** `-rw------- 1 reil reil <N> ... secrets/octelium_auth_token`.
- **Never:** paste the token into `.env`, the PuTTY scrollback, chat, or this repo. **Never** use the old laptop token.
- **Recovery:** rerun the block; it overwrites the file.

## 6. 🐧 Pre-flight 📋

```bash
bash scripts/verify-destination.sh
```

- **Expected:** ends with `PRE-FLIGHT: OK`.
- **Errors:** any `[FAIL]` line — fix that item; `cannot talk to docker` → you are not in the `docker` group; do **not** use sudo, report back.
- **Recovery:** read-only script; rerun freely.

## 7. 🐧 Pull the pinned images 📋

```bash
docker compose pull
docker image ls --digests | grep -E 'octelium|postgres-mcp'
```

- **Expected:** both images pulled; digests `sha256:a40ecd27…` (octelium) and `sha256:dbbd3468…` (postgres-mcp).
- **Errors:** `manifest unknown`/network error → server cannot reach ghcr.io/Docker Hub. Fallback: on the laptop `docker save <image@digest> -o x.tar`, copy, `docker load -i x.tar` on the server.
- **Recovery:** pulling only adds images; nothing running changes.

---

## ⏱️ Cutover window (needs 0.4 approval)

If Ivan confirmed concurrent sessions are fine (0.2), you may run step 9 before
step 8 to pre-test, then stop the laptop. Otherwise follow the order below.

## 8. 🪟 Stop the laptop stack (keep it for rollback)

**Dir:** `C:\Users\ReilJakeEngaña\OneDrive - Geidi\Documents\ConnectWise MCP`

```powershell
docker compose -p connectwisemcp stop
docker ps -a --filter "name=connectwisemcp" --format "table {{.Names}}\t{{.Status}}"
```

- **Expected:** both `connectwisemcp-*` containers `Exited`.
- **Note:** `stop`, **not** `down` — containers stay for the fast rollback path.

## 9. 🐧 Start the server stack 📋

**Dir:** `~/deployments/cw-mcp`

```bash
docker compose up -d
sleep 60
bash scripts/validate-stack.sh
```

- **Expected:** `VALIDATION: OK` — containers running, healthy, no ports, token not in inspect, restricted mode, DB connected, smoke test 9 tools / SELECT ok / UPDATE refused / `cw_agent`.
- **Errors:**
  - octelium logs show auth errors → wrong/expired token or Ivan hasn't applied the credential; `docker compose stop`, fix step 5, retry.
  - "no successful DB connection" but octelium looks fine → `docker compose up -d --force-recreate postgres-mcp`, wait 60s, revalidate.
  - anything else → **ROLLBACK.md**.

## 10. 🪟 End-to-end through Janus 📋

**Dir:** `C:\Users\ReilJakeEngaña\OneDrive - Geidi\Documents\ConnectWise MCP\Daily Tasks`

```powershell
claude mcp get cw-postgres-mcp
powershell -ExecutionPolicy Bypass -File ..\cw-deployment\scripts\verify-source.ps1
```

Then in Claude Code (that folder) ask: *"Using cw-postgres-mcp, how many rows are in cw.Company?"*

- **Expected:** `✓ Connected`; verify-source says nothing is listening on :8000 (laptop is not serving); the question returns a number (≈492).
- **This is the "works without my laptop's Docker" proof.** Optional stronger proof: quit Docker Desktop and repeat.

## 11. Close-out

| # | Who | Action |
|---|---|---|
| 11.1 | Reil | Soak: re-run `bash scripts/validate-stack.sh` after ~24h and after the restart test in VALIDATION.md |
| 11.2 | **Ivan** | Revoke the **old** (exposed) laptop credential |
| 11.3 | Reil 🪟 | After 11.2: `docker compose -p connectwisemcp down` in the ConnectWise MCP dir (removes old containers; no volumes involved). Remove `OCTELIUM_AUTH_TOKEN` from the OneDrive `.env` |
| 11.4 | Reil | Post evidence (validate-stack output, Janus check) on the Plane ticket; update `TICKETS OVERVIEW` |

---

# Part B — Stage 2 preparation: CW PostgreSQL

**Preparation only.** Nothing here touches the source database, the live mirror or
any existing container. Do not start until MIGRATION.md gate **G3** (dedicated disk)
is green. The restore cutover itself is MIGRATION.md §6.3 and needs gate G5 approval.

Server directory: `~/deployments/cw-mcp/db` (comes with the bundle from Part A).

## B1. 🐧 Confirm the dedicated disk 📋

```bash
df -hT /srv/cw-postgres
ls -ld /srv/cw-postgres
findmnt /srv/cw-postgres
```

- **Expected:** its own filesystem (≈100 GB, not `/` and not `/var/lib/docker`), owned by `reil`.
- **If** `findmnt` prints nothing, it is just a directory on `/`. **STOP**, because gate G3 isn't met.

## B2. 🐧 Create the data and dump directories

```bash
mkdir -p /srv/cw-postgres/data /srv/cw-postgres/dumps
ls -la /srv/cw-postgres
```

- **Expected:** `data/` and `dumps/` exist, both empty. Postgres sets its own
  permissions on `data/pgdata` at first start.

## B3. 🐧 Configuration and superuser secret

**Dir:** `~/deployments/cw-mcp/db`

```bash
cp -n .env.example .env && cat .env
umask 077
openssl rand -base64 33 | tr -d '\n' > secrets/cw_pg_superuser_password
chmod 600 secrets/cw_pg_superuser_password
ls -l secrets/
```

- **Expected:** `.env` shows `CW_PG_ROOT=/srv/cw-postgres`; the secret file is `-rw-------` and non-empty.
- The new cluster's superuser password is generated here and **never displayed**.
  Store a copy in the team password manager (Bitwarden) as "cw-postgres superuser (gc-gei-ollama)".
- `secrets/octelium_db_auth_token` is **not** needed until cutover (MIGRATION.md §6.3 C6); Ivan mints it.

## B4. 🐧 Validate the config and pull the image 📋

```bash
docker compose config --quiet && echo CONFIG-OK
docker compose config | grep -E 'published:|device:|memory:|image:'
docker compose pull cw-postgres
docker image ls --digests postgres
```

- **Expected:** `CONFIG-OK`; no `published:` line; `device: /srv/cw-postgres/data`;
  digest `sha256:2d2b8998…` for `postgres:17.11`.
- `secrets/octelium_db_auth_token` isn't needed yet. Tested: `config` passes without it,
  and the sidecar (profile `serve`) is not started by `up -d cw-postgres`.

## B5. 🐧 Rehearsal restore (MIGRATION.md §6.2), after the owner delivers a rehearsal dump

```bash
cd ~/deployments/cw-mcp/db
docker compose up -d cw-postgres          # no 'serve' profile: not reachable from Octelium
sleep 60; docker compose ps               # cw-postgres: healthy
(cd /srv/cw-postgres/dumps && sha256sum -c cw-<ts>.sha256)
bash ../scripts/restore.sh <ts>
diff <(grep -v '^roleconfig' /srv/cw-postgres/dumps/inventory-source-<ts>.txt) <(grep -v '^roleconfig' inventory-dest-<ts>.txt) && echo STRUCTURE-IDENTICAL
docker exec cw-postgres psql -U postgres -XAtc "select pg_size_pretty(pg_database_size('postgres')); show data_checksums"
df -h /srv/cw-postgres; docker stats --no-stream cw-postgres
```

- **Expected:** `restore.sh` prints timings; `STRUCTURE-IDENTICAL`; `data_checksums = on`.
- **Record:** dump size, restore time, DB size, memory use. These replace the estimates in MIGRATION.md §3.
- **Errors:** `STOP: target already has … CW relations` means the data dir isn't fresh (see B6). Restore errors: stop and share the last 30 lines.

## B6. 🐧 Discard the rehearsal (CW-owned new resources only)

```bash
cd ~/deployments/cw-mcp/db
docker compose down                       # removes cw-postgres container + cw-db-net only; NOT -v
ls -la /srv/cw-postgres/data
```

Emptying `/srv/cw-postgres/data` afterwards needs root, because Postgres files are owned by
the container's postgres user. **Ask before doing it**, and confirm the path twice. It is the
only deletion in this plan, and it applies only to rehearsal data on the new CW disk.
