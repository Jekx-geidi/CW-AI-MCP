-- Pre-built ConnectWise reports (schema rpt).
--
-- Purpose: let the CW MCP (and PostgREST) answer the common reporting
-- questions in milliseconds instead of re-scanning SR_Service / Time_Entry
-- every time. The MCP's restricted mode stops any query after 30 s, and the
-- 6- and 12-month questions regularly hit that limit.
--
-- Design:
--   * Two fact snapshots (tickets, time) over a rolling 25 months.
--   * Monthly aggregates on top of them. Any window (3, 6, 12 months, a
--     single month, this year vs last) is a cheap SUM over monthly rows, so
--     there is one table per subject, not one per period.
--   * Report functions (rpt.ticket_drivers, rpt.sla_summary, ...) are the
--     interface the AI calls. Each takes p_months and returns finished rows.
--   * rpt.refresh_all() refreshes everything; pg_cron runs it hourly.
--   * rpt.catalog describes every report so the AI finds it first.
--
-- Run as the database owner (not cw_agent). Needs Paul's approval: this
-- writes to the cw-postgres mirror. Nothing here touches the cw schema.
--
-- STATUS: draft, not yet run. Validate on a rehearsal copy first and compare
-- the totals with the checks in reports/README.md.

begin;

create schema if not exists rpt;
comment on schema rpt is
  'Pre-built ConnectWise reports. Start with: select * from rpt.catalog;';

-- Re-runs start clean: drop every rpt function so a changed signature never
-- leaves an old overload behind. Always run 001, 002 and 003 together.
do $$
declare
    v_fn regprocedure;
begin
    for v_fn in
        select p.oid::regprocedure
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'rpt'
    loop
        execute format('drop function %s cascade', v_fn);
    end loop;
end
$$;


-- ---------------------------------------------------------------------------
-- Reference data that ConnectWise does not hold
-- ---------------------------------------------------------------------------

create table if not exists rpt.team_member (
    member_id  text primary key,          -- cw."Member"."Member_ID"
    team       text not null,
    is_lead    boolean not null default false
);
comment on table rpt.team_member is
  'Support team membership (not stored in ConnectWise). Maintained by the service desk manager.';

insert into rpt.team_member (member_id, team, is_lead) values
    ('TOtayco',    'Team A', true),
    ('MTapayan',   'Team A', false),
    ('KDAbellana', 'Team A', false),
    ('MCatason',   'Team A', false),
    ('MHussain',   'Team A', false),
    ('ZUndang',    'Team A', false),
    ('JOuano',     'Team B', true),
    ('CQuinto',    'Team B', false),
    ('ELlanos',    'Team B', false),
    ('IElemino',   'Team B', false),
    ('Jamad',      'Team B', false)
on conflict (member_id) do nothing;
-- TODO: second "Mary" in Team A is unconfirmed (possibly MArcibal).

create table if not exists rpt.settings (
    key    text primary key,
    value  numeric not null,
    note   text
);

insert into rpt.settings (key, value, note) values
    ('monthly_capacity_hours', 160,  'Hours per tech per month'),
    ('target_utilisation',     0.85, 'Healthy utilisation target')
on conflict (key) do nothing;

create table if not exists rpt.noise_pattern (
    pattern        text primary key,      -- ILIKE pattern on the ticket summary
    label          text not null,
    suggested_fix  text
);
comment on table rpt.noise_pattern is
  'Ticket summaries that are automated alerts or notifications, not user requests.';

insert into rpt.noise_pattern (pattern, label, suggested_fix) values
    ('%VM CPU usage%',                    'vCenter VM CPU usage alarm',            'Alert in vCenter only; ticket after 30 min sustained'),
    ('%Zabbix%',                          'Zabbix alerts and recoveries',          'Auto-close recoveries; dedupe repeat triggers'),
    ('%Email Robot%',                     'Email Robot utility errors',            'Fix the robot; drop these emails'),
    ('%UserCentric%',                     'UserCentric sync reports',              'Retire: replaced by the portal Managed Users report'),
    ('%Delivery Status Notification%',    'Delivery status notification',          'Drop at email connector'),
    ('%offline server%',                  'LT offline servers monitor',            'Dedupe with Zabbix'),
    ('%directory sync%',                  'Proofpoint directory sync',             'Drop at email connector'),
    ('%quarantine digest%',               'Proofpoint quarantine digest',          'End-user self-release'),
    ('%PolicyPak%',                       'PolicyPak licence threshold',           'Route to admin, not Support'),
    ('%lost call%',                       '3CX lost call in queue',                'Daily digest instead of tickets'),
    ('%DRV free space%',                  'Low disk space',                        'Auto cleanup script, then re-check'),
    ('%drift%',                           'Config drift notifications',            'Daily digest; ticket on unexpected change')
on conflict (pattern) do nothing;

create table if not exists rpt.noise_board (
    board_pattern  text primary key,      -- ILIKE pattern on the board name
    suggested_fix  text
);
comment on table rpt.noise_board is
  'Boards whose tickets are all automated alerts (every ticket on them counts as noise).';

insert into rpt.noise_board (board_pattern, suggested_fix) values
    ('RMM Alerts', 'Tune RMM thresholds; auto-close recoveries')
on conflict (board_pattern) do nothing;

create table if not exists rpt.leave_charge_code (
    pattern  text primary key             -- ILIKE pattern on the charge code name
);
comment on table rpt.leave_charge_code is
  'Charge codes that are leave, not work. Excluded from utilisation and capacity demand.';

insert into rpt.leave_charge_code (pattern) values
    ('%Leave%'), ('%Holiday%'), ('%Sick%'), ('%Bereavement%')
on conflict (pattern) do nothing;


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Groups summaries that differ only by numbers/IDs ("Ticket #12345 ...").
create or replace function rpt.summary_pattern(p_summary text)
returns text
language sql
immutable
as $$
    select left(
        trim(regexp_replace(
            regexp_replace(lower(coalesce(p_summary, '')), '[0-9]+', '#', 'g'),
            '\s+', ' ', 'g')),
        120)
$$;

