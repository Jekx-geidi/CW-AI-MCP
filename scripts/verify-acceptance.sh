#!/usr/bin/env bash
# Acceptance checks for CW-MCP-01 (Plane GEIDIMCP-51).
# Run after `docker compose up -d` and once Ivan's identity/credential is live.
# Talks straight to cw-postgres over the Octelium mesh (same path the MCP
# server uses) so the evidence reflects what an agent would actually see.
set -euo pipefail

: "${OCTELIUM_CW_POSTGRES_URL:?set this (see .env.example) before running}"

echo "== 1. List tables in cw schema =="
psql "$OCTELIUM_CW_POSTGRES_URL" -c "\dt cw.*"

echo
echo "== 2. select count(*) from cw.\"Company\" (expect 490) =="
psql "$OCTELIUM_CW_POSTGRES_URL" -c 'select count(*) from cw."Company";'

echo
echo "== 3. Attempt an update — must be refused =="
if psql "$OCTELIUM_CW_POSTGRES_URL" -c 'update cw."Company" set "Id" = "Id" where false;' 2>&1; then
  echo "FAIL: update was not refused" >&2
  exit 1
else
  echo "OK: update was refused, as expected"
fi

echo
echo "== 4. Deliberately slow query — must be cut off at 60s =="
start=$(date +%s)
if psql "$OCTELIUM_CW_POSTGRES_URL" -c 'select pg_sleep(70);' 2>&1; then
  echo "FAIL: slow query was not cut off" >&2
  exit 1
else
  elapsed=$(( $(date +%s) - start ))
  echo "OK: query was cancelled after ${elapsed}s (expected ~60s)"
fi
