-- Pre-built ConnectWise reports, part 2: deeper service desk reports,
-- "something is off" reports, and two pivots that cover any combination of
-- dimensions. Run after 001_rpt_schema.sql. Safe to re-run.
--
-- Every function takes the window as p_months (last N complete months)
-- unless it is a point-in-time report (backlog, zombies, oldest open).

begin;

-- ---------------------------------------------------------------------------
-- Trend and KPIs
-- ---------------------------------------------------------------------------

create or replace function rpt.monthly_kpis(
    p_board   text    default '%',
    p_months  integer default 12
)
returns table (
    month date, opened bigint, opened_excl_alerts bigint, alert_pct numeric,
    closed bigint, hours numeric, respond_sla_pct numeric, resolve_sla_pct numeric,
    avg_hours_to_close numeric
)
language sql
stable
as $$
    with t as (
        select month,
               sum(opened) as opened,
               sum(opened) filter (where not is_noise) as real_opened,
               sum(respond_sla_met) filter (where not is_noise) as rm,
               sum(respond_sla_n)   filter (where not is_noise) as rn,
               sum(resolve_sla_met) filter (where not is_noise) as sm,
               sum(resolve_sla_n)   filter (where not is_noise) as sn,
               sum(close_hours_sum) filter (where not is_noise) as chs,
               sum(close_hours_n)   filter (where not is_noise) as chn
        from rpt.ticket_monthly
        where month >= (select rpt.window_start(p_months)) and board ilike p_board
        group by month
    ),
    c as (
        select month, sum(closed) as closed
        from rpt.closed_monthly
        where month >= (select rpt.window_start(p_months)) and board ilike p_board
        group by month
    ),
    h as (
        select month, sum(hours) as hours
        from rpt.time_monthly
        where month >= (select rpt.window_start(p_months)) and board ilike p_board
        group by month
    )
    select t.month, t.opened::bigint, coalesce(t.real_opened, 0)::bigint,
           round(100.0 * (t.opened - coalesce(t.real_opened, 0)) / nullif(t.opened, 0), 1),
           coalesce(c.closed, 0)::bigint, round(coalesce(h.hours, 0), 1),
           round(100.0 * t.rm / nullif(t.rn, 0), 1),
           round(100.0 * t.sm / nullif(t.sn, 0), 1),
           round((t.chs / nullif(t.chn, 0))::numeric, 1)
    from t
    left join c using (month)
    left join h using (month)
    order by t.month
$$;
comment on function rpt.monthly_kpis(text, integer) is
  'One row per month: volume, alert share, closed, hours, SLA and time to close (current month to date included). Example: select * from rpt.monthly_kpis(''Support'', 12);';


create or replace function rpt.team_compare(
    p_months  integer default 6
)
returns table (
    team text, techs bigint, hours numeric, billable_pct numeric,
    tickets_worked bigint, hours_per_ticket numeric, after_hours_pct numeric
)
language sql
stable
as $$
    select team,
           count(distinct member_id)::bigint,
           round(sum(hours), 1),
           round(100.0 * sum(hours) filter (where billable) / nullif(sum(hours), 0), 1),
           count(distinct ticket_id)::bigint,
           round(sum(hours) filter (where ticket_id is not null)
                 / nullif(count(distinct ticket_id), 0), 2),
           -- Same basis as rpt.after_hours: entries with a start time only.
           round(100.0 * sum(hours) filter (
                     where extract(isodow from time_start) >= 6
                        or time_start::time < time '07:00'
                        or time_start::time >= time '18:00')
                 / nullif(sum(hours) filter (where time_start is not null), 0), 1)
    from rpt.time_fact
    where month >= (select rpt.window_start(p_months))
      and not is_leave
      and month <  rpt.current_month()
    group by team
    order by team
$$;
comment on function rpt.team_compare(integer) is
  'Teams side by side: hours, billable share, tickets worked, hours per ticket, after-hours share. Example: select * from rpt.team_compare(6);';


