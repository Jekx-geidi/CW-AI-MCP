"""Reports-first MCP server for the ConnectWise mirror.

Agents get the pre-built rpt reports first (list_reports, run_report). Raw SQL
against the cw tables (query_cw) is offered only as a last resort for questions
no report covers, so routine questions never re-scan the mirror.

Configuration (environment):
    DATABASE_URI           Postgres connection string (cw_agent, read-only)
    MCP_HOST / MCP_PORT    SSE bind address (default 127.0.0.1:8000)
    STATEMENT_TIMEOUT_MS   Per-query timeout (default 30000)
    CONNECT_TIMEOUT_S      Connection timeout (default 10)
    MAX_ROWS               Rows returned per call (default 500)
"""

import argparse
import logging
import os
import re
from collections.abc import Callable
from datetime import date, datetime
from decimal import Decimal
from typing import Any

import anyio
import psycopg
from mcp.server.fastmcp import FastMCP
from psycopg import sql
from psycopg.rows import dict_row

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s,p%(process)s,{%(filename)s:%(lineno)d},%(levelname)s,%(message)s",
)
logger = logging.getLogger(__name__)

DEFAULT_HOST: str = "127.0.0.1"
DEFAULT_PORT: int = 8000
DEFAULT_TIMEOUT_MS: int = 30000
DEFAULT_CONNECT_TIMEOUT_S: int = 10
DEFAULT_MAX_ROWS: int = 500
FUNCTION_NAME_PATTERN = re.compile(r"^rpt\.[a-z_][a-z0-9_]*$")
PARAM_NAME_PATTERN = re.compile(r"^p_[a-z0-9_]+$")
# Parameter types report functions may use; values are cast to these.
ALLOWED_PARAM_TYPES: frozenset[str] = frozenset({"integer", "numeric", "text", "boolean", "date"})

INSTRUCTIONS = """ConnectWise reporting server. ALWAYS answer from the pre-built reports first:
1. Call list_reports to see every report, what it answers and its parameters.
2. Call run_report with the best match. Most reports take p_months (1-24, e.g. 3, 6, 12),
   p_board ('Support' is the main board, '%' for all boards, or any board name from
   the Board overview report) or p_team ('Team A', 'Team B', '%').
   ticket_pivot and time_pivot cover any one or two dimension split.
3. Combine several reports when a question spans them.
Only call query_cw when no report can answer the question (a new requirement).
Quote the data freshness returned with every answer."""

mcp = FastMCP("cw-reports", instructions=INSTRUCTIONS)


def _get_setting(
    name: str,
    default: int,
) -> int:
    value = os.getenv(name)
    return int(value) if value else default


def _get_dsn() -> str:
    dsn = os.getenv("DATABASE_URI")
    if not dsn:
        raise ValueError("DATABASE_URI must be set (cw_agent connection string)")
    return dsn


def _to_json_value(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    return value


def _clean_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{key: _to_json_value(value) for key, value in row.items()} for row in rows]


def _with_read_only(work: Callable[[psycopg.Connection], Any]) -> Any:
    """Run work(conn) in one read-only transaction on one connection, then roll back."""
    conn = psycopg.connect(
        _get_dsn(),
        row_factory=dict_row,
        autocommit=False,
        connect_timeout=_get_setting("CONNECT_TIMEOUT_S", DEFAULT_CONNECT_TIMEOUT_S),
    )
    try:
        conn.execute("set transaction read only")
        timeout_ms = _get_setting("STATEMENT_TIMEOUT_MS", DEFAULT_TIMEOUT_MS)
        conn.execute(sql.SQL("set local statement_timeout = {}").format(sql.Literal(timeout_ms)))
        return work(conn)
    finally:
        try:
            conn.rollback()
        finally:
            conn.close()