-- ConnectWise stores local (Perth) times for ticket and time entry dates,
-- while the database clock runs in UTC. All "now", "today" and month
-- boundaries for local columns go through these helpers.
create or replace function rpt.local_now()
returns timestamp
language sql
stable
as $$
    select (now() at time zone 'Australia/Perth')::timestamp
$$;

create or replace function rpt.local_today()
returns date
language sql
stable
as $$
    select rpt.local_now()::date
$$;

-- First day of the current (incomplete) month, local time.
create or replace function rpt.current_month()
returns date
language sql
stable
as $$
    select date_trunc('month', rpt.local_now())::date
$$;

-- First day of the window covering the last p_months COMPLETE months.
-- History is 25 months, so windows are limited to 1-24 months.
create or replace function rpt.window_start(p_months integer)
returns date
language plpgsql
stable
as $$
begin
    if p_months is null or p_months < 1 or p_months > 24 then
        raise exception 'p_months must be between 1 and 24 (history kept: 25 months), got %', p_months;
    end if;
    return (rpt.current_month() - make_interval(months => p_months))::date;
end
$$;


-- ---------------------------------------------------------------------------
-- Fact snapshots (rolling 25 months)
-- ---------------------------------------------------------------------------

drop materialized view if exists rpt.ticket_fact cascade;
create materialized view rpt.ticket_fact as
select
    s."SR_Service_RecID"                                   as ticket_id,
    date_trunc('month', s."Date_Entered")::date            as month_opened,
    date_trunc('month', s."Date_Closed")::date             as month_closed,
    s."Date_Entered"                                       as opened_at,
    s."Date_Closed"                                        as closed_at,
    coalesce(b."Board_Name", '(none)')                     as board,
    coalesce(t."Description", '(none)')                    as type,
    coalesce(st."Description", '(none)')                   as subtype,
    coalesce(u."Description", '(none)')                    as priority,
    coalesce(src."Description", '(none)')                  as source,
    coalesce(c."Company_Name", '(none)')                   as company,
    coalesce(stat."Description", '(none)')                 as status,
    -- IsClosed_Flag is unreliable; use the close date or a closed status.
    (s."Date_Closed" is not null or coalesce(stat."Closed_Flag", false)) as is_closed,
    tph."PM_Project_RecID"                                 as project_id,
    s."Summary"                                            as summary,
    rpt.summary_pattern(s."Summary")                       as pattern,
    coalesce(np.label, nb.label)                           as noise_label,
    (np.label is not null or nb.label is not null)         as is_noise,
    s."Date_Entered_UTC"                                   as opened_at_utc,
    s."Date_Closed_UTC"                                    as closed_at_utc,
    w."Date_Responded_UTC"                                 as responded_at_utc,
    w."Date_Resolved_UTC"                                  as resolved_at_utc,
    -- SLA clock stops: closed tickets without a resolved (or responded) date
    -- use their close time instead of counting as an ever-growing miss.
    coalesce(w."Date_Resolved_UTC",
             case when s."Date_Closed" is not null then s."Date_Closed_UTC" end) as resolve_stop_utc,
    coalesce(w."Date_Responded_UTC", w."Date_Resolved_UTC",
             case when s."Date_Closed" is not null then s."Date_Closed_UTC" end) as respond_stop_utc,
    -- ConnectWise's own SLA clock (business minutes, excludes waiting time).
    w."Responded_Minutes"                                  as responded_minutes,
    w."Resolved_Minutes"                                   as resolved_minutes,
    w."Responded_By"                                       as responded_by,
    w."Resolved_By"                                        as resolved_by,
    w."Date_Status_Changed_UTC"                            as status_changed_at_utc,
    calc."Expected_Responded_Expiration_Date_UTC"          as respond_due_utc,
    calc."Expected_Resolution_Expiration_Date_UTC"         as resolve_due_utc
from cw."SR_Service" s
left join cw."SR_Board"   b    on b."SR_Board_RecID"     = s."SR_Board_RecID"
left join cw."SR_Type"    t    on t."SR_Type_RecID"      = s."SR_Type_RecID"
left join cw."SR_SubType" st   on st."SR_SubType_RecID"  = s."SR_SubType_RecID"
left join cw."SR_Urgency" u    on u."SR_Urgency_RecID"   = s."SR_Urgency_RecID"
left join cw."SR_Source"  src  on src."SR_Source_RecID"  = s."SR_Source_RecID"
left join cw."Company"    c    on c."Company_RecID"      = s."Company_RecID"
left join cw."SR_Status"  stat on stat."SR_Status_RecID" = s."SR_Status_RecID"
left join cw."SR_Service_SLA_Workflow" w on w."SR_Service_RecID"    = s."SR_Service_RecID"
left join cw."SR_Service_Calculated"   calc on calc."SR_Service_RecID" = s."SR_Service_RecID"
left join cw."PM_Phase"                tph  on tph."PM_Phase_RecID"     = s."PM_Phase_RecID"
left join lateral (
    select n.label
    from rpt.noise_pattern n
    where s."Summary" ilike n.pattern
    order by n.pattern
    limit 1
) np on true
left join lateral (
    select 'Alert board: ' || b."Board_Name" as label
    from rpt.noise_board nb
    where b."Board_Name" ilike nb.board_pattern
    limit 1
) nb on true
-- Last 25 months, plus anything closed in that time and every ticket still
-- open, however old, so the backlog and closures are complete.
where s."Date_Entered" >= rpt.current_month() - interval '25 months'
   or s."Date_Closed"  >= rpt.current_month() - interval '25 months'
   or (s."Date_Closed" is null and not coalesce(stat."Closed_Flag", false));

create unique index on rpt.ticket_fact (ticket_id);
create index on rpt.ticket_fact (month_opened, board);
create index on rpt.ticket_fact (board) where not is_closed;


