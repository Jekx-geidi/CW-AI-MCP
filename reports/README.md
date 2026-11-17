# Pre-built CW reports (`rpt` schema) and the reports-first MCP

Goal: the CW MCP answers service desk reporting questions in seconds, from pre-built reports, for any board and any window from 1 to 24 months. It touches the raw ConnectWise tables only for a question no report covers.

Today every question makes the AI write a fresh query against `SR_Service` / `Time_Entry` on the live mirror, and the 6- and 12-month questions regularly hit the 30-second restricted-mode timeout.

## Pieces

| Piece | Where | What |
|---|---|---|
| Report schema | `001_rpt_schema.sql` | Facts, monthly aggregates, core reports, catalog, refresh, grants |
| More reports | `002_rpt_more_reports.sql` | KPIs, SLA detail, queue health, "something is off" reports, pivots |
| Boards and projects | `003_rpt_boards_projects.sql` | All boards side by side; project reporting |
| Reports-first MCP | `../reports-mcp/` | MCP server whose tools are the reports; raw SQL only as a last resort |
| Tests | `test/run-tests.sh` | Builds everything in a throwaway Postgres 17 against stub cw tables, checks every report, re-applies, then runs the MCP server tests |

## How it works

- `rpt.ticket_fact` and `rpt.time_fact` hold one row per ticket / time entry for the last 25 months, with names joined and alerts flagged.
- Monthly aggregates sit on top. A 3-, 6- or 12-month answer is a sum over 3, 6 or 12 rows per group, so every window is fast and there is no table per period.
- Report functions are the interface. They take `p_months` (last N complete months), `p_board` (default `'Support'`, `'%'` for all boards, or any board name or pattern) and `p_team` / `p_who` where relevant.
- `rpt.refresh_all()` refreshes everything; pg_cron runs it hourly. `rpt.freshness` shows when.
- `rpt.catalog` lists every report with what it answers and an example. It is the AI's starting point.

## Reports (42)

**Volume and trend:** `monthly_kpis`, `ticket_volume`, `period_compare` (use 12 for year on year), `tickets_by_day`, `flow` (weekly opened vs closed), `board_overview` (every board side by side).

**What the work is:** `ticket_drivers`, `type_breakdown`, `source_mix`, `top_words`, `automation_candidates`.

**SLA and speed:** `sla_summary`, `response_times`, `sla_breaches`, `responder_stats`.

**People and capacity:** `utilisation`, `team_capacity`, `team_compare`, `tech_productivity`, `tech_workload`, `time_by_category`, `after_hours`.

**Queue health:** `backlog`, `oldest_open`, `zombie_tickets`, `status_ageing`.

**Something is off:** `zero_time_tickets`, `instant_closes`, `multi_tech_tickets` (ping-pong), `top_tickets_by_hours`, `unbilled_time`, `client_spikes`.

**Clients and agreements:** `client_summary`, `agreement_usage`.

**Projects:** `project_hours`, `project_summary`, `project_burn`, `project_team`, `project_tickets`.

**Any combination:** `ticket_pivot(rows, cols, board, months)` over month, board, type, priority, source, company, alerts; `time_pivot(rows, cols, who, months)` over month, tech, team, board, type, company, billable, category.

Run `select report, answers, sql_example from rpt.catalog order by report;` for the full list with examples.

## Reference data (not in ConnectWise)

- `rpt.team_member`: Team A and Team B membership. The second "Mary" in Team A is unconfirmed.
- `rpt.noise_pattern`: summaries that are automated alerts, with the suggested fix. Seeded from the October 2026 Support review; tune against real summaries.
- `rpt.settings`: 160 h monthly capacity, 85% utilisation target.

## Make the reports come first

The reports-first MCP (`../reports-mcp`) has three tools, in this order:

1. `list_reports`: every report, what it answers, its parameters.
2. `run_report(report, params)`: runs one report by name, with validated parameters.
3. `query_cw(query)`: read-only raw SQL, described to the AI as a last resort for new requirements.

Its server instructions tell the AI to use the reports first and to combine them before ever writing raw SQL. Every answer carries the data freshness.

Two ways to deploy it (`cw-deployment/compose.yaml`, profile `reports`):

- **Recommended: make it the endpoint.** Point the `cw-postgres-mcp` Octelium Service at port 8001 (Ivan), so Janus users get reports first with the raw fallback built in. Keep `postgres-mcp` running for schema tools if wanted.
- **Side by side:** register it in Janus as its own server (Chris Jane) and update the `cw-postgres-mcp` description: "For reporting, use cw-reports first. Use this server only when no report fits."

## Steps

1. **Approval.** The `rpt` schema is created on the cw-postgres mirror (data platform owner: Paul). Nothing in the `cw` schema changes. Agree timing with the Supabase migration.
2. **Test locally:** `bash reports/test/run-tests.sh` (Docker; uv for the MCP tests).
3. **Rehearse on a copy of the real data.** Run 001, 002 and 003 in order as the database owner. The roles `cw_agent` and `cw_reader` must exist. Record how long the build and `select rpt.refresh_all();` take.
4. **Check the numbers** against the October 2026 review (Support board, 23 Apr to 22 Oct 2026): about 24,648 tickets, about 6,720 hours, about 11,114 alert tickets. Spot-check one month of SLA in ConnectWise.
5. **Tune the noise patterns:** `select * from rpt.automation_candidates('Support', 6, 10);`, then move any unflagged alert into `rpt.noise_pattern`.
6. **Schedule:** `select cron.schedule('rpt-refresh', '15 * * * *', 'select rpt.refresh_all()');`
7. **Deploy the reports MCP** (see above) and test through Janus: each catalog example should answer in under 5 seconds.

## Notes and limits

- `p_months` is 1 to 24 (history is 25 months); `period_compare` goes up to 12. Anything else is rejected with a clear error.
- Windows are complete months. These also include the current month to date: `monthly_kpis`, `ticket_volume`, `project_burn`, `sla_breaches`. `tickets_by_day` and `flow` include today and the current week.
- Hours on tickets cover time logged in the last 25 months. The ticket snapshot also keeps every ticket that is still open, however old, so the backlog reports are complete.
- SLA figures use ConnectWise's own due dates and business minutes. A ticket counts once its SLA is decided: stopped (responded, resolved, or closed) or open and past due. A closed ticket without a resolved date uses its close time.
- Alerts ("noise") are tickets whose summary matches `rpt.noise_pattern`, plus every ticket on a board in `rpt.noise_board` (seeded: RMM Alerts). SLA, KPI and board reports exclude them.
- Utilisation and capacity count work only. Leave charge codes (`rpt.leave_charge_code`: leave, holiday, sick, bereavement) are reported separately and reduce available capacity.
- ConnectWise stores local Perth time for ticket and time entry dates; the reports use Perth time for "now", "today" and month boundaries (`rpt.local_now()`), and UTC only for SLA dates.
- Re-running: always run 001, 002 and 003 together. 001 drops and recreates every rpt function so no old version is left behind.
- Access: `cw_agent` and `cw_reader` need `select` on the `cw` tables (the project and agreement reports read them directly) and are granted `select` / `execute` on `rpt`. Only the owner can run `rpt.refresh_all()`.
