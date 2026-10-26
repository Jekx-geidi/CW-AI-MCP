# Discovery — read-only checks before any database work

Everything here is **read-only**. Nothing is started, stopped, installed or
changed. Sanitize output before sharing (remove anything that looks like a
password, token or connection string with a password).

🐧 = run by Reil on gc-gei-ollama (PuTTY), no sudo.
👤 = run by the source owner (Ivan / Paul / Joshua) on the current cw-postgres host.

---

## Part A — 🐧 gc-gei-ollama

### A1. Memory pressure: is the full swap a live problem or stale?

```bash
free -h; swapon --show
cat /proc/sys/vm/swappiness
cat /proc/pressure/memory /proc/pressure/io
uptime
vmstat 5 7
```

Read `vmstat` columns `si`/`so` (swap-in/out per second), ignoring the first line:
- **both ≈ 0** → swap holds stale pages pushed out long ago; not a live problem.
- **sustained non-zero** → the host is actively swapping now; adding a 6 GiB
  database here would hurt every workload. Stage 2 blocks until resolved.

`/proc/pressure/memory` `some avg60` above ~5 means tasks are regularly
stalling on memory.

### A2. Who holds the swap and the RAM?

```bash
for f in /proc/[0-9]*/status; do awk '/^Name:/{n=$2} /^VmSwap:/{if ($2>0) print $2" kB", n}' "$f" 2>/dev/null; done | sort -rn | head -15
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}'
journalctl -k --since "-14 days" --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -10
```

(The `journalctl` line may print nothing or "permission denied" — both fine, say which.)

### A3. Is cw-postgres (or its loader/PostgREST) already on this host?

```bash
# Postgres backend process titles are "postgres: <user> <db> <client> ...".
# If cw_agent or authenticator appear here, cw-postgres runs on THIS host.
ps -eo args | grep -E '^postgres: ' | awk '{print $2, $3}' | sort | uniq -c | sort -rn | head -20

# Process names only (no arguments, so no secrets) for Java / PostgREST / Kafka
ps -eo comm | grep -iE 'java|postgrest|kafka' | sort | uniq -c

# Which containers own the existing 5432/5433/8000 listeners
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' | grep -E ':(5432|5433|8000)->'

# Any postgres / postgrest / kafka / connect / debezium containers at all (running or stopped)
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -iE 'postgres|postgrest|kafka|connect|debezium|zookeeper|redpanda|cw'

# cw-postgres reports its own address as 172.18.0.2 — does any network here use 172.18.0.0/16?
for n in $(docker network ls -q); do docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}| {{range .Containers}}{{.Name}}={{.IPv4Address}} {{end}}' "$n"; done | grep '172\.18\.'
```

### A4. Disk: what is filling /var/lib/docker, and are there spare disks?

```bash
df -hT / /var/lib/docker
docker system df
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
cat /etc/os-release | head -2; uname -r
```

`docker system df` is read-only (it only reports). `lsblk` shows whether an
unused disk or free volume-group space exists for a dedicated CW disk.

---

## Part B — 👤 source owner (send to Ivan / Paul / Joshua)

> We are preparing to move cw-postgres (14 GB, PG 17.11) and the CW MCP to
> gc-gei-ollama. Nothing will be changed on the source. Could you run / answer
> the following, read-only? Please mask any secrets.

### B1. Where does cw-postgres run?

- Host name / IP, and the container name and compose project directory:
  ```bash
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -iE 'postgres|postgrest|kafka|connect|debezium'
  PG_CONTAINER=REPLACE_WITH_CW_POSTGRES_CONTAINER_NAME
  docker inspect -f '{{.Name}} project={{index .Config.Labels "com.docker.compose.project"}} dir={{index .Config.Labels "com.docker.compose.project.working_dir"}} mounts={{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}' "$PG_CONTAINER"
  docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$PG_CONTAINER" | xargs -r df -h
  ```
- Octelium: what is the upstream of Service `cw-postgres`, and how is it served
  (connector on the host, `--serve` sidecar, k8s)?

### B2. Who connects, from where (superuser `psql` on the source)

```sql
select usename, application_name, client_addr, count(*)
  from pg_stat_activity where datname = 'postgres' group by 1,2,3 order by 1;
select slot_name, plugin, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) retained
  from pg_replication_slots;
select now(), pg_size_pretty(pg_database_size('postgres'));   -- run again in 7 days: growth rate
show data_directory;
```

### B3. The JDBC loader (5 sessions as `postgres`, "PostgreSQL JDBC Driver")

1. What is it? Our notes say the `cw-ai-data-platform` uses Debezium — is this a
   **Kafka Connect JDBC sink** (Debezium or Confluent) fed from a Debezium source
   on the ConnectWise SQL Server?
2. Where does it run (host/container), and what hostname does it use to reach
   cw-postgres (`connection.url`): the Octelium name, a Docker network name, or an IP?
3. If Kafka Connect, please share (secrets masked):
   ```bash
   CONNECT=http://REPLACE_WITH_CONNECT_HOST:8083
   curl -s "$CONNECT/connectors"
   NAME=REPLACE_WITH_SINK_CONNECTOR_NAME
   curl -s "$CONNECT/connectors/$NAME/status"
   curl -s "$CONNECT/connectors/$NAME/config" | jq 'with_entries(if (.key|test("password|secret|token|key";"i")) then .value="***" else . end)'
   ```
   We need: `insert.mode` (upsert?), `primary.key.mode`, `delete.enabled`,
   `schema.evolution`, and the topics' `retention.ms`.
4. Can it be **paused** for ~1–2 hours and resumed without losing changes
   (Kafka keeps the backlog)? What is the maximum safe pause?
5. Is the mirror **rebuildable** from ConnectWise (full re-snapshot), and how long would that take?
6. Why does it connect as the `postgres` superuser? (A dedicated writer role is
   recommended after the move — not part of the move itself.)

### B4. PostgREST 14.17 (`authenticator` → `cw_reader`)

1. Where does it run, what is its `db-uri` host, and who/what calls it?
2. Is it in the same compose project as cw-postgres?

### B5. Other consumers and constraints

1. Anything else reading or writing (Metabase, reports, KB/retrieval jobs, exports)?
2. Why `wal_level = logical` — is a CDC consumer planned off this mirror (CW-RET-02)?
3. Backups today: tool, schedule, location (D-16 asked Evgeny; still open).
4. Off-host backup target + encryption we should use on gc-gei-ollama.
5. Who approves the cutover window, and the maximum acceptable mirror staleness.

---

## What the answers decide

| Answer | Decides |
|---|---|
| A1/A2 swap live vs stale | Whether gc-gei-ollama can take a 6 GiB database at all |
| A3 cw-postgres already here? | If yes: Stage 2 shrinks to "adopt and harden in place" |
| A4 + MIGRATION.md §3 | Dedicated disk size / where data lives |
| B1 Octelium upstream | How consumers are switched (one repoint vs many config edits) |
| B3 loader type + hostname | Whether the loader **moves** or only gets a **new destination** (MIGRATION.md §5) |
| B3.4 / B3.5 pause & rebuild | Cutover method: dump/restore vs logical replication |
| B4 PostgREST | Repoint vs co-locate |