drop materialized view if exists rpt.time_fact cascade;
create materialized view rpt.time_fact as
select
    te."Time_RecID"                                        as time_id,
    date_trunc('month', te."Date_Start")::date             as month,
    te."Date_Start"::date                                  as work_date,
    te."Time_Start"                                        as time_start,
    te."Member_ID"                                         as member_id,
    coalesce(nullif(trim(concat_ws(' ', m."First_Name", m."Last_Name")), ''), te."Member_ID") as member_name,
    coalesce(tm.team, '(no team)')                         as team,
    coalesce(te."Hours_Actual", 0)                         as hours,
    coalesce(te."Billable_Flag", false)                    as billable,
    coalesce(te."Charge_To_Type", '(none)')                as charge_to_type,
    coalesce(cc."Description", '(none)')                   as charge_code,
    -- Where the time went: a service ticket, a project, or a charge code
    -- (admin, meetings, training, leave ...).
    case
        when te."SR_Service_RecID" is not null and s."PM_Phase_RecID" is null then 'Service ticket'
        when te."PM_Project_RecID" is not null or s."PM_Phase_RecID" is not null then 'Project'
        when cc."Description" is not null then 'Charge code: ' || cc."Description"
        else 'Other'
    end                                                    as category,
    exists (select 1 from rpt.leave_charge_code l
            where cc."Description" ilike l.pattern)        as is_leave,
    te."SR_Service_RecID"                                  as ticket_id,
    -- Project tickets carry the project on their phase, not on the entry.
    coalesce(te."PM_Project_RecID", ph."PM_Project_RecID") as project_id,
    te."Agr_Header_RecID"                                  as agreement_id,
    coalesce(b."Board_Name", '(none)')                     as board,
    coalesce(t."Description", '(none)')                    as type,
    coalesce(c."Company_Name", '(none)')                   as company
from cw."Time_Entry" te
left join cw."Member"         m  on m."Member_ID"              = te."Member_ID"
left join rpt.team_member     tm on tm.member_id               = te."Member_ID"
left join cw."SR_Service"     s  on s."SR_Service_RecID"       = te."SR_Service_RecID"
left join cw."SR_Board"       b  on b."SR_Board_RecID"         = s."SR_Board_RecID"
left join cw."SR_Type"        t  on t."SR_Type_RecID"          = s."SR_Type_RecID"
left join cw."Company"        c  on c."Company_RecID"          = te."Company_RecID"
left join cw."TE_Charge_Code" cc on cc."TE_Charge_Code_RecID"  = te."TE_Charge_Code_RecID"
left join cw."PM_Phase"       ph on ph."PM_Phase_RecID"        = s."PM_Phase_RecID"
where te."Date_Start" >= rpt.current_month() - interval '25 months';

create unique index on rpt.time_fact (time_id);
create index on rpt.time_fact (month, member_id);
create index on rpt.time_fact (ticket_id);


-- ---------------------------------------------------------------------------
-- Monthly aggregates
-- ---------------------------------------------------------------------------

-- Ticket volume, closure and SLA by month opened.
create materialized view rpt.ticket_monthly as
select
    month_opened as month, board, type, priority, source, company, is_noise,
    count(*)                                                   as opened,
    count(*) filter (where is_closed)                          as closed,
    count(*) filter (where not is_closed)                      as still_open,
    sum(date_part('epoch', closed_at - opened_at) / 3600.0)
        filter (where closed_at is not null)                   as close_hours_sum,
    count(*) filter (where closed_at is not null)              as close_hours_n,
    -- An SLA counts once it is decided: the clock stopped (responded,
    -- resolved or closed), or an open ticket is past due. Open tickets not yet
    -- due, and closed tickets with no stop time at all, are left out.
    count(*) filter (where respond_due_utc is not null
                       and (respond_stop_utc is not null
                            or (not is_closed and respond_due_utc < now() at time zone 'utc')))
                                                                              as respond_sla_n,
    count(*) filter (where respond_stop_utc <= respond_due_utc)               as respond_sla_met,
    count(*) filter (where resolve_due_utc is not null
                       and (resolve_stop_utc is not null
                            or (not is_closed and resolve_due_utc < now() at time zone 'utc')))
                                                                              as resolve_sla_n,
    count(*) filter (where resolve_stop_utc <= resolve_due_utc)               as resolve_sla_met
from rpt.ticket_fact
group by 1, 2, 3, 4, 5, 6, 7;

create unique index on rpt.ticket_monthly (month, board, type, priority, source, company, is_noise);


-- Closed tickets by month closed (throughput).
create materialized view rpt.closed_monthly as
select month_closed as month, board, count(*) as closed
from rpt.ticket_fact
where month_closed is not null
group by 1, 2;

create unique index on rpt.closed_monthly (month, board);


-- Hours by tech, board, type and client.
create materialized view rpt.time_monthly as
select
    month, member_id, member_name, team, board, type, company, billable, category, is_leave,
    sum(hours)                      as hours,
    count(*)                        as entries,
    count(distinct ticket_id)       as tickets_worked
from rpt.time_fact
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10;

create unique index on rpt.time_monthly
    (month, member_id, member_name, team, board, type, company, billable, category, is_leave);


-- When tickets arrive: day of week x hour of day.
create materialized view rpt.arrival_hourly as
select month_opened as month, board, is_noise,
       extract(isodow from opened_at)::int as dow,
       extract(hour from opened_at)::int   as hour,
       count(*)                            as opened
from rpt.ticket_fact
group by 1, 2, 3, 4, 5;

create unique index on rpt.arrival_hourly (month, board, is_noise, dow, hour);


-- Tickets per day for the last 90 days ("what came in yesterday?").
create materialized view rpt.ticket_daily as
select
    opened_at::date as day, board, type, company, is_noise,
    count(*)        as opened
from rpt.ticket_fact
where opened_at >= rpt.local_today() - 90
group by 1, 2, 3, 4, 5;

create unique index on rpt.ticket_daily (day, board, type, company, is_noise);


-- Opened vs closed per ISO week (is the queue growing?).
create materialized view rpt.flow_weekly as
with o as (
    select date_trunc('week', opened_at)::date as week, board,
           count(*) as opened,
           count(*) filter (where not is_noise) as opened_excl_alerts
    from rpt.ticket_fact
    group by 1, 2
),
c as (
    select date_trunc('week', closed_at)::date as week, board, count(*) as closed
    from rpt.ticket_fact
    where closed_at is not null
    group by 1, 2
)
select week, board,
       coalesce(o.opened, 0)             as opened,
       coalesce(o.opened_excl_alerts, 0) as opened_excl_alerts,
       coalesce(c.closed, 0)             as closed