create or replace function rpt.tech_productivity(
    p_team    text    default '%',
    p_months  integer default 6
)
returns table (
    team text, member_name text, hours numeric, ticket_hours numeric,
    tickets_worked bigint, hours_per_ticket numeric, billable_pct numeric,
    days_with_time bigint, hours_per_day numeric
)
language sql
stable
as $$
    select team, member_name,
           round(sum(hours), 1),
           round(coalesce(sum(hours) filter (where ticket_id is not null), 0), 1),
           count(distinct ticket_id)::bigint,
           round(sum(hours) filter (where ticket_id is not null)
                 / nullif(count(distinct ticket_id), 0), 2),
           round(100.0 * sum(hours) filter (where billable) / nullif(sum(hours), 0), 1),
           count(distinct work_date)::bigint,
           round(sum(hours) / nullif(count(distinct work_date), 0), 1)
    from rpt.time_fact
    where month >= (select rpt.window_start(p_months))
      and month <  rpt.current_month()
      and team ilike p_team
      and not is_leave
    group by team, member_name
    order by sum(hours) desc
$$;
comment on function rpt.tech_productivity(text, integer) is
  'Per tech: hours, tickets worked, hours per ticket, billable share, hours per working day. Example: select * from rpt.tech_productivity(''Team A'', 3);';


-- ---------------------------------------------------------------------------
-- Speed and SLA detail
-- ---------------------------------------------------------------------------

create or replace function rpt.response_times(
    p_board   text    default 'Support',
    p_months  integer default 6
)
returns table (
    metric text, bucket text, tickets bigint, share_pct numeric
)
language sql
stable
as $$
    with m as (
        select 'First response' as metric, responded_minutes as minutes
        from rpt.ticket_fact
        where month_opened >= (select rpt.window_start(p_months))
          and month_opened <  rpt.current_month()
          and board ilike p_board and not is_noise and responded_minutes is not null
        union all
        select 'Resolution', resolved_minutes
        from rpt.ticket_fact
        where month_opened >= (select rpt.window_start(p_months))
          and month_opened <  rpt.current_month()
          and board ilike p_board and not is_noise and resolved_minutes is not null
    ),
    b as (
        select metric,
               case
                   when minutes < 15   then 1
                   when minutes < 60   then 2
                   when minutes < 240  then 3
                   when minutes < 1440 then 4
                   when minutes < 4320 then 5
                   else 6
               end as bucket_no
        from m
    )
    select metric,
           (array['under 15 min', '15-60 min', '1-4 h', '4-24 h', '1-3 days', 'over 3 days'])[bucket_no],
           count(*)::bigint,
           round(100.0 * count(*) / sum(count(*)) over (partition by metric), 1)
    from b
    group by metric, bucket_no
    order by metric, bucket_no
$$;
comment on function rpt.response_times(text, integer) is
  'Distribution of first response and resolution times (ConnectWise SLA business minutes, alerts excluded). Example: select * from rpt.response_times(''Support'', 3);';


create or replace function rpt.sla_breaches(
    p_board   text    default 'Support',
    p_months  integer default 3,
    p_limit   integer default 100
)
returns table (
    ticket_id integer, summary text, company text, priority text, breached text,
    hours_late numeric, opened_at timestamp, is_closed boolean
)
language sql
stable
as $$
    -- Uses the SLA stop times (responded / resolved / closed). A closed ticket
    -- with no stop time is not a breach; an open one counts while past due.
    with b as (
        select f.*,
               case
                   when f.respond_stop_utc > f.respond_due_utc
                     or (f.respond_stop_utc is null and not f.is_closed
                         and f.respond_due_utc < now() at time zone 'utc')
                   then 'response' end as resp,
               case
                   when f.resolve_stop_utc > f.resolve_due_utc
                     or (f.resolve_stop_utc is null and not f.is_closed
                         and f.resolve_due_utc < now() at time zone 'utc')
                   then 'resolution' end as reso
        from rpt.ticket_fact f
        where f.month_opened >= (select rpt.window_start(p_months))
          and f.board ilike p_board
          and not f.is_noise
    )
    select ticket_id, summary, company, priority,
           concat_ws(' + ', resp, reso),
           round((greatest(
               date_part('epoch', coalesce(respond_stop_utc, now() at time zone 'utc') - respond_due_utc)
                   * (resp is not null)::int,
               date_part('epoch', coalesce(resolve_stop_utc, now() at time zone 'utc') - resolve_due_utc)
                   * (reso is not null)::int
           ) / 3600.0)::numeric, 1),
           opened_at, is_closed
    from b
    where resp is not null or reso is not null
    order by 6 desc
    limit p_limit
