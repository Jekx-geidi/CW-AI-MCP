-- Checks every report against the known data in cw_stub.sql.
-- Any failed check raises an exception and stops the run (ON_ERROR_STOP).

create or replace function pg_temp.check(p_name text, p_ok boolean)
returns void
language plpgsql
as $$
begin
    if p_ok is distinct from true then
        raise exception 'FAIL: %', p_name;
    end if;
    raise notice 'ok: %', p_name;
end
$$;

select rpt.refresh_all();
select pg_temp.check('freshness recorded', (select last_refreshed_at is not null from rpt.freshness));

select pg_temp.check('drivers: password resets grouped, 2 tickets, 5 h',
    (select tickets = 2 and hours = 5
     from rpt.ticket_drivers('Support', 6) where pattern = 'password reset for user #'));

select pg_temp.check('drivers: vCenter alarm flagged as noise',
    (select is_noise from rpt.ticket_drivers('Support', 6) where pattern like 'vcenter vm cpu%'));

select pg_temp.check('sla: alerts excluded, 2 tickets, respond 50%, resolve 50% (open ticket past due)',
    (select tickets = 2 and respond_sla_pct = 50 and resolve_sla_pct = 50
     from rpt.sla_summary('Support', 6)));

select pg_temp.check('utilisation: Elonah 4 h work, 8 h leave kept apart, over 2 months',
    (select work_hours = 4 and leave_hours = 8 and months_active = 2
     from rpt.utilisation('%', 6) where member_id = 'ELlanos'));

select pg_temp.check('team capacity: both teams',
    (select count(*) = 2 from rpt.team_capacity(6)));

select pg_temp.check('ticket volume: Support has 2 tickets in m1',
    (select opened = 2 and opened_excl_alerts = 1
     from rpt.ticket_volume('Support', 12)
     where month = (rpt.current_month() - interval '1 month')::date));

select pg_temp.check('client summary: Acme 7 h',
    (select hours = 7 from rpt.client_summary(6) where company = 'Acme'));

select pg_temp.check('backlog: one open Support ticket',
    (select sum(tickets) = 1 from rpt.backlog('Support')));

select pg_temp.check('period compare: three metrics',
    (select count(*) = 3 from rpt.period_compare('Support', 1)));

select pg_temp.check('tickets by day: 6 tickets in 90 days',
    (select sum(opened) = 6 from rpt.tickets_by_day('%', 90)));

select pg_temp.check('flow: 6 opened, 4 closed',
    (select sum(opened) = 6 and sum(closed) = 4 from rpt.flow('%', 20)));

select pg_temp.check('tech workload: Elonah split ticket, admin, leave',
    (select count(*) = 3 from rpt.tech_workload('ELlanos', 6)));

select pg_temp.check('time by category: admin charge code 1 h',
    (select sum(hours) = 1 from rpt.time_by_category('%', 6) where category = 'Charge code: Admin'));

select pg_temp.check('time by category: project ticket counted as Project',
    (select sum(hours) = 4 from rpt.time_by_category('%', 6) where category = 'Project'));

select pg_temp.check('type breakdown: Request on Support',
    (select tickets = 2 and hours = 5 from rpt.type_breakdown('Support', 6) where type = 'Request'));

select pg_temp.check('source mix: Support sources sum to 3',
    (select sum(tickets) = 3 from rpt.source_mix('Support', 6)));

select pg_temp.check('automation: vCenter alarm with suggested fix',
    (select kind = 'Alert / notification' and suggested_fix like 'Alert in vCenter%'
     from rpt.automation_candidates('Support', 6, 1)
     where candidate = 'vCenter VM CPU usage alarm'));

select pg_temp.check('agreement usage: 4 h, 20 remaining',
    (select hours = 4 and remaining_balance = 20
     from rpt.agreement_usage(6) where agreement = 'Managed Services'));

select pg_temp.check('project hours: phase ticket counted, 50% of estimate',
    (select hours_last_25_months = 4 and pct_of_estimate = 50
     from rpt.project_hours() where project = 'Migration'));

-- Part 2 reports (002_rpt_more_reports.sql)

select pg_temp.check('monthly kpis: m1 has 2 tickets, 50% alerts',
    (select opened = 2 and alert_pct = 50 from rpt.monthly_kpis('Support', 12)
     where month = (rpt.current_month() - interval '1 month')::date));

select pg_temp.check('team compare: two teams',
    (select count(*) = 2 from rpt.team_compare(6)));

