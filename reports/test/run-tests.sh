#!/usr/bin/env bash
# Builds the rpt schema in a throwaway Postgres 17 container against the
# stub cw tables, runs every report check, re-runs the schema script to prove
# it is safe to apply twice, then removes the container.
#
# Usage (from the repo root):  bash reports/test/run-tests.sh
# On Windows Git Bash, set MSYS_NO_PATHCONV=1 first.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="rpt-test-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -e POSTGRES_PASSWORD=test -p 127.0.0.1::5432 \
    -v "$HERE/..:/reports:ro" postgres:17 >/dev/null

for _ in $(seq 1 30); do
    docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
done

# Result rows go to /dev/null; check results and errors arrive on stderr.
psql_run() {
    docker exec "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q -f "$1" >/dev/null
}

psql_run /reports/test/cw_stub.sql
psql_run /reports/001_rpt_schema.sql
psql_run /reports/002_rpt_more_reports.sql
psql_run /reports/003_rpt_boards_projects.sql
psql_run /reports/test/assertions.sql
echo "--- second apply"
psql_run /reports/001_rpt_schema.sql
psql_run /reports/002_rpt_more_reports.sql
psql_run /reports/003_rpt_boards_projects.sql
psql_run /reports/test/assertions.sql
echo "SQL CHECKS PASSED"

# Reports MCP server tests (unit + integration against this database).
if command -v uv >/dev/null 2>&1; then
    PORT="$(docker port "$NAME" 5432/tcp | head -1 | sed 's/.*://')"
    export RPT_TEST_DSN="postgresql://cw_agent:agent@127.0.0.1:${PORT}/postgres"
    (cd "$HERE/../../reports-mcp" && uv run --group dev pytest -q)
    echo "MCP SERVER TESTS PASSED"
else
    echo "uv not found: skipped the reports-mcp tests"
fi