from o full join c using (week, board);

create unique index on rpt.flow_weekly (week, board);


-- Hours per agreement per month (agreement usage).
create materialized view rpt.agreement_monthly as
select
    f.month, f.agreement_id,
    coalesce(a."AGR_Name", '(unknown)')        as agreement,
    coalesce(at."AGR_Type_Desc", '(none)')     as agreement_type,
    coalesce(c."Company_Name", '(none)')       as company,
    sum(f.hours)                               as hours,
    coalesce(sum(f.hours) filter (where f.billable), 0) as billable_hours,
    count(distinct f.ticket_id)                as tickets_worked
from rpt.time_fact f
left join cw."AGR_Header" a  on a."AGR_Header_RecID" = f.agreement_id
left join cw."AGR_Type"   at on at."AGR_Type_RecID"  = a."AGR_Type_RecID"
left join cw."Company"    c  on c."Company_RecID"    = a."Company_RecID"
where f.agreement_id is not null
group by 1, 2, 3, 4, 5;

create unique index on rpt.agreement_monthly (month, agreement_id);


-- Hours per project per month.
create materialized view rpt.project_monthly as
select month, project_id, sum(hours) as hours,
       coalesce(sum(hours) filter (where billable), 0) as billable_hours
from rpt.time_fact
where project_id is not null
group by 1, 2;

create unique index on rpt.project_monthly (month, project_id);


-- Hours and techs per ticket (time logged in the last 25 months).
create materialized view rpt.ticket_hours as
select ticket_id,
       sum(hours)                  as hours,
       count(distinct member_id)   as techs,
       max(work_date)              as last_worked
from rpt.time_fact
where ticket_id is not null
group by ticket_id;

create unique index on rpt.ticket_hours (ticket_id);


-- Ticket drivers: grouped summaries with ticket counts and hours spent.
create materialized view rpt.driver_monthly as
select
    f.month_opened as month, f.board, f.pattern, f.is_noise,
    coalesce(f.noise_label, '')                     as noise_label,
    count(*)                                        as tickets,
    count(*) filter (where h.hours > 0)             as tickets_worked,
    coalesce(sum(h.hours), 0)                       as hours,
    min(f.summary)                                  as example_summary
from rpt.ticket_fact f
left join rpt.ticket_hours h on h.ticket_id = f.ticket_id
group by 1, 2, 3, 4, 5;

create unique index on rpt.driver_monthly (month, board, pattern, is_noise, noise_label);


-- Current open backlog with age buckets (snapshot at refresh time).
create materialized view rpt.open_backlog as
select
    board, status, priority, company,
    case
        when rpt.local_now() - opened_at < interval '1 day'   then '0-1 days'
        when rpt.local_now() - opened_at < interval '3 days'  then '1-3 days'
        when rpt.local_now() - opened_at < interval '7 days'  then '3-7 days'
        when rpt.local_now() - opened_at < interval '30 days' then '7-30 days'
        else '30+ days'
    end                                          as age_bucket,
    count(*)                                     as tickets,
    min(opened_at)                               as oldest_opened_at
from rpt.ticket_fact
where not is_closed
group by 1, 2, 3, 4, 5;

create unique index on rpt.open_backlog (board, status, priority, company, age_bucket);


-- ---------------------------------------------------------------------------
-- Report functions (what the AI calls)
-- ---------------------------------------------------------------------------

create or replace function rpt.ticket_drivers(
    p_board   text    default 'Support',
    p_months  integer default 6,
    p_limit   integer default 50
)
returns table (
    pattern text, example_summary text, is_noise boolean, noise_label text,
    tickets bigint, tickets_worked bigint, hours numeric, share_of_tickets numeric
)
language sql
stable
as $$
    with d as (
        select pattern, min(example_summary) as example_summary, bool_or(is_noise) as is_noise,
               max(noise_label) as noise_label, sum(tickets) as tickets,
               sum(tickets_worked) as tickets_worked, sum(hours) as hours
        from rpt.driver_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and board ilike p_board
        group by pattern
    )
    select pattern, example_summary, is_noise, nullif(noise_label, ''),
           tickets::bigint, tickets_worked::bigint, round(hours, 1),
           round(100.0 * tickets / nullif(sum(tickets) over (), 0), 1)
    from d
    order by hours desc, tickets desc
    limit p_limit
$$;
comment on function rpt.ticket_drivers(text, integer, integer) is
  'Top ticket drivers for a board over the last N complete months, ranked by hours spent. Example: select * from rpt.ticket_drivers(''Support'', 6);';


create or replace function rpt.sla_summary(
    p_board   text    default '%',
    p_months  integer default 6
)
returns table (
    board text, priority text, tickets bigint,
    respond_sla_pct numeric, resolve_sla_pct numeric,
    avg_hours_to_close numeric, still_open bigint
)
language sql
stable
as $$
    select board, priority, sum(opened)::bigint,
           round(100.0 * sum(respond_sla_met) / nullif(sum(respond_sla_n), 0), 1),
           round(100.0 * sum(resolve_sla_met) / nullif(sum(resolve_sla_n), 0), 1),
           round((sum(close_hours_sum) / nullif(sum(close_hours_n), 0))::numeric, 1),
           sum(still_open)::bigint
    from rpt.ticket_monthly
    where month >= (select rpt.window_start(p_months))
      and month <  rpt.current_month()
      and board ilike p_board
      and not is_noise
    group by board, priority
    order by board, priority
$$;
comment on function rpt.sla_summary(text, integer) is
  'Response and resolution SLA attainment by board and priority (alerts excluded). Example: select * from rpt.sla_summary(''Support'', 3);';