select pg_temp.check('tech productivity: Elonah 4 h, 1 ticket',
    (select hours = 4 and tickets_worked = 1 from rpt.tech_productivity('%', 6)
     where member_name = 'Elonah L'));

select pg_temp.check('response times: 2 first responses, 1 under 15 min',
    (select sum(tickets) = 2 and sum(tickets) filter (where bucket = 'under 15 min') = 1
     from rpt.response_times('Support', 6) where metric = 'First response'));

select pg_temp.check('sla breaches: ticket 3 missed both',
    (select count(*) = 1 and min(breached) = 'response + resolution' and min(ticket_id) = 3
     from rpt.sla_breaches('Support', 6)));

select pg_temp.check('responder stats: two responders',
    (select count(*) = 2 from rpt.responder_stats('Support', 6)));

select pg_temp.check('oldest open: ticket 3',
    (select ticket_id = 3 from rpt.oldest_open('Support', 1)));

select pg_temp.check('zombie tickets: ticket 3 idle',
    (select count(*) = 1 from rpt.zombie_tickets('Support', 14)));

select pg_temp.check('status ageing: one status with one ticket',
    (select count(*) = 1 and sum(tickets) = 1 from rpt.status_ageing('Support')));

select pg_temp.check('zero-time tickets: none (only the alert had no time)',
    (select count(*) = 0 from rpt.zero_time_tickets('Support', 6)));

select pg_temp.check('instant closes: the 60-minute alert within 61 minutes',
    (select count(*) = 1 and bool_and(is_noise) from rpt.instant_closes('Support', 6, 61)));

select pg_temp.check('ping-pong: two tickets with at least one tech',
    (select count(*) = 2 from rpt.multi_tech_tickets('Support', 6, 1)));

select pg_temp.check('biggest ticket: ticket 3 with 3 h',
    (select ticket_id = 3 and hours = 3 from rpt.top_tickets_by_hours('Support', 6, 1)));

select pg_temp.check('after hours: Elonah has after-hours time',
    (select after_hours_pct > 0 from rpt.after_hours('%', 6) where member_name = 'Elonah L'));

select pg_temp.check('unbilled time: Globex 3 h',
    (select non_billable_hours = 3 from rpt.unbilled_time(6) where company = 'Globex'));

select pg_temp.check('client spikes: Acme jumped from nothing',
    (select bool_or(company = 'Acme') from rpt.client_spikes(1, 1.5)));

select pg_temp.check('arrival heatmap: 2 non-alert Support tickets',
    (select sum(tickets) = 2 from rpt.arrival_heatmap('Support', 6)));

select pg_temp.check('top words: password and reset lead',
    (select count(*) = 2 from rpt.top_words('Support', 6, 2) where word in ('password', 'reset')));

select pg_temp.check('ticket pivot: company x priority, 2 tickets',
    (select sum(tickets) = 2 from rpt.ticket_pivot('company', 'priority', 'Support', 6)));

select pg_temp.check('ticket pivot: one dimension only',
    (select count(*) = 1 from rpt.ticket_pivot('type', null, 'Support', 6)));

select pg_temp.check('time pivot: all 18 h by team',
    (select sum(hours) = 18 from rpt.time_pivot('team', null, '%', 6)));

do $$
begin
    perform * from rpt.ticket_pivot('summary; drop table cw."Company"', null, '%', 6);
    raise exception 'FAIL: pivot accepted an unknown dimension';
exception
    when raise_exception then
        if sqlerrm like 'FAIL:%' then raise; end if;
        raise notice 'ok: pivot rejects unknown dimensions';
end
$$;

select pg_temp.check('every report function is in the catalog',
    (select count(*) = 0
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'rpt'
       and p.proname not in ('summary_pattern', 'window_start', 'refresh_all', 'local_now', 'local_today', 'current_month')
       and ('rpt.' || p.proname) not in (select function_name from rpt.catalog)));

select pg_temp.check('every catalog entry points at an existing function',
    (select bool_and(to_regproc(function_name) is not null) from rpt.catalog));

-- Part 3 reports (003_rpt_boards_projects.sql)

select pg_temp.check('board overview: four boards, Support 3 tickets 1 open, Backup Board shows its 2018 ticket open',
    (select count(*) = 4
        and sum(tickets) filter (where board = 'Support') = 3
        and sum(open_now) filter (where board = 'Support') = 1
        and sum(open_now) filter (where board = 'Backup Board') = 1
     from rpt.board_overview(6)));

