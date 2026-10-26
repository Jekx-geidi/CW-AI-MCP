#!/usr/bin/env bash
# Post-deploy validation on gc-gei-ollama AFTER `docker compose up -d`.
# Read-only against the database. Prints no secrets.
# Run from the cw-deployment directory:  bash scripts/validate-stack.sh
set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
pass() { echo "[PASS] $*"; }
bad()  { echo "[FAIL] $*"; fail=1; }

echo "== containers"
for c in cw-mcp-octelium cw-mcp-server; do
  state=$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}} policy={{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null) \
    || { bad "$c not found"; continue; }
  case "$state" in running*) pass "$c $state" ;; *) bad "$c $state" ;; esac
done
health=$(docker inspect -f '{{.State.Health.Status}}' cw-mcp-server 2>/dev/null)
[ "$health" = "healthy" ] && pass "cw-mcp-server healthcheck: healthy" || bad "cw-mcp-server healthcheck: ${health:-unknown} (wait 30-60s after start, then re-run)"

echo "== exposure"
ports=$(docker port cw-mcp-octelium 2>/dev/null; docker port cw-mcp-server 2>/dev/null)
[ -z "$ports" ] && pass "no host ports published" || bad "host ports published: $ports"
s=secrets/octelium_auth_token
if [ -s "$s" ] && docker inspect cw-mcp-octelium cw-mcp-server | grep -qF -- "$(cat "$s")"; then
  bad "auth token visible in docker inspect"
else
  pass "auth token not visible in docker inspect"
fi

echo "== octelium sidecar (last 20 log lines, filtered)"
docker logs --tail 20 cw-mcp-octelium 2>&1 | grep -viE 'token' | sed 's/^/     /'

echo "== postgres-mcp start-up"
logs=$(docker logs cw-mcp-server 2>&1)
echo "$logs" | grep -q 'RESTRICTED mode' && pass "restricted (read-only) mode" || bad "restricted mode not confirmed in logs"
echo "$logs" | grep -q 'Successfully connected to database' && pass "connected to cw-postgres" || bad "no successful DB connection in logs"

echo "== MCP end-to-end (SSE, tools, SELECT, UPDATE refusal, CW data)"
if docker exec -i cw-mcp-server python - --cw < scripts/mcp_smoke.py; then
  pass "MCP smoke test"
else
  bad "MCP smoke test"
fi

echo
[ "$fail" -eq 0 ] && echo "VALIDATION: OK" || echo "VALIDATION: FAILED - see ROLLBACK.md"
exit "$fail"