$$;
comment on function rpt.sla_breaches(text, integer, integer) is
  'Tickets that missed (or are past) their response or resolution SLA, worst first. Includes the current month. Example: select * from rpt.sla_breaches(''Support'', 1);';


create or replace function rpt.responder_stats(
    p_board   text    default '%',
    p_months  integer default 6
)
returns table (
    responder text, tickets bigint, avg_response_minutes numeric, within_sla_pct numeric
)
language sql
stable
as $$
    select responded_by, count(*)::bigint,
           round(avg(responded_minutes), 0),
           round(100.0 * count(*) filter (where respond_stop_utc <= respond_due_utc)
                 / nullif(count(*) filter (where respond_due_utc is not null
                                             and respond_stop_utc is not null), 0), 1)
    from rpt.ticket_fact
    where month_opened >= (select rpt.window_start(p_months))
      and month_opened <  rpt.current_month()
      and board ilike p_board
      and not is_noise
      and responded_by is not null
    group by responded_by
    order by count(*) desc
$$;
comment on function rpt.responder_stats(text, integer) is
  'Who gives the first response, how fast, and how often within SLA. Example: select * from rpt.responder_stats(''Support'', 3);';


-- ---------------------------------------------------------------------------
-- Queue health
-- ---------------------------------------------------------------------------

create or replace function rpt.oldest_open(
    p_board  text    default 'Support',
    p_limit  integer default 25
)
returns table (
    ticket_id integer, summary text, company text, status text, priority text,
    opened_at timestamp, age_days integer, hours numeric, last_worked date
)
language sql
stable
as $$
    select f.ticket_id, f.summary, f.company, f.status, f.priority, f.opened_at,
           (rpt.local_today() - f.opened_at::date)::int,
           round(coalesce(h.hours, 0), 1), h.last_worked
    from rpt.ticket_fact f
    left join rpt.ticket_hours h using (ticket_id)
    where not f.is_closed and f.board ilike p_board
    order by f.opened_at
    limit p_limit
$$;
comment on function rpt.oldest_open(text, integer) is
  'The oldest open tickets with hours spent and last time worked. Example: select * from rpt.oldest_open(''Support'');';


create or replace function rpt.zombie_tickets(
    p_board      text    default 'Support',
    p_idle_days  integer default 14,
    p_limit      integer default 50
)
returns table (
    ticket_id integer, summary text, company text, status text,
    opened_at timestamp, last_worked date, idle_days integer
)
language sql
stable
as $$
    select f.ticket_id, f.summary, f.company, f.status, f.opened_at, h.last_worked,
           (rpt.local_today() - coalesce(h.last_worked, f.opened_at::date))::int
    from rpt.ticket_fact f
    left join rpt.ticket_hours h using (ticket_id)
    where not f.is_closed
      and f.board ilike p_board
      and coalesce(h.last_worked, f.opened_at::date) < rpt.local_today() - p_idle_days
    order by 7 desc
    limit p_limit
$$;
comment on function rpt.zombie_tickets(text, integer, integer) is
  'Open tickets nobody has logged time on for N days (default 14). Example: select * from rpt.zombie_tickets(''Support'', 30);';


create or replace function rpt.status_ageing(
    p_board  text default 'Support'
)
returns table (
    status text, tickets bigint, avg_days_in_status numeric, max_days_in_status numeric
)
language sql
stable
as $$
    select status, count(*)::bigint,
           round(avg(date_part('epoch', now() at time zone 'utc'
                                - coalesce(status_changed_at_utc, opened_at_utc)) / 86400.0)::numeric, 1),
           round(max(date_part('epoch', now() at time zone 'utc'
                                - coalesce(status_changed_at_utc, opened_at_utc)) / 86400.0)::numeric, 1)
    from rpt.ticket_fact
    where not is_closed and board ilike p_board
    group by status
    order by count(*) desc