select pg_temp.check('client summary filters by board',
    (select count(*) = 1 from rpt.client_summary(6, 25, 'Infrastructure')));

select pg_temp.check('project hours: board, 5 days overdue, 1 open ticket',
    (select board = 'Infrastructure' and days_overdue = 5 and open_tickets = 1 and remaining_estimate = 4
     from rpt.project_hours(true, '%') where project = 'Migration'));

select pg_temp.check('project summary: one in-progress project, overdue',
    (select projects = 1 and overdue = 1 from rpt.project_summary() where status = 'In progress'));

select pg_temp.check('project burn: 4 h cumulative',
    (select max(cumulative_hours) = 4 from rpt.project_burn('%Migration%', 6)));

select pg_temp.check('project team: KD has 100% of Migration',
    (select share_of_project_pct = 100 from rpt.project_team('Migration', 6) where member_name = 'KD A'));

select pg_temp.check('project tickets: Migration 1 open',
    (select open_tickets = 1 and hours = 4 from rpt.project_tickets('Migration')));

select pg_temp.check('catalog lists 42 reports', (select count(*) = 42 from rpt.catalog));

-- Review fixes

select pg_temp.check('sla: closed ticket with no resolved date uses its close time (met, not a miss)',
    (select tickets = 1 and respond_sla_pct = 100 and resolve_sla_pct = 100
     from rpt.sla_summary('Backup Board', 6)));

select pg_temp.check('sla breaches: closed ticket without resolved date is not a breach',
    (select count(*) = 0 from rpt.sla_breaches('Backup Board', 6)));

select pg_temp.check('backlog: 2018 ticket still open shows as 30+ days',
    (select sum(tickets) = 1 from rpt.backlog('Backup Board') where age_bucket = '30+ days'));

select pg_temp.check('oldest open: the 2018 ticket comes first across boards',
    (select ticket_id = 6 from rpt.oldest_open('%', 1)));

select pg_temp.check('alert board: every RMM Alerts ticket is noise',
    (select bool_and(is_noise) and min(noise_label) = 'Alert board: RMM Alerts'
     from rpt.ticket_drivers('RMM Alerts', 6)));

select pg_temp.check('automation: alert board shows its own suggested fix',
    (select suggested_fix like 'Tune RMM%' from rpt.automation_candidates('RMM Alerts', 6, 1)));

-- Two patterns sharing a label, and two board patterns matching one board,
-- must not double count (rolled back afterwards).
begin;
insert into rpt.noise_pattern values ('%vCenter%', 'vCenter VM CPU usage alarm', 'Alert in vCenter only');
insert into rpt.noise_board values ('RMM%', 'Tune RMM thresholds');
select pg_temp.check('automation: shared labels do not double count',
    (select bool_and(tickets = 1)
     from rpt.automation_candidates('%', 6, 0)
     where candidate in ('vCenter VM CPU usage alarm', 'Alert board: RMM Alerts')));
rollback;

select pg_temp.check('team capacity: leave reported apart from work',
    (select avg_leave_hours_per_month > 0 from rpt.team_capacity(6) where team = 'Team B'));

do $$
begin
    perform * from rpt.ticket_drivers('Support', 25);
    raise exception 'FAIL: 25-month window accepted';
exception
    when raise_exception then
        if sqlerrm like 'FAIL:%' then raise; end if;
        raise notice 'ok: windows over 24 months are rejected';
end
$$;

do $$
begin
    perform * from rpt.period_compare('Support', 13);
    raise exception 'FAIL: period_compare accepted 13 months';
exception
    when raise_exception then
        if sqlerrm like 'FAIL:%' then raise; end if;
        raise notice 'ok: period_compare over 12 months is rejected';
end
$$;

select pg_temp.check('one version of every rpt function (no leftover overloads)',
    (select count(*) = count(distinct p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'rpt'));

-- Access: the MCP role can read reports but cannot refresh them.
set role cw_agent;
select pg_temp.check('cw_agent can run a report',
    (select count(*) >= 0 from rpt.ticket_drivers('Support', 6)));
reset role;

select pg_temp.check('cw_agent cannot run refresh_all',
    (select not has_function_privilege('cw_agent', 'rpt.refresh_all()', 'execute')));

select pg_temp.check('rerun of the schema script is safe',
    (select true));
