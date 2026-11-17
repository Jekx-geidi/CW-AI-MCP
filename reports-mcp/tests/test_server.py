"""Tests for the reports-first MCP server.

Unit tests always run. Integration tests run when RPT_TEST_DSN points at a
database with the rpt schema, connected as the read-only cw_agent role
(reports/test/run-tests.sh sets this up).
"""

import os

import anyio
import psycopg
import pytest

from cw_reports_mcp import server

ALLOWED = {"p_board": "text", "p_months": "integer", "p_limit": "integer"}


class TestBuildReportCall:
    """build_report_call only accepts known rpt functions and parameters, and casts each value."""

    def test_builds_named_arguments_with_casts(self):
        query = server.build_report_call("rpt.ticket_drivers", {"p_board": "Support", "p_months": 6}, ALLOWED)
        text = query.as_string(None)
        assert text == (
            'select * from "rpt"."ticket_drivers"'
            '("p_board" => %(p_board)s::text, "p_months" => %(p_months)s::integer)'
        )

    def test_no_params_calls_with_defaults(self):
        text = server.build_report_call("rpt.backlog", {}, {"p_board": "text"}).as_string(None)
        assert text == 'select * from "rpt"."backlog"()'

    def test_rejects_unknown_parameter(self):
        with pytest.raises(ValueError, match="Unknown parameter"):
            server.build_report_call("rpt.ticket_drivers", {"p_team": "A"}, ALLOWED)

    def test_rejects_injected_parameter_name(self):
        with pytest.raises(ValueError, match="Unknown parameter"):
            server.build_report_call("rpt.ticket_drivers", {"p_board) ; drop table x; --": 1}, ALLOWED)

    def test_rejects_function_outside_rpt(self):
        with pytest.raises(ValueError, match="Invalid report function"):
            server.build_report_call("cw.sales_commission", {}, ALLOWED)

    @pytest.mark.parametrize(
        ("params", "message"),
        [
            ({"p_months": True}, "must be integer"),
            ({"p_months": 6.5}, "must be integer"),
            ({"p_board": ["a", "b"]}, "must be text"),
            ({"p_board": 5}, "must be text"),
            ({"p_months": 25}, "between 1 and 24"),
        ],
    )
    def test_rejects_wrong_json_types(self, params, message):
        with pytest.raises(ValueError, match=message):
            server.build_report_call("rpt.ticket_drivers", params, ALLOWED)

    def test_accepts_integral_float_for_integer(self):
        server.build_report_call("rpt.ticket_drivers", {"p_months": 6.0}, ALLOWED)

    def test_rejects_unexpected_parameter_type(self):
        with pytest.raises(ValueError, match="Unsupported parameter type"):
            server.build_report_call("rpt.x", {"p_a": 1}, {"p_a": "text; drop table y"})


class TestCheckSingleStatement:
    """query_cw accepts exactly one statement."""

    def test_trailing_semicolon_allowed(self):
        assert server.check_single_statement("select 1;") == "select 1"

    def test_second_statement_rejected(self):
        with pytest.raises(ValueError, match="one statement"):
            server.check_single_statement("select 1; commit; delete from cw.x")

    def test_empty_rejected(self):
        with pytest.raises(ValueError, match="Empty"):
            server.check_single_statement("  ;  ")


integration = pytest.mark.skipif(not os.getenv("RPT_TEST_DSN"), reason="RPT_TEST_DSN not set")


@pytest.fixture
def dsn(monkeypatch):
    monkeypatch.setenv("DATABASE_URI", os.environ["RPT_TEST_DSN"])


def _call(tool, *args):
    return anyio.run(tool, *args)


@integration
class TestAgainstDatabase:
    """End to end as cw_agent against the stub database built by reports/test/run-tests.sh."""

    def test_list_reports_returns_catalog_with_parameters(self, dsn):
        result = _call(server.list_reports)
        names = {row["function_name"] for row in result["reports"]}
        assert "rpt.ticket_drivers" in names
        assert len(result["reports"]) == 42
        assert result["data_freshness"] is not None
        drivers = next(r for r in result["reports"] if r["function_name"] == "rpt.ticket_drivers")
        assert "p_months" in drivers["parameters"]

    def test_run_report_by_name(self, dsn):
        result = _call(server.run_report, "Ticket drivers", {"p_board": "Support", "p_months": 6})
        assert result["report"] == "rpt.ticket_drivers"
        assert result["row_count"] == 2

    def test_run_report_by_function_without_prefix(self, dsn):
        result = _call(server.run_report, "utilisation", {"p_team": "%", "p_months": 6})
        assert result["row_count"] == 3

    def test_json_floats_are_cast_to_the_parameter_type(self, dsn):
        result = _call(server.run_report, "client_spikes", {"p_min_tickets": 1, "p_ratio": 1.5})
        assert any(row["company"] == "Acme" for row in result["rows"])
        result = _call(server.run_report, "Ticket drivers", {"p_months": 6.0})
        assert result["row_count"] == 2

    def test_reports_reading_cw_tables_work_as_cw_agent(self, dsn):
        assert _call(server.run_report, "Agreement usage", {"p_months": 6})["row_count"] == 1
        assert _call(server.run_report, "Project hours", {})["row_count"] == 1

    def test_month_window_is_validated(self, dsn):
        with pytest.raises(ValueError, match="between 1 and 24"):
            _call(server.run_report, "Ticket drivers", {"p_months": 0})

    def test_run_report_unknown_name(self, dsn):
        with pytest.raises(ValueError, match="Unknown report"):
            _call(server.run_report, "payroll")

    def test_run_report_rejects_wrong_parameter(self, dsn):
        with pytest.raises(ValueError, match="accepts"):
            _call(server.run_report, "Ticket drivers", {"p_team": "Team A"})

    def test_query_cw_refuses_writes(self, dsn):
        with pytest.raises(psycopg.Error):
            _call(server.query_cw, 'delete from cw."Company"')

    def test_query_cw_reads(self, dsn):
        result = _call(server.query_cw, 'select count(*) as n from cw."Company"')
        assert result["rows"][0]["n"] == 2

    def test_query_cw_caps_rows_without_loading_everything(self, dsn, monkeypatch):
        monkeypatch.setenv("MAX_ROWS", "5")
        result = _call(server.query_cw, "select g from generate_series(1, 5000000) g")
        assert result["row_count"] == 5
        assert result["truncated"] is True