$$;
comment on function rpt.status_ageing(text) is
  'Open tickets per status and how long they have sat in it. Example: select * from rpt.status_ageing(''Support'');';


-- ---------------------------------------------------------------------------
-- Something is off
-- ---------------------------------------------------------------------------

create or replace function rpt.zero_time_tickets(
    p_board   text    default 'Support',
    p_months  integer default 6,
    p_limit   integer default 50
)
returns table (
    pattern text, example_summary text, tickets bigint
)
language sql
stable
as $$
    select f.pattern, min(f.summary), count(*)::bigint
    from rpt.ticket_fact f
    left join rpt.ticket_hours h using (ticket_id)
    where f.month_opened >= (select rpt.window_start(p_months))
      and f.month_opened <  rpt.current_month()
      and f.board ilike p_board
      and f.is_closed
      and not f.is_noise
      and coalesce(h.hours, 0) = 0
    group by f.pattern
    order by count(*) desc
    limit p_limit
$$;
comment on function rpt.zero_time_tickets(text, integer, integer) is
  'Closed tickets (not alerts) with no time logged: unlogged work, or requests that could be auto-closed. Example: select * from rpt.zero_time_tickets(''Support'', 3);';


create or replace function rpt.instant_closes(
    p_board    text    default 'Support',
    p_months   integer default 6,
    p_minutes  integer default 10
)
returns table (
    pattern text, example_summary text, is_noise boolean, tickets bigint
)
language sql
stable
as $$
    select pattern, min(summary), bool_or(is_noise), count(*)::bigint
    from rpt.ticket_fact
    where month_opened >= (select rpt.window_start(p_months))
      and month_opened <  rpt.current_month()
      and board ilike p_board
      and closed_at is not null
      and closed_at - opened_at < make_interval(mins => p_minutes)
    group by pattern
    order by count(*) desc
    limit 50
$$;
comment on function rpt.instant_closes(text, integer, integer) is
  'Tickets closed within N minutes of opening: noise that should never become a ticket. Example: select * from rpt.instant_closes(''Support'', 6, 5);';


create or replace function rpt.multi_tech_tickets(
    p_board      text    default 'Support',
    p_months     integer default 6,
    p_min_techs  integer default 3,
    p_limit      integer default 50
)
returns table (
    ticket_id integer, summary text, company text, techs bigint, hours numeric, is_closed boolean
)
language sql
stable
as $$
    select f.ticket_id, f.summary, f.company, h.techs::bigint, round(h.hours, 1), f.is_closed
    from rpt.ticket_fact f
    join rpt.ticket_hours h using (ticket_id)
    where f.month_opened >= (select rpt.window_start(p_months))
      and f.month_opened <  rpt.current_month()
      and f.board ilike p_board
      and h.techs >= p_min_techs
    order by h.techs desc, h.hours desc
    limit p_limit
$$;
comment on function rpt.multi_tech_tickets(text, integer, integer, integer) is
  'Tickets passed between many techs (ping-pong), a sign of unclear ownership or missing skills. Example: select * from rpt.multi_tech_tickets(''Support'', 6, 3);';


create or replace function rpt.top_tickets_by_hours(
    p_board   text    default 'Support',
    p_months  integer default 6,
    p_limit   integer default 25
)
returns table (
    ticket_id integer, summary text, company text, type text, hours numeric,
    techs bigint, is_closed boolean
)
language sql
stable
as $$
    select f.ticket_id, f.summary, f.company, f.type, round(h.hours, 1), h.techs::bigint, f.is_closed
    from rpt.ticket_fact f
    join rpt.ticket_hours h using (ticket_id)
    where f.month_opened >= (select rpt.window_start(p_months))
      and f.month_opened <  rpt.current_month()
      and f.board ilike p_board
    order by h.hours desc
    limit p_limit
$$;
comment on function rpt.top_tickets_by_hours(text, integer, integer) is
  'Single tickets that ate the most hours. Example: select * from rpt.top_tickets_by_hours(''Support'', 6);';


