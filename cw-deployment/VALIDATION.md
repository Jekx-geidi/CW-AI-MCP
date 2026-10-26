# Stage 1 — Validation

Stage 1 is done only when every check below passes on gc-gei-ollama **and**
through Janus, with the laptop stack stopped.

## Baseline (laptop stack, 2026-10-19, `mcp_smoke.py --cw`)

```
[PASS] SSE endpoint event
[PASS] initialize - postgres-mcp 1.6.0
      tools: analyze_db_health, analyze_query_indexes, analyze_workload_indexes, execute_sql,
             explain_query, get_object_details, get_top_queries, list_objects, list_schemas
[PASS] tool parity - missing=[] extra=[]
[PASS] SELECT 1 via MCP - [{'ok': 1}]
[PASS] UPDATE refused (read-only) - error: error validating query: update cw."company" ...
[PASS] CW mirror reachable as cw_agent - [{'usr': 'cw_agent', 'companies': 492}]
```

The Company count will drift as the mirror loads; any non-zero count passes.

## Checks

| # | Check | How | Pass criteria |
|---|---|---|---|
| V1 | Containers up, restart policy | `validate-stack.sh` | both `running`, `policy=unless-stopped` |
| V2 | Healthcheck | `validate-stack.sh` | `cw-mcp-server` `healthy` |
| V3 | No exposure | `validate-stack.sh` | no host ports; token not in `docker inspect` |
| V4 | Read-only mode | `validate-stack.sh` | `RESTRICTED mode` in logs |
| V5 | DB path | `validate-stack.sh` | `Successfully connected to database` |
| V6 | MCP parity + data | `validate-stack.sh` (smoke `--cw`) | output matches the baseline above |
| V7 | Through Janus | DEPLOYMENT.md step 10 | `claude mcp get cw-postgres-mcp` ✓ Connected; real query answers |
| V8 | Laptop independent | DEPLOYMENT.md step 10 | nothing on laptop :8000; V7 still passes |
| V9 | Sidecar restart resilience | see below | smoke passes after sidecar restart (or after the documented recreate) |
| V10 | Reboot-style restart | `docker compose restart` then `validate-stack.sh` | `VALIDATION: OK` |
| V11 | Neighbours unaffected | `docker ps` before/after, compare | no other container restarted or changed |
| V12 | Concurrency | 3 parallel `docker exec -i cw-mcp-server python - --cw < scripts/mcp_smoke.py` | all 3 `ALL PASSED`. **Known issue:** on the laptop (2026-10-19) 1 of 3 parallel runs timed out on `SELECT 1`. Record the server result; if it repeats, investigate before giving the MCP to more staff |

### V9 — sidecar restart test (🐧, in `~/deployments/cw-mcp`)

```bash
docker restart cw-mcp-octelium
sleep 45
bash scripts/validate-stack.sh
```

If the smoke test fails here while both containers show `running`, that is the
known `network_mode: service:` stale-namespace behaviour. Confirm the fix:

```bash
docker compose up -d --force-recreate postgres-mcp
sleep 45
bash scripts/validate-stack.sh
```

Record which case happened — it decides whether we add an automatic recovery
(e.g. a watchdog) later.

### V11 — neighbour check (🐧)

Before step 9: `docker ps --format '{{.Names}} {{.Status}}' | sort > /tmp/before.txt`
After V10: `docker ps --format '{{.Names}} {{.Status}}' | sort > /tmp/after.txt; diff /tmp/before.txt /tmp/after.txt`
Only `cw-mcp-*` lines may differ (uptime text changes are fine).
