-- Pre-built ConnectWise reports, part 3: every board side by side, and
-- project reporting. Run after 001 and 002. Safe to re-run.
--
-- Board filter: every ticket report takes p_board. It defaults to 'Support'
-- (the main board) or '%' (all boards); pass any board name, or a pattern
-- such as 'Infra%'. rpt.board_overview lists the board names.

begin;

-- ---------------------------------------------------------------------------
-- Boards
-- ---------------------------------------------------------------------------

create or replace function rpt.board_overview(
    p_months  integer default 6
)
returns table (
    board text, tickets bigint, tickets_excl_alerts bigint, alert_pct numeric,
    hours numeric, hours_per_ticket numeric, respond_sla_pct numeric,
    resolve_sla_pct numeric, avg_hours_to_close numeric, open_now bigint
)
language sql
stable
as $$
    with t as (
        select board,
               sum(opened) as tickets,
               coalesce(sum(opened) filter (where not is_noise), 0) as real_tickets,
               sum(respond_sla_met) filter (where not is_noise) as rm,
               sum(respond_sla_n)   filter (where not is_noise) as rn,
               sum(resolve_sla_met) filter (where not is_noise) as sm,
               sum(resolve_sla_n)   filter (where not is_noise) as sn,
               sum(close_hours_sum) filter (where not is_noise) as chs,
               sum(close_hours_n)   filter (where not is_noise) as chn
        from rpt.ticket_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
        group by board
    ),
    h as (
        select board, sum(hours) as hours
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
        group by board
    ),
    o as (
        select board, sum(tickets) as open_now
        from rpt.open_backlog
        group by board
    )
    select t.board, t.tickets::bigint, t.real_tickets::bigint,
           round(100.0 * (t.tickets - t.real_tickets) / nullif(t.tickets, 0), 1),
           round(coalesce(h.hours, 0), 1),
           round(coalesce(h.hours, 0) / nullif(t.real_tickets, 0), 2),
           round(100.0 * t.rm / nullif(t.rn, 0), 1),
           round(100.0 * t.sm / nullif(t.sn, 0), 1),
           round((t.chs / nullif(t.chn, 0))::numeric, 1),
           coalesce(o.open_now, 0)::bigint
    from t
    left join h using (board)
    left join o using (board)
    order by coalesce(h.hours, 0) desc
$$;
comment on function rpt.board_overview(integer) is
  'Every board side by side: tickets, alert share, hours, SLA, time to close and open now. Also lists the board names to use as p_board. Example: select * from rpt.board_overview(6);';


-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

create or replace function rpt.project_summary(
    p_board  text default '%'
)
returns table (
    status text, projects bigint, estimated_hours numeric, hours_last_25_months numeric,
    over_estimate bigint, overdue bigint, open_tickets bigint
)
language sql
stable
as $$
    select status, count(*)::bigint,
           round(coalesce(sum(estimated_hours), 0), 1),
           round(coalesce(sum(hours_last_25_months), 0), 1),
           count(*) filter (where hours_last_25_months > estimated_hours)::bigint,
           count(*) filter (where days_overdue > 0)::bigint,
           coalesce(sum(open_tickets), 0)::bigint
    from rpt.project_hours(false, p_board)
    group by status
    order by count(*) desc
$$;
comment on function rpt.project_summary(text) is
  'Projects by status: count, estimated vs actual hours, how many are over estimate or overdue. Example: select * from rpt.project_summary();';


create or replace function rpt.project_burn(
    p_project  text    default '%',
    p_months   integer default 6
)
returns table (
    month date, project text, hours numeric, billable_hours numeric, cumulative_hours numeric
)
language sql
stable
as $$
    select m.month, p."Project_ID", round(m.hours, 1), round(m.billable_hours, 1),
           round(sum(m.hours) over (partition by m.project_id order by m.month), 1)
    from rpt.project_monthly m
    join cw."PM_Project" p on p."PM_Project_RecID" = m.project_id
    where m.month >= (select rpt.window_start(p_months))
      and p."Project_ID" ilike p_project
    order by p."Project_ID", m.month
$$;
comment on function rpt.project_burn(text, integer) is
  'Hours burned per project per month, with a running total over the window (current month included). Example: select * from rpt.project_burn(''%Migration%'', 6);';


create or replace function rpt.project_team(
    p_project  text    default '%',
    p_months   integer default 6
)
returns table (
    project text, team text, member_name text, hours numeric, share_of_project_pct numeric
)
language sql
stable
as $$
    with w as (
        select p."Project_ID" as project, f.team, f.member_name, sum(f.hours) as hours
        from rpt.time_fact f
        join cw."PM_Project" p on p."PM_Project_RecID" = f.project_id
        where f.month >= (select rpt.window_start(p_months))
          and f.month <  rpt.current_month()
          and p."Project_ID" ilike p_project
        group by 1, 2, 3
    )
    select project, team, member_name, round(hours, 1),
           round(100.0 * hours / nullif(sum(hours) over (partition by project), 0), 1)
    from w
    order by project, hours desc
$$;
comment on function rpt.project_team(text, integer) is
  'Who works on each project and their share of its hours. Example: select * from rpt.project_team(''%'', 3);';


create or replace function rpt.project_tickets(
    p_project  text default '%'
)
returns table (
    project text, open_tickets bigint, closed_tickets bigint,
    oldest_open_at timestamp, hours numeric
)
language sql
stable
as $$
    select p."Project_ID",
           count(*) filter (where not f.is_closed)::bigint,
           count(*) filter (where f.is_closed)::bigint,
           min(f.opened_at) filter (where not f.is_closed),
           round(coalesce(sum(h.hours), 0), 1)
    from rpt.ticket_fact f
    join cw."PM_Project" p on p."PM_Project_RecID" = f.project_id
    left join rpt.ticket_hours h using (ticket_id)
    where p."Project_ID" ilike p_project
    group by p."Project_ID"
    order by 2 desc
$$;
comment on function rpt.project_tickets(text) is
  'Project tickets per project: open, closed, oldest open and hours (tickets from the last 25 months). Example: select * from rpt.project_tickets();';


-- ---------------------------------------------------------------------------
-- Catalog and access
-- ---------------------------------------------------------------------------

insert into rpt.catalog (report, function_name, answers, sql_example, owner) values
    ('Board overview',  'rpt.board_overview',  'All boards side by side; lists board names for p_board.', 'select * from rpt.board_overview(6);',              'Service desk'),
    ('Project summary', 'rpt.project_summary', 'Projects by status: hours vs estimate, over budget, overdue.', 'select * from rpt.project_summary();',          'Projects'),
    ('Project burn',    'rpt.project_burn',    'Hours per project per month with running total.',        'select * from rpt.project_burn(''%'', 6);',          'Projects'),
    ('Project team',    'rpt.project_team',    'Who works on each project.',                             'select * from rpt.project_team(''%'', 3);',          'Projects'),
    ('Project tickets', 'rpt.project_tickets', 'Open and closed tickets per project.',                   'select * from rpt.project_tickets();',               'Projects')
on conflict (report) do nothing;

update rpt.catalog
set answers = 'Every project: due date, overdue days, estimated vs actual hours, % complete, open tickets.',
    sql_example = 'select * from rpt.project_hours(true, ''%'');'
where report = 'Project hours';

grant execute on all functions in schema rpt to cw_agent, cw_reader;
revoke execute on function rpt.refresh_all() from public, cw_agent, cw_reader;

commit;