create or replace function rpt.after_hours(
    p_team    text    default '%',
    p_months  integer default 6
)
returns table (
    team text, member_name text, hours numeric, after_hours numeric,
    weekend_hours numeric, after_hours_pct numeric
)
language sql
stable
as $$
    with t as (
        select team, member_name, hours,
               (extract(isodow from time_start) >= 6) as weekend,
               (time_start::time < time '07:00' or time_start::time >= time '18:00') as outside
        from rpt.time_fact
        where month >= (select rpt.window_start(p_months))
          and month <  rpt.current_month()
          and team ilike p_team
          and time_start is not null
          and not is_leave
    )
    select team, member_name, round(sum(hours), 1),
           round(coalesce(sum(hours) filter (where outside and not weekend), 0), 1),
           round(coalesce(sum(hours) filter (where weekend), 0), 1),
           round(100.0 * coalesce(sum(hours) filter (where outside or weekend), 0)
                 / nullif(sum(hours), 0), 1)
    from t
    group by team, member_name
    order by 6 desc nulls last
$$;
comment on function rpt.after_hours(text, integer) is
  'Hours started before 07:00, after 18:00 or on weekends, per tech (burnout and on-call check). Example: select * from rpt.after_hours(''%'', 3);';


create or replace function rpt.unbilled_time(
    p_months  integer default 6,
    p_limit   integer default 25
)
returns table (
    company text, non_billable_hours numeric, tickets bigint
)
language sql
stable
as $$
    select company, round(sum(hours), 1), count(distinct ticket_id)::bigint
    from rpt.time_fact
    where month >= (select rpt.window_start(p_months))
      and month <  rpt.current_month()
      and category = 'Service ticket'
      and not billable
      and agreement_id is null
    group by company
    order by sum(hours) desc
    limit p_limit
$$;
comment on function rpt.unbilled_time(integer, integer) is
  'Non-billable ticket time on work not covered by an agreement: possible billing leakage to review. Example: select * from rpt.unbilled_time(3);';


create or replace function rpt.client_spikes(
    p_min_tickets  integer default 10,
    p_ratio        numeric default 1.5
)
returns table (
    company text, last_month bigint, avg_previous_6 numeric, ratio numeric
)
language sql
stable
as $$
    with m as (
        select company, month, sum(opened) as tickets
        from rpt.ticket_monthly
        where not is_noise
          and month >= (select rpt.window_start(7))
          and month <  rpt.current_month()
        group by company, month
    ),
    s as (
        select company,
               coalesce(sum(tickets) filter (where month = (select rpt.window_start(1))), 0) as last_month,
               coalesce(sum(tickets) filter (where month < (select rpt.window_start(1))), 0) / 6.0 as avg_prev
        from m
        group by company
    )
    select company, last_month::bigint, round(avg_prev, 1),
           round(last_month / nullif(avg_prev, 0), 1)
    from s
    where last_month >= p_min_tickets
      and (avg_prev = 0 or last_month / avg_prev >= p_ratio)
    order by last_month - avg_prev desc
$$;
comment on function rpt.client_spikes(integer, numeric) is
  'Clients whose tickets last month jumped above their 6-month average (alerts excluded). Example: select * from rpt.client_spikes();';