def _fetch(
    conn: psycopg.Connection,
    query: sql.Composable | str,
    params: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], bool]:
    """Run a query through a server-side cursor and return (rows, truncated).

    The server-side cursor means only MAX_ROWS + 1 rows ever leave the
    database, however large the full result is."""
    max_rows = _get_setting("MAX_ROWS", DEFAULT_MAX_ROWS)
    with conn.cursor(name="mcp_result") as cur:
        cur.execute(query, params)
        rows = cur.fetchmany(max_rows + 1)
    truncated = len(rows) > max_rows
    return _clean_rows(rows[:max_rows]), truncated


def _freshness(conn: psycopg.Connection) -> str | None:
    row = conn.execute("select last_refreshed_at::text as at from rpt.freshness").fetchone()
    return row["at"] if row else None


def _resolve_report(
    conn: psycopg.Connection,
    report: str,
) -> str:
    """Map a report name or function name to its catalog function name."""
    rows = conn.execute(
        "select function_name from rpt.catalog "
        "where lower(report) = lower(%(r)s) or function_name = %(r)s "
        "or function_name = 'rpt.' || %(r)s",
        {"r": report.strip()},
    ).fetchall()
    if not rows:
        raise ValueError(f"Unknown report '{report}'. Call list_reports for the available reports.")
    function_name = rows[0]["function_name"]
    if not FUNCTION_NAME_PATTERN.match(function_name):
        raise ValueError(f"Catalog entry '{function_name}' is not a valid rpt function name")
    return function_name


def _function_params(
    conn: psycopg.Connection,
    function_name: str,
) -> dict[str, str]:
    """Input parameter names and types of a report function (exactly one overload)."""
    rows = conn.execute(
        "select p.oid, a.name, format_type(a.type_oid, null) as type "
        "from pg_proc p "
        "join pg_namespace n on n.oid = p.pronamespace "
        "cross join lateral unnest("
        "    coalesce(p.proallargtypes, p.proargtypes::oid[]),"
        "    p.proargnames,"
        "    coalesce(p.proargmodes, array_fill('i'::\"char\", array[p.pronargs::int]))"
        ") as a(type_oid, name, mode) "
        "where n.nspname = 'rpt' and p.proname = %(f)s and a.mode = 'i'",
        {"f": function_name.split(".", 1)[1]},
    ).fetchall()
    if len({row["oid"] for row in rows}) > 1:
        raise ValueError(f"Report function '{function_name}' has more than one version; re-run the rpt scripts")
    return {row["name"]: row["type"] for row in rows if row["name"]}


def _check_value_type(
    name: str,
    value: Any,
    pg_type: str,
) -> None:
    """Reject JSON values that do not match the parameter type instead of silently casting them."""
    is_number = isinstance(value, (int, float, Decimal)) and not isinstance(value, bool)
    ok = {
        "integer": is_number and float(value).is_integer(),
        "numeric": is_number,
        "text": isinstance(value, str),
        "boolean": isinstance(value, bool),
        "date": isinstance(value, str),
    }.get(pg_type, False)
    if value is not None and not ok:
        raise ValueError(f"Parameter {name} must be {pg_type}, got {value!r}")
    if name == "p_months" and value is not None and not 1 <= value <= 24:
        raise ValueError("p_months must be between 1 and 24 (history kept: 25 months)")


def build_report_call(
    function_name: str,
    params: dict[str, Any],
    allowed: dict[str, str],
) -> sql.Composed:
    """Build `select * from rpt.fn(p_a => %(p_a)s::type, ...)` with validated names and types."""
    if not FUNCTION_NAME_PATTERN.match(function_name):
        raise ValueError(f"Invalid report function '{function_name}'")
    unknown = [name for name in params if name not in allowed or not PARAM_NAME_PATTERN.match(name)]
    if unknown:
        raise ValueError(f"Unknown parameter(s) {unknown}. This report accepts: {sorted(allowed)}")
    bad_types = {name: allowed[name] for name in params if allowed[name] not in ALLOWED_PARAM_TYPES}
    if bad_types:
        raise ValueError(f"Unsupported parameter type(s) {bad_types}")
    for key, value in params.items():
        _check_value_type(key, value, allowed[key])
    schema, name = function_name.split(".", 1)
    args = sql.SQL(", ").join(
        sql.SQL("{} => {}::{}").format(sql.Identifier(key), sql.Placeholder(key), sql.SQL(allowed[key]))
        for key in params
    )
    return sql.SQL("select * from {}.{}({})").format(sql.Identifier(schema), sql.Identifier(name), args)