create or replace function rpt.utilisation(
    p_team    text    default '%',
    p_months  integer default 6
)
returns table (
    team text, member_id text, member_name text, months_active bigint,
    work_hours numeric, leave_hours numeric, billable_hours numeric,
    avg_work_hours_per_month numeric, utilisation_pct numeric
)
language sql
stable
as $$
    with cap as (
        select value as hours from rpt.settings where key = 'monthly_capacity_hours'
    ),
    m as (
        select team, member_id, member_name, month,
               coalesce(sum(hours) filter (where not is_leave), 0) as work_hours,
               coalesce(sum(hours) filter (where is_leave), 0)     as leave_hours,
               coalesce(sum(hours) filter (where billable), 0)     as billable_hours
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and team ilike p_team
        group by 1, 2, 3, 4
    )
    -- Utilisation = work hours / (capacity - leave), over the months the
    -- tech logged any time.
    select m.team, m.member_id, m.member_name, count(*)::bigint,
           round(sum(m.work_hours), 1), round(sum(m.leave_hours), 1),
           round(sum(m.billable_hours), 1),
           round(avg(m.work_hours), 1),
           round(100.0 * sum(m.work_hours)
                 / nullif(sum(greatest((select hours from cap) - m.leave_hours, 0)), 0), 0)
    from m
    group by m.team, m.member_id, m.member_name
    order by avg(m.work_hours) desc
$$;
comment on function rpt.utilisation(text, integer) is
  'Work hours (leave excluded), leave hours and utilisation per tech against monthly capacity less leave. Example: select * from rpt.utilisation(''Team A'', 6);';


create or replace function rpt.team_capacity(
    p_months  integer default 6
)
returns table (
    team text, techs bigint, avg_work_hours_per_month numeric, avg_leave_hours_per_month numeric,
    fte_needed_at_target numeric, utilisation_pct numeric
)
language sql
stable
as $$
    with s as (
        select max(value) filter (where key = 'monthly_capacity_hours') as cap,
               max(value) filter (where key = 'target_utilisation')     as target
        from rpt.settings
    ),
    m as (
        select team, month,
               coalesce(sum(hours) filter (where not is_leave), 0) as work_hours,
               coalesce(sum(hours) filter (where is_leave), 0)     as leave_hours,
               count(distinct member_id)                           as techs
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and team <> '(no team)'
        group by team, month
    )
    -- Demand is work hours only; leave reduces the capacity available.
    select m.team, max(m.techs)::bigint,
           round(avg(m.work_hours), 1), round(avg(m.leave_hours), 1),
           round(avg(m.work_hours) / (s.cap * s.target), 1),
           round(100.0 * sum(m.work_hours)
                 / nullif(sum(greatest(m.techs * s.cap - m.leave_hours, 0)), 0), 0)
    from m cross join s
    group by m.team, s.cap, s.target
    order by m.team
$$;
comment on function rpt.team_capacity(integer) is
  'Team work demand (leave excluded) versus capacity less leave, and FTE needed at the target utilisation. Example: select * from rpt.team_capacity(6);';


create or replace function rpt.ticket_volume(
    p_board   text    default '%',
    p_months  integer default 12
)
returns table (
    month date, board text, opened bigint, opened_excl_alerts bigint,
    closed bigint, hours numeric
)
language sql
stable
as $$
    with o as (
        select month, board, sum(opened) as opened,
               sum(opened) filter (where not is_noise) as opened_excl_alerts
        from rpt.ticket_monthly
        where month >= (select rpt.window_start(p_months)) and board ilike p_board
        group by 1, 2
    ),
    h as (
        select month, board, sum(hours) as hours
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months)) and board ilike p_board
        group by 1, 2
    )
    select o.month, o.board, o.opened::bigint, coalesce(o.opened_excl_alerts, 0)::bigint,
           coalesce(c.closed, 0)::bigint, round(coalesce(h.hours, 0), 1)
    from o
    left join rpt.closed_monthly c using (month, board)
    left join h using (month, board)
    order by o.month, o.board
$$;
comment on function rpt.ticket_volume(text, integer) is
  'Monthly opened, closed and hours by board, including the current month to date. Example: select * from rpt.ticket_volume(''Support'', 12);';


create or replace function rpt.client_summary(
    p_months  integer default 6,
    p_limit   integer default 25,
    p_board   text    default '%'
)
returns table (
    company text, tickets bigint, tickets_excl_alerts bigint, hours numeric,
    billable_hours numeric, resolve_sla_pct numeric
)
language sql
stable
as $$
    with t as (
        select company, sum(opened) as tickets,
               sum(opened) filter (where not is_noise) as tickets_excl_alerts,
               sum(resolve_sla_met) as met, sum(resolve_sla_n) as n
        from rpt.ticket_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and board ilike p_board
        group by company
    ),
    h as (
        select company, sum(hours) as hours, sum(hours) filter (where billable) as billable_hours
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and board ilike p_board
        group by company
    )
    select t.company, t.tickets::bigint, coalesce(t.tickets_excl_alerts, 0)::bigint,
           round(coalesce(h.hours, 0), 1), round(coalesce(h.billable_hours, 0), 1),
           round(100.0 * t.met / nullif(t.n, 0), 1)
    from t left join h using (company)
    order by coalesce(h.hours, 0) desc
    limit p_limit
$$;
comment on function rpt.client_summary(integer, integer, text) is
  'Per-client tickets, hours and resolution SLA for client reviews, optionally for one board. Example: select * from rpt.client_summary(12, 25, ''Support'');';


create or replace function rpt.backlog(
    p_board   text default '%'
)
returns table (
    board text, age_bucket text, tickets bigint, oldest_opened_at timestamp
)
language sql
stable
as $$
    select board, age_bucket, sum(tickets)::bigint, min(oldest_opened_at)
    from rpt.open_backlog
    where board ilike p_board
    group by board, age_bucket
    order by board, min(oldest_opened_at)
$$;
comment on function rpt.backlog(text) is
  'Open tickets by age bucket as of the last refresh. Example: select * from rpt.backlog(''Support'');';


