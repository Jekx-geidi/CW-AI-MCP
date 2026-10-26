# Laptop-side checks for the CW MCP migration (Windows PowerShell).
# Read-only. Shows the state of the laptop stacks and, if one is running,
# runs the MCP smoke test against it. Prints no secrets.
#
#   powershell -ExecutionPolicy Bypass -File scripts\verify-source.ps1
#
# Before cutover: expect the old "connectwisemcp" stack running + smoke PASS.
# After cutover:  expect no CW stack running on the laptop.

$ErrorActionPreference = 'Continue'
Write-Host "== CW compose stacks on this laptop"
docker compose ls --all | Select-String -Pattern 'NAME|connectwisemcp|cw-mcp' | ForEach-Object { $_.Line }

Write-Host "`n== CW containers"
docker ps -a --filter "name=connectwisemcp" --filter "name=cw-mcp" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

$listening = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue
if (-not $listening) {
    Write-Host "`nNothing listening on :8000 - no laptop CW MCP is serving (expected after cutover)."
    exit 0
}

Write-Host "`n== MCP smoke test against the laptop stack (http://127.0.0.1:8000)"
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Write-Host "python not on PATH - skipping smoke test"; exit 0 }
& $py.Source -I (Join-Path $PSScriptRoot 'mcp_smoke.py') --cw http://127.0.0.1:8000
exit $LASTEXITCODE
