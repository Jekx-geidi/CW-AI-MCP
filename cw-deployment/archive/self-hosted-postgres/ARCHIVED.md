# ARCHIVED — self-hosted CW PostgreSQL on gc-gei-ollama

**Superseded on 2026-10-19.** The target for CW PostgreSQL is now **Supabase Cloud**,
not a container on gc-gei-ollama. See `../../SUPABASE_MIGRATION.md`.

Nothing in this folder was ever deployed. It is kept only as reference:

| File | Still useful for |
|---|---|
| `MIGRATION.md`, `DEPLOYMENT.md`, `README.md`, `ROLLBACK.md`, `DISCOVERY.md` | Snapshots of the plan as it stood before the change (capacity analysis, decisions D1–D11) |
| `db/compose.yaml` | Parity settings measured on the source (max_connections, memory, WAL) |
| `scripts/restore.sh` | Pattern for the never-overwrite guard (re-used in `scripts/supabase-restore.sh`) |
| `scripts/db-backup.sh` | Pattern for dump + checksum + optional age/rsync (re-used in `scripts/supabase-backup.sh`) |
| `scripts/source-dump.sh` | Old version that also dumped roles with password hashes. **Do not use**: on Supabase roles are recreated, never imported |

Do not run anything from this folder. In particular, no PostgreSQL container or data
volume may be created on gc-gei-ollama.