create or replace function rpt.period_compare(
    p_board   text    default '%',
    p_months  integer default 3
)
returns table (
    metric text, current_period numeric, previous_period numeric, change_pct numeric
)
language sql
stable
as $$
    with bounds as (
        select (select rpt.window_start(p_months))            as cur_start,
               rpt.current_month()      as cur_end,
               (select rpt.window_start(2 * p_months))        as prev_start
    ),
    t as (
        select
            sum(opened) filter (where month >= b.cur_start  and month < b.cur_end)   as cur_tickets,
            sum(opened) filter (where month >= b.prev_start and month < b.cur_start) as prev_tickets,
            sum(opened) filter (where not is_noise and month >= b.cur_start  and month < b.cur_end)   as cur_real,
            sum(opened) filter (where not is_noise and month >= b.prev_start and month < b.cur_start) as prev_real
        from rpt.ticket_monthly, bounds b
        where board ilike p_board
    ),
    h as (
        select
            sum(hours) filter (where month >= b.cur_start  and month < b.cur_end)   as cur_hours,
            sum(hours) filter (where month >= b.prev_start and month < b.cur_start) as prev_hours
        from rpt.time_monthly, bounds b
        where board ilike p_board
    )
    select x.metric, x.cur, x.prev, round(100.0 * (x.cur - x.prev) / nullif(x.prev, 0), 1)
    from t, h, lateral (values
        ('tickets',               t.cur_tickets::numeric, t.prev_tickets::numeric),
        ('tickets excl. alerts',  t.cur_real::numeric,    t.prev_real::numeric),
        ('hours',                 round(h.cur_hours, 1),  round(h.prev_hours, 1))
    ) as x(metric, cur, prev)
$$;
comment on function rpt.period_compare(text, integer) is
  'Last N complete months against the N months before them (N up to 12, since history is 25 months; 12 = year on year). Example: select * from rpt.period_compare(''Support'', 6);';


create or replace function rpt.tickets_by_day(
    p_board  text    default '%',
    p_days   integer default 7
)
returns table (
    day date, board text, opened bigint, opened_excl_alerts bigint
)
language sql
stable
as $$
    select day, board, sum(opened)::bigint,
           coalesce(sum(opened) filter (where not is_noise), 0)::bigint
    from rpt.ticket_daily
    where day >= rpt.local_today() - p_days
      and board ilike p_board
    group by day, board
    order by day desc, board
$$;
comment on function rpt.tickets_by_day(text, integer) is
  'Tickets opened per day: today so far plus the previous N days (up to 90), with and without alerts. p_days = 1 gives yesterday and today. Example: select * from rpt.tickets_by_day(''%'', 1);';


create or replace function rpt.flow(
    p_board  text    default '%',
    p_weeks  integer default 12
)
returns table (
    week date, opened bigint, opened_excl_alerts bigint, closed bigint, net_change bigint
)
language sql
stable
as $$
    select week, sum(opened)::bigint, sum(opened_excl_alerts)::bigint, sum(closed)::bigint,
           (sum(opened) - sum(closed))::bigint
    from rpt.flow_weekly
    where week >= (date_trunc('week', rpt.local_now()) - make_interval(weeks => p_weeks))::date
      and board ilike p_board
    group by week
    order by week
$$;
comment on function rpt.flow(text, integer) is
  'Opened vs closed per week; a positive net change means the queue is growing. Example: select * from rpt.flow(''Support'', 12);';


create or replace function rpt.tech_workload(
    p_who     text    default '%',
    p_months  integer default 6,
    p_limit   integer default 100
)
returns table (
    team text, member_name text, category text, board text, type text,
    hours numeric, tickets_worked bigint, share_of_member_hours numeric
)
language sql
stable
as $$
    with w as (
        select team, member_name, category, board, type,
               sum(hours) as hours, sum(tickets_worked) as tickets_worked
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and (member_id ilike p_who or member_name ilike p_who or team ilike p_who)
        group by 1, 2, 3, 4, 5
    )
    select team, member_name, category, board, type, round(hours, 1), tickets_worked::bigint,
           round(100.0 * hours / nullif(sum(hours) over (partition by member_name), 0), 1)
    from w
    order by member_name, hours desc
    limit p_limit
$$;
comment on function rpt.tech_workload(text, integer, integer) is
  'Where each tech''s hours go (ticket board/type, projects, charge codes). p_who matches a member ID, name or team; tickets_worked can double count a ticket worked in more than one month. Example: select * from rpt.tech_workload(''Team B'', 3);';


create or replace function rpt.time_by_category(
    p_team    text    default '%',
    p_months  integer default 6
)
returns table (
    team text, category text, hours numeric, billable_hours numeric, share_pct numeric
)
language sql
stable
as $$
    with c as (
        select team, category, sum(hours) as hours,
               coalesce(sum(hours) filter (where billable), 0) as billable_hours
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and team ilike p_team
        group by 1, 2
    )
    select team, category, round(hours, 1), round(billable_hours, 1),
           round(100.0 * hours / nullif(sum(hours) over (partition by team), 0), 1)
    from c
    order by team, hours desc
$$;
comment on function rpt.time_by_category(text, integer) is
  'Split of time between service tickets, projects and charge codes (admin, meetings, leave). Example: select * from rpt.time_by_category(''%'', 6);';


create or replace function rpt.type_breakdown(
    p_board   text    default 'Support',
    p_months  integer default 6
)
returns table (
    type text, tickets bigint, tickets_excl_alerts bigint, hours numeric,
    hours_per_ticket numeric
)
language sql
stable
as $$
    with t as (
        select type, sum(opened) as tickets,
               coalesce(sum(opened) filter (where not is_noise), 0) as tickets_excl_alerts
        from rpt.ticket_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and board ilike p_board
        group by type
    ),
    h as (
        select type, sum(hours) as hours
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and board ilike p_board
        group by type
    )
    select t.type, t.tickets::bigint, t.tickets_excl_alerts::bigint,
           round(coalesce(h.hours, 0), 1),
           round(coalesce(h.hours, 0) / nullif(t.tickets, 0), 2)
    from t left join h using (type)
    order by coalesce(h.hours, 0) desc