create or replace function rpt.arrival_heatmap(
    p_board           text    default 'Support',
    p_months          integer default 3,
    p_include_alerts  boolean default false
)
returns table (
    day text, hour integer, tickets bigint
)
language sql
stable
as $$
    select (array['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])[dow], hour, sum(opened)::bigint
    from rpt.arrival_hourly
    where month >= (select rpt.window_start(p_months))
      and month <  rpt.current_month()
      and board ilike p_board
      and (p_include_alerts or not is_noise)
    group by dow, hour
    order by dow, hour
$$;
comment on function rpt.arrival_heatmap(text, integer, boolean) is
  'Tickets by weekday and hour (staffing and roster planning). Example: select * from rpt.arrival_heatmap(''Support'', 3);';


create or replace function rpt.top_words(
    p_board           text    default 'Support',
    p_months          integer default 3,
    p_limit           integer default 40,
    p_include_alerts  boolean default false
)
returns table (
    word text, tickets bigint
)
language sql
stable
as $$
    with w as (
        select f.ticket_id, regexp_split_to_table(lower(f.summary), '[^a-z]+') as word
        from rpt.ticket_fact f
        where f.month_opened >= (select rpt.window_start(p_months))
          and f.month_opened <  rpt.current_month()
          and f.board ilike p_board
          and (p_include_alerts or not f.is_noise)
    )
    select word, count(distinct ticket_id)::bigint
    from w
    where length(word) >= 4
      and word not in ('with', 'from', 'that', 'this', 'have', 'please', 'request', 'issue',
                       'ticket', 'service', 'user', 'users', 'need', 'help', 'unable',
                       'cannot', 'when', 'there', 'their', 'your', 'about', 'after',
                       'into', 'will', 'been', 'were', 'also', 'more', 'than')
    group by word
    order by 2 desc
    limit p_limit
$$;
comment on function rpt.top_words(text, integer, integer, boolean) is
  'Most common words in ticket summaries (what are people actually asking about?). Example: select * from rpt.top_words(''Support'', 3);';


-- ---------------------------------------------------------------------------
-- Pivots: any two dimensions, any window
-- ---------------------------------------------------------------------------

create or replace function rpt.ticket_pivot(
    p_rows            text    default 'type',
    p_cols            text    default null,
    p_board           text    default '%',
    p_months          integer default 6,
    p_include_alerts  boolean default false
)
returns table (
    row_value text, col_value text, tickets bigint, closed bigint,
    resolve_sla_pct numeric, avg_hours_to_close numeric
)
language plpgsql
stable
as $$
declare
    v_dims constant text[] := array['month', 'board', 'type', 'priority', 'source', 'company', 'is_noise'];
begin
    if not (p_rows = any (v_dims)) or (p_cols is not null and not (p_cols = any (v_dims))) then
        raise exception 'p_rows / p_cols must be one of %', v_dims;
    end if;
    return query execute format(
        'select %I::text, %s::text, sum(opened)::bigint, sum(closed)::bigint,
                round(100.0 * sum(resolve_sla_met) / nullif(sum(resolve_sla_n), 0), 1),
                round((sum(close_hours_sum) / nullif(sum(close_hours_n), 0))::numeric, 1)
         from rpt.ticket_monthly
         where month >= (select rpt.window_start($1))
           and month <  rpt.current_month()
           and board ilike $2
           and ($3 or not is_noise)
         group by 1, 2
         order by 3 desc',
        p_rows,
        case when p_cols is null then 'null' else quote_ident(p_cols) end)
    using p_months, p_board, p_include_alerts;
end
$$;
comment on function rpt.ticket_pivot(text, text, text, integer, boolean) is
  'Tickets split by any one or two of: month, board, type, priority, source, company, is_noise. Example: select * from rpt.ticket_pivot(''company'', ''priority'', ''Support'', 3);';


create or replace function rpt.time_pivot(
    p_rows    text    default 'member_name',
    p_cols    text    default null,
    p_who     text    default '%',
    p_months  integer default 6
)
returns table (
    row_value text, col_value text, hours numeric, billable_hours numeric
)
language plpgsql
stable
as $$
declare
    v_dims constant text[] := array['month', 'member_name', 'team', 'board', 'type', 'company', 'billable', 'category'];
begin
    if not (p_rows = any (v_dims)) or (p_cols is not null and not (p_cols = any (v_dims))) then
        raise exception 'p_rows / p_cols must be one of %', v_dims;
    end if;
    return query execute format(
        'select %I::text, %s::text, round(sum(hours), 1),
                round(coalesce(sum(hours) filter (where billable), 0), 1)
         from rpt.time_monthly
         where month >= (select rpt.window_start($1))
           and month <  rpt.current_month()
           and (member_id ilike $2 or member_name ilike $2 or team ilike $2)
         group by 1, 2
         order by 3 desc',
        p_rows,
        case when p_cols is null then 'null' else quote_ident(p_cols) end)
    using p_months, p_who;
end
$$;
comment on function rpt.time_pivot(text, text, text, integer) is
  'Hours split by any one or two of: month, member_name, team, board, type, company, billable, category. p_who filters by member ID, name or team. Example: select * from rpt.time_pivot(''member_name'', ''category'', ''Team B'', 3);';


-- ---------------------------------------------------------------------------
-- Catalog and access
-- ---------------------------------------------------------------------------

insert into rpt.catalog (report, function_name, answers, sql_example, owner) values
    ('Monthly KPIs',        'rpt.monthly_kpis',       'Month by month: volume, alerts, closed, hours, SLA, time to close.',  'select * from rpt.monthly_kpis(''Support'', 12);',          'Service desk'),
    ('Team compare',        'rpt.team_compare',       'Team A vs Team B side by side.',                                     'select * from rpt.team_compare(6);',                        'Service desk'),
    ('Tech productivity',   'rpt.tech_productivity',  'Hours, tickets and hours per ticket per tech.',                      'select * from rpt.tech_productivity(''%'', 3);',             'Service desk'),
    ('Response times',      'rpt.response_times',     'How fast do we respond and resolve (distribution)?',                 'select * from rpt.response_times(''Support'', 3);',          'Service desk'),
    ('SLA breaches',        'rpt.sla_breaches',       'Which tickets missed SLA, worst first?',                             'select * from rpt.sla_breaches(''Support'', 1);',            'Service desk'),
    ('Responder stats',     'rpt.responder_stats',    'Who responds first and how fast?',                                   'select * from rpt.responder_stats(''Support'', 3);',         'Service desk'),
    ('Oldest open',         'rpt.oldest_open',        'Which open tickets are oldest?',                                     'select * from rpt.oldest_open(''Support'');',                'Service desk'),
    ('Zombie tickets',      'rpt.zombie_tickets',     'Open tickets nobody has touched for weeks.',                         'select * from rpt.zombie_tickets(''Support'', 14);',         'Service desk'),
    ('Status ageing',       'rpt.status_ageing',      'How long tickets sit in each status.',                               'select * from rpt.status_ageing(''Support'');',              'Service desk'),
    ('Zero-time tickets',   'rpt.zero_time_tickets',  'Closed tickets with no time logged.',                                'select * from rpt.zero_time_tickets(''Support'', 3);',       'Service desk'),
    ('Instant closes',      'rpt.instant_closes',     'Tickets closed within minutes: noise that should not be tickets.',   'select * from rpt.instant_closes(''Support'', 6, 10);',      'Service desk'),
    ('Ping-pong tickets',   'rpt.multi_tech_tickets', 'Tickets passed between many techs.',                                 'select * from rpt.multi_tech_tickets(''Support'', 6, 3);',   'Service desk'),
    ('Biggest tickets',     'rpt.top_tickets_by_hours','Single tickets that took the most hours.',                          'select * from rpt.top_tickets_by_hours(''Support'', 6);',    'Service desk'),
    ('After hours',         'rpt.after_hours',        'Who works nights and weekends?',                                     'select * from rpt.after_hours(''%'', 3);',                   'Service desk'),
    ('Unbilled time',       'rpt.unbilled_time',      'Non-billable work outside agreements (billing leakage).',            'select * from rpt.unbilled_time(3);',                        'Account management'),
    ('Client spikes',       'rpt.client_spikes',      'Which clients suddenly logged far more tickets?',                    'select * from rpt.client_spikes();',                         'Account management'),
    ('Arrival heatmap',     'rpt.arrival_heatmap',    'When do tickets arrive (weekday x hour)?',                           'select * from rpt.arrival_heatmap(''Support'', 3);',         'Service desk'),
    ('Top words',           'rpt.top_words',          'What words appear most in ticket summaries?',                        'select * from rpt.top_words(''Support'', 3);',               'Service desk'),
    ('Ticket pivot',        'rpt.ticket_pivot',       'Any ticket split: month, board, type, priority, source, company, alerts.', 'select * from rpt.ticket_pivot(''company'', ''priority'', ''Support'', 3);', 'Service desk'),
    ('Time pivot',          'rpt.time_pivot',         'Any time split: month, tech, team, board, type, company, billable, category.', 'select * from rpt.time_pivot(''member_name'', ''category'', ''%'', 3);', 'Service desk')
on conflict (report) do nothing;

grant execute on all functions in schema rpt to cw_agent, cw_reader;
revoke execute on function rpt.refresh_all() from public, cw_agent, cw_reader;

commit;