def check_single_statement(query: str) -> str:
    """Allow exactly one statement, so a query cannot end the read-only transaction."""
    stripped = query.strip().rstrip(";").strip()
    if not stripped:
        raise ValueError("Empty query")
    if ";" in stripped:
        raise ValueError("Send one statement per call (no ';' inside the query)")
    return stripped


def _list_reports_sync() -> dict[str, Any]:
    def work(conn: psycopg.Connection) -> dict[str, Any]:
        rows, _ = _fetch(
            conn,
            "select c.report, c.function_name, c.answers, c.sql_example, "
            "pg_get_function_arguments(p.oid) as parameters "
            "from rpt.catalog c "
            "join pg_namespace n on n.nspname = 'rpt' "
            "join pg_proc p on p.pronamespace = n.oid "
            "and p.proname = split_part(c.function_name, '.', 2) "
            "order by c.report",
        )
        return {"data_freshness": _freshness(conn), "reports": rows}

    return _with_read_only(work)


def _run_report_sync(
    report: str,
    params: dict[str, Any],
) -> dict[str, Any]:
    def work(conn: psycopg.Connection) -> dict[str, Any]:
        function_name = _resolve_report(conn, report)
        query = build_report_call(function_name, params, _function_params(conn, function_name))
        logger.info("run_report %s %s", function_name, params)
        rows, truncated = _fetch(conn, query, params)
        return {
            "report": function_name,
            "params": params,
            "data_freshness": _freshness(conn),
            "row_count": len(rows),
            "truncated": truncated,
            "rows": rows,
        }

    return _with_read_only(work)


def _query_cw_sync(statement: str) -> dict[str, Any]:
    def work(conn: psycopg.Connection) -> dict[str, Any]:
        rows, truncated = _fetch(conn, statement)
        return {"row_count": len(rows), "truncated": truncated, "rows": rows}

    return _with_read_only(work)


@mcp.tool()
async def list_reports() -> dict[str, Any]:
    """START HERE for any ConnectWise reporting question (tickets, SLA, utilisation,
    capacity, drivers, boards, clients, agreements, projects, backlog, trends).
    Returns every pre-built report with what it answers, its parameters and an example."""
    return await anyio.to_thread.run_sync(_list_reports_sync)


@mcp.tool()
async def run_report(report: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """Run a pre-built report by its name or function (from list_reports).

    params uses the report's own parameter names, for example
    {"p_board": "Support", "p_months": 6} or {"p_team": "Team A", "p_months": 3}.
    Omitted parameters use the report's defaults."""
    return await anyio.to_thread.run_sync(_run_report_sync, report, params or {})


@mcp.tool()
async def query_cw(query: str) -> dict[str, Any]:
    """LAST RESORT: one read-only SELECT against the raw ConnectWise tables (schema cw).
    Only use this when no report from list_reports can answer the question.
    Raw queries are slow on the live mirror and are cut off after 30 seconds."""
    statement = check_single_statement(query)
    logger.info("query_cw used (no report matched): %s", statement[:200])
    return await anyio.to_thread.run_sync(_query_cw_sync, statement)


def main() -> None:
    parser = argparse.ArgumentParser(description="Reports-first ConnectWise MCP server (SSE)")
    parser.add_argument("--host", default=os.getenv("MCP_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int, default=_get_setting("MCP_PORT", DEFAULT_PORT))
    args = parser.parse_args()
    _get_dsn()
    mcp.settings.host = args.host
    mcp.settings.port = args.port
    logger.info("Starting cw-reports MCP on %s:%s (SSE)", args.host, args.port)
    mcp.run(transport="sse")


if __name__ == "__main__":
    main()