$$;
comment on function rpt.type_breakdown(text, integer) is
  'Tickets and hours by ticket type for a board. Hours are by month worked, tickets by month opened. Example: select * from rpt.type_breakdown(''Support'', 6);';


create or replace function rpt.source_mix(
    p_board   text    default '%',
    p_months  integer default 6
)
returns table (
    source text, tickets bigint, tickets_excl_alerts bigint, share_pct numeric
)
language sql
stable
as $$
    with s as (
        select source, sum(opened) as tickets,
               coalesce(sum(opened) filter (where not is_noise), 0) as tickets_excl_alerts
        from rpt.ticket_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and board ilike p_board
        group by source
    )
    select source, tickets::bigint, tickets_excl_alerts::bigint,
           round(100.0 * tickets / nullif(sum(tickets) over (), 0), 1)
    from s
    order by tickets desc
$$;
comment on function rpt.source_mix(text, integer) is
  'How tickets arrive (email, portal, phone, monitoring). Example: select * from rpt.source_mix(''Support'', 6);';


create or replace function rpt.automation_candidates(
    p_board        text    default 'Support',
    p_months       integer default 6,
    p_min_tickets  integer default 20
)
returns table (
    candidate text, kind text, tickets bigint, hours numeric,
    tickets_per_month numeric, suggested_fix text
)
language sql
stable
as $$
    with d as (
        select pattern, min(example_summary) as example_summary,
               bool_or(is_noise) as is_noise, max(noise_label) as noise_label,
               sum(tickets) as tickets, sum(hours) as hours
        from rpt.driver_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and board ilike p_board
        group by pattern
    ),
    g as (
        -- Alerts are grouped by their noise label; repeat requests by pattern.
        select case when d.is_noise then d.noise_label else d.example_summary end as candidate,
               case when d.is_noise then 'Alert / notification' else 'Repeat request' end as kind,
               sum(d.tickets) as tickets, sum(d.hours) as hours
        from d
        group by 1, 2
    )
    -- Fixes are looked up per candidate (not joined into g), so several
    -- patterns sharing a label can never multiply the sums.
    select candidate, kind, tickets::bigint, round(hours, 1),
           round(tickets / p_months::numeric, 1),
           coalesce(
               (select max(n.suggested_fix) from rpt.noise_pattern n where n.label = g.candidate),
               (select max(nb.suggested_fix) from rpt.noise_board nb
                where g.candidate ilike 'Alert board: ' || nb.board_pattern),
               'Review: template, self-service or scripted fix')
    from g
    where tickets >= p_min_tickets
    order by hours desc, tickets desc
$$;
comment on function rpt.automation_candidates(text, integer, integer) is
  'Alerts and repeated requests worth automating, with the suggested fix. Example: select * from rpt.automation_candidates(''Support'', 6);';


create or replace function rpt.agreement_usage(
    p_months  integer default 6,
    p_limit   integer default 50
)
returns table (
    company text, agreement text, agreement_type text, hours numeric,
    billable_hours numeric, avg_hours_per_month numeric, remaining_balance numeric
)
language sql
stable
as $$
    with a as (
        select agreement_id, company, agreement, agreement_type,
               sum(hours) as hours, sum(billable_hours) as billable_hours
        from rpt.agreement_monthly
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
        group by 1, 2, 3, 4
    )
    select a.company, a.agreement, a.agreement_type, round(a.hours, 1),
           round(a.billable_hours, 1), round(a.hours / p_months, 1),
           ac."RemainingBal"
    from a
    left join cw."AGR_Header_Calculated" ac on ac."AGR_Header_RecID" = a.agreement_id
    order by a.hours desc
    limit p_limit
$$;
comment on function rpt.agreement_usage(integer, integer) is
  'Hours logged against each agreement, with the current remaining balance from ConnectWise. Example: select * from rpt.agreement_usage(12);';


create or replace function rpt.project_hours(
    p_open_only  boolean default true,
    p_board      text    default '%'
)
returns table (
    project text, company text, board text, status text, manager text,
    start_date date, due_date date, days_overdue integer,
    estimated_hours numeric, hours_last_25_months numeric, remaining_estimate numeric,
    pct_of_estimate numeric, percent_complete numeric, open_tickets bigint
)
language sql
stable
as $$
    with h as (
        select project_id, sum(hours) as hours
        from rpt.project_monthly
        group by project_id
    ),
    t as (
        select project_id, count(*) filter (where not is_closed) as open_tickets
        from rpt.ticket_fact
        where project_id is not null
        group by project_id
    ),
    ps as (
        select p.*, s."Description" as status_name, coalesce(s."Closed_Flag", false) as closed
        from cw."PM_Project" p
        left join cw."PM_Status" s on s."PM_Status_RecID" = p."PM_Status_RecID"
    )
    select p."Project_ID", c."Company_Name", coalesce(b."Board_Name", '(none)'), p.status_name,
           p."Member_ID", p."Date_Start", p."Date_Req",
           case when not p.closed and p."Date_Req" < rpt.local_today()
                then (rpt.local_today() - p."Date_Req")::int end,
           p."Est_Hours",
           round(coalesce(h.hours, 0), 1),
           round(p."Est_Hours" - coalesce(h.hours, 0), 1),
           round(100.0 * coalesce(h.hours, 0) / nullif(p."Est_Hours", 0), 0),
           p."Percent_Complete",
           coalesce(t.open_tickets, 0)::bigint
    from ps p
    left join cw."Company"  c on c."Company_RecID"  = p."Company_RecID"
    left join cw."SR_Board" b on b."SR_Board_RecID" = p."SR_Board_RecID"
    left join h on h.project_id = p."PM_Project_RecID"
    left join t on t.project_id = p."PM_Project_RecID"
    where (not p_open_only or not p.closed)
      and coalesce(b."Board_Name", '(none)') ilike p_board
    order by 12 desc nulls last
$$;
comment on function rpt.project_hours(boolean, text) is
  'Every project: dates, overdue days, estimated vs actual hours, % of estimate, % complete, open tickets. Hours cover time logged in the last 25 months. Example: select * from rpt.project_hours(true);';


-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

