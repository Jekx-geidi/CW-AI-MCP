#!/usr/bin/env python3
"""Read-only MCP smoke test for the CW postgres-mcp SSE endpoint.

Standard library only, so it runs inside the postgres-mcp container
(`docker exec -i cw-mcp-server python - < mcp_smoke.py`) or anywhere with
Python 3.8+.

Checks:
  1. GET /sse returns an `endpoint` event (SSE transport is up).
  2. MCP `initialize` succeeds.
  3. `tools/list` returns the expected tool set (parity with the laptop).
  4. `execute_sql` runs `SELECT 1` against cw-postgres (end-to-end DB path).
  5. `execute_sql` with an UPDATE is refused (read-only enforcement).
     The UPDATE uses `WHERE false`, so it can never change a row even if
     read-only enforcement were somehow missing.

  6. (with --cw) the session runs as `cw_agent` and cw."Company" has rows,
     i.e. we are reading the real CW mirror, not some other database.

Usage: python mcp_smoke.py [--cw] [base_url]   (default http://127.0.0.1:8000)
Exit code 0 = all checks passed, 1 = a check failed.
"""

import http.client
import json
import queue
import sys
import threading
import urllib.parse

EXPECTED_TOOLS = {
    "list_schemas",
    "list_objects",
    "get_object_details",
    "explain_query",
    "execute_sql",
    "analyze_workload_indexes",
    "analyze_query_indexes",
    "analyze_db_health",
    "get_top_queries",
}
TIMEOUT = 60

args = [a for a in sys.argv[1:] if a != "--cw"]
CW_CHECK = "--cw" in sys.argv[1:]
base = urllib.parse.urlparse(args[0] if args else "http://127.0.0.1:8000")
messages: "queue.Queue[dict]" = queue.Queue()
endpoint: "queue.Queue[str]" = queue.Queue()
failures = []


def check(ok, label, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {label}" + (f" - {detail}" if detail else ""))
    if not ok:
        failures.append(label)


def read_sse():
    conn = http.client.HTTPConnection(base.hostname, base.port or 80, timeout=TIMEOUT)
    conn.request("GET", "/sse", headers={"Accept": "text/event-stream"})
    resp = conn.getresponse()
    event, data = None, []
    while True:
        raw = resp.fp.readline()
        if not raw:
            return
        line = raw.decode("utf-8").rstrip("\r\n")
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].strip())
        elif line == "" and event:
            payload = "\n".join(data)
            if event == "endpoint":
                endpoint.put(payload)
            elif event == "message":
                messages.put(json.loads(payload))
            event, data = None, []


def post(path, body):
    conn = http.client.HTTPConnection(base.hostname, base.port or 80, timeout=TIMEOUT)
    conn.request("POST", path, body=json.dumps(body), headers={"Content-Type": "application/json"})
    resp = conn.getresponse()
    resp.read()
    return resp.status


def rpc(path, req_id, method, params=None):
    status = post(path, {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}})
    if status not in (200, 202):
        raise RuntimeError(f"{method}: HTTP {status}")
    while True:
        msg = messages.get(timeout=TIMEOUT)
        if msg.get("id") == req_id:
            return msg


def tool_text(result):
    return " ".join(c.get("text", "") for c in result.get("result", {}).get("content", []))


def main():
    threading.Thread(target=read_sse, daemon=True).start()
    try:
        path = endpoint.get(timeout=TIMEOUT)
    except queue.Empty:
        check(False, "SSE endpoint event", "no endpoint event received")
        return 1
    check(True, "SSE endpoint event")

    init = rpc(path, 1, "initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "cw-mcp-smoke", "version": "1"},
    })
    server = init.get("result", {}).get("serverInfo", {})
    check("result" in init, "initialize", f"{server.get('name')} {server.get('version')}")
    post(path, {"jsonrpc": "2.0", "method": "notifications/initialized"})

    tools = rpc(path, 2, "tools/list").get("result", {}).get("tools", [])
    names = {t["name"] for t in tools}
    print("      tools:", ", ".join(sorted(names)))
    check(names == EXPECTED_TOOLS, "tool parity",
          f"missing={sorted(EXPECTED_TOOLS - names)} extra={sorted(names - EXPECTED_TOOLS)}")

    sql_tool = next((t for t in tools if t["name"] == "execute_sql"), None)
    if not sql_tool:
        check(False, "execute_sql available")
        return 1
    arg = next(iter(sql_tool.get("inputSchema", {}).get("properties", {"sql": None})))

    ok = rpc(path, 3, "tools/call", {"name": "execute_sql", "arguments": {arg: "SELECT 1 AS ok"}})
    text = tool_text(ok)
    check(not ok.get("result", {}).get("isError") and "ok" in text, "SELECT 1 via MCP", text[:120])

    upd = rpc(path, 4, "tools/call", {"name": "execute_sql", "arguments": {
        arg: 'UPDATE cw."Company" SET "Company_Name" = "Company_Name" WHERE false'}})
    text = tool_text(upd).lower()
    refused = upd.get("result", {}).get("isError") or "error" in upd or any(
        w in text for w in ("read-only", "read only", "not allowed", "error"))
    check(bool(refused), "UPDATE refused (read-only)", text[:160])

    if CW_CHECK:
        cw = rpc(path, 5, "tools/call", {"name": "execute_sql", "arguments": {
            arg: 'SELECT current_user AS usr, (SELECT count(*) FROM cw."Company") AS companies'}})
        text = tool_text(cw)
        check(not cw.get("result", {}).get("isError") and "'cw_agent'" in text
              and "'companies': 0" not in text, "CW mirror reachable as cw_agent", text[:120])

    print("RESULT:", "ALL PASSED" if not failures else f"FAILED: {failures}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