create table if not exists rpt.refresh_log (
    refreshed_at  timestamptz not null default now(),
    seconds       numeric not null
);

create or replace function rpt.refresh_all()
returns void
language plpgsql
as $$
declare
    v_start timestamptz := clock_timestamp();
begin
    -- Facts first, then everything built on them.
    refresh materialized view concurrently rpt.ticket_fact;
    refresh materialized view concurrently rpt.time_fact;
    refresh materialized view concurrently rpt.ticket_hours;
    refresh materialized view concurrently rpt.ticket_monthly;
    refresh materialized view concurrently rpt.closed_monthly;
    refresh materialized view concurrently rpt.time_monthly;
    refresh materialized view concurrently rpt.driver_monthly;
    refresh materialized view concurrently rpt.open_backlog;
    refresh materialized view concurrently rpt.arrival_hourly;
    refresh materialized view concurrently rpt.ticket_daily;
    refresh materialized view concurrently rpt.flow_weekly;
    refresh materialized view concurrently rpt.agreement_monthly;
    refresh materialized view concurrently rpt.project_monthly;
    insert into rpt.refresh_log (seconds)
    values (round(extract(epoch from clock_timestamp() - v_start)::numeric, 1));
end
$$;

-- The views above were just built from live data: record that as a refresh.
insert into rpt.refresh_log (seconds) values (0);

create or replace view rpt.freshness as
select max(refreshed_at) as last_refreshed_at,
       now() - max(refreshed_at) as age
from rpt.refresh_log;
comment on view rpt.freshness is 'When the reports were last refreshed. Quote this with any answer.';


-- ---------------------------------------------------------------------------
-- Catalog (the AI's starting point)
-- ---------------------------------------------------------------------------

create table if not exists rpt.catalog (
    report         text primary key,
    function_name  text not null,
    answers        text not null,
    sql_example    text not null,
    owner          text,
    verified       text
);

insert into rpt.catalog (report, function_name, answers, sql_example, owner) values
    ('Ticket drivers',   'rpt.ticket_drivers', 'What are techs spending time on? What can we automate?', 'select * from rpt.ticket_drivers(''Support'', 6);', 'Service desk'),
    ('SLA summary',      'rpt.sla_summary',    'Are we meeting response and resolution SLAs?',          'select * from rpt.sla_summary(''Support'', 3);',    'Service desk'),
    ('Tech utilisation', 'rpt.utilisation',    'Who is busiest? Utilisation per tech and team.',         'select * from rpt.utilisation(''%'', 6);',           'Service desk'),
    ('Team capacity',    'rpt.team_capacity',  'Are we understaffed? FTE needed at target.',             'select * from rpt.team_capacity(6);',                'Service desk'),
    ('Ticket volume',    'rpt.ticket_volume',  'Monthly opened, closed and hours trend.',                'select * from rpt.ticket_volume(''Support'', 12);', 'Service desk'),
    ('Client summary',   'rpt.client_summary', 'Which clients use the most time? Client reviews.',       'select * from rpt.client_summary(12);',              'Account management'),
    ('Open backlog',     'rpt.backlog',        'How many tickets are open and how old?',                 'select * from rpt.backlog(''Support'');',           'Service desk'),
    ('Period compare',   'rpt.period_compare', 'Is it getting better or worse than last period? Use 12 for year on year.', 'select * from rpt.period_compare(''Support'', 6);', 'Service desk'),
    ('Tickets by day',   'rpt.tickets_by_day', 'What came in yesterday or this week?',                   'select * from rpt.tickets_by_day(''%'', 1);',       'Service desk'),
    ('Weekly flow',      'rpt.flow',           'Is the queue growing? Opened vs closed per week.',       'select * from rpt.flow(''Support'', 12);',          'Service desk'),
    ('Tech workload',    'rpt.tech_workload',  'Where does a tech or team spend their hours?',           'select * from rpt.tech_workload(''Team B'', 3);',   'Service desk'),
    ('Time by category', 'rpt.time_by_category','Tickets vs projects vs admin, meetings and leave.',     'select * from rpt.time_by_category(''%'', 6);',     'Service desk'),
    ('Type breakdown',   'rpt.type_breakdown', 'Which ticket types take the most time?',                 'select * from rpt.type_breakdown(''Support'', 6);', 'Service desk'),
    ('Source mix',       'rpt.source_mix',     'How do tickets arrive (email, portal, phone, alerts)?',  'select * from rpt.source_mix(''Support'', 6);',     'Service desk'),
    ('Automation candidates', 'rpt.automation_candidates', 'What should we automate first?',             'select * from rpt.automation_candidates(''Support'', 6);', 'Service desk'),
    ('Agreement usage',  'rpt.agreement_usage','Hours used per client agreement and remaining balance.', 'select * from rpt.agreement_usage(12);',            'Account management'),
    ('Project hours',    'rpt.project_hours',  'Are projects over their estimated hours?',               'select * from rpt.project_hours();',                'Projects')
on conflict (report) do nothing;


-- ---------------------------------------------------------------------------
-- Access: MCP (cw_agent) and PostgREST (cw_reader) read only
-- ---------------------------------------------------------------------------

grant usage on schema rpt to cw_agent, cw_reader;
grant select on all tables in schema rpt to cw_agent, cw_reader;
grant execute on all functions in schema rpt to cw_agent, cw_reader;
revoke execute on function rpt.refresh_all() from public, cw_agent, cw_reader;

commit;

-- Initial population (outside the transaction; takes a few minutes).
-- The first refresh cannot be CONCURRENTLY, so the views above are created
-- populated already. Afterwards, schedule the hourly refresh (pg_cron):
--
--   select cron.schedule('rpt-refresh', '15 * * * *', 'select rpt.refresh_all()');
--
-- Optional, by the owner of cw.report_catalog: add the rpt reports to the
-- existing catalog so one query lists everything:
--
--   create or replace view cw.report_catalog_all as
--   select report, function_name, answers as description, sql_example, owner, verified
--   from rpt.catalog
--   union all
--   select report, function_name, description, sql_example, owner, verified
--   from cw.report_catalog;
