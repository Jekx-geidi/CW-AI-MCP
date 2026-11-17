-- Minimal copy of the cw tables that rpt reads (column names and types match
-- the cw-postgres mirror, 2026-11-17), plus the two read roles and a small,
-- known data set. Used by run-tests.sh in a throwaway Postgres 17 container.

-- Like production: cw_agent is read-only by default (the MCP tests log in as it).
create role cw_agent login password 'agent';
alter role cw_agent set default_transaction_read_only = on;
create role cw_reader nologin;

create schema cw;

create table cw."SR_Board"   ("SR_Board_RecID" integer, "Board_Name" text);
create table cw."SR_Type"    ("SR_Type_RecID" integer, "Description" text);
create table cw."SR_SubType" ("SR_SubType_RecID" integer, "Description" text);
create table cw."SR_Urgency" ("SR_Urgency_RecID" integer, "Description" text);
create table cw."SR_Source"  ("SR_Source_RecID" integer, "Description" text);
create table cw."SR_Status"  ("SR_Status_RecID" integer, "Description" text, "Closed_Flag" boolean);
create table cw."Company"    ("Company_RecID" integer, "Company_Name" text);
create table cw."Member"     ("Member_ID" text, "First_Name" text, "Last_Name" text);

create table cw."SR_Service" (
    "SR_Service_RecID" integer, "Date_Entered" timestamp without time zone,
    "Date_Closed" timestamp without time zone, "SR_Board_RecID" integer,
    "SR_Type_RecID" integer, "SR_SubType_RecID" integer, "SR_Urgency_RecID" integer,
    "SR_Source_RecID" integer, "Company_RecID" integer, "SR_Status_RecID" integer,
    "Summary" text, "PM_Phase_RecID" integer,
    "Date_Entered_UTC" timestamp without time zone,
    "Date_Closed_UTC" timestamp without time zone
);
create table cw."SR_Service_SLA_Workflow" (
    "SR_Service_RecID" integer, "Date_Responded_UTC" timestamp without time zone,
    "Date_Resolved_UTC" timestamp without time zone, "Responded_Minutes" integer,
    "Resolved_Minutes" integer, "Responded_By" text, "Resolved_By" text,
    "Date_Status_Changed_UTC" timestamp without time zone
);
create table cw."SR_Service_Calculated" (
    "SR_Service_RecID" integer,
    "Expected_Responded_Expiration_Date_UTC" timestamp without time zone,
    "Expected_Resolution_Expiration_Date_UTC" timestamp without time zone
);
create table cw."Time_Entry" (
    "Time_RecID" integer, "Date_Start" timestamp without time zone, "Member_ID" text,
    "Hours_Actual" numeric, "Billable_Flag" boolean, "Charge_To_Type" text,
    "SR_Service_RecID" integer, "PM_Project_RecID" integer, "Agr_Header_RecID" integer,
    "Company_RecID" integer, "TE_Charge_Code_RecID" integer,
    "Time_Start" timestamp without time zone
);
create table cw."TE_Charge_Code" ("TE_Charge_Code_RecID" integer, "Description" text);
create table cw."PM_Phase"       ("PM_Phase_RecID" integer, "PM_Project_RecID" integer);
create table cw."PM_Status"      ("PM_Status_RecID" integer, "Description" text, "Closed_Flag" boolean);
create table cw."PM_Project" (
    "PM_Project_RecID" integer, "Project_ID" text, "Company_RecID" integer,
    "PM_Status_RecID" integer, "Member_ID" text, "Est_Hours" numeric, "Percent_Complete" numeric,
    "Date_Start" date, "Date_Req" date, "SR_Board_RecID" integer
);
create table cw."AGR_Type"   ("AGR_Type_RecID" integer, "AGR_Type_Desc" text);
create table cw."AGR_Header" (
    "AGR_Header_RecID" integer, "AGR_Name" text, "AGR_Type_RecID" integer, "Company_RecID" integer
);
create table cw."AGR_Header_Calculated" ("AGR_Header_RecID" integer, "RemainingBal" numeric);

-- Both read roles can read the mirror, as in production.
grant usage on schema cw to cw_agent, cw_reader;
grant select on all tables in schema cw to cw_agent, cw_reader;


-- Known data. m1 = last complete month, m2 = the month before.
insert into cw."SR_Board"   values (1, 'Support'), (2, 'Infrastructure'), (3, 'Backup Board'), (4, 'RMM Alerts');
insert into cw."SR_Type"    values (1, 'Request'), (2, 'Alert');
insert into cw."SR_Urgency" values (1, 'Priority 3');
insert into cw."SR_Source"  values (1, 'Email'), (2, 'Monitoring');
insert into cw."SR_Status"  values (1, 'New', false), (2, 'Closed', true);
insert into cw."Company"    values (1, 'Acme'), (2, 'Globex');
insert into cw."Member"     values ('TOtayco', 'Tony', 'O'), ('ELlanos', 'Elonah', 'L'), ('KDAbellana', 'KD', 'A');
insert into cw."TE_Charge_Code" values (1, 'Admin'), (2, 'Annual Leave');
insert into cw."PM_Status"  values (1, 'In progress', false);
insert into cw."PM_Phase"   values (100, 10);
insert into cw."PM_Project" values (10, 'Migration', 1, 1, 'TOtayco', 8, 25, current_date - 60, current_date - 5, 2);
insert into cw."AGR_Type"   values (1, 'MSP');
insert into cw."AGR_Header" values (5, 'Managed Services', 1, 1);
insert into cw."AGR_Header_Calculated" values (5, 20);

with d as (
    select date_trunc('month', now() at time zone 'Australia/Perth') - interval '1 month' + interval '2 days 10 hours' as m1,
           date_trunc('month', now() at time zone 'Australia/Perth') - interval '2 months' + interval '5 days 9 hours' as m2
)
insert into cw."SR_Service"
select 1, m1, m1 + interval '2 hours', 1, 1, null::int, 1, 1, 1, 2, 'Password reset for user 123', null::int from d
union all
select 2, m1, m1 + interval '1 hour', 1, 2, null, 1, 2, 1, 2, 'vCenter VM CPU usage alarm on host 7', null from d
union all
select 3, m2, null::timestamp, 1, 1, null, 1, 1, 2, 1, 'Password reset for user 456', null from d
union all
select 4, m1, null, 2, 1, null, 1, 1, 1, 1, 'Migration task', 100 from d
union all
-- Closed without a resolved date (SLA stop = close time, within due).
select 5, m1, m1 + interval '1 hour', 3, 1, null, 1, 1, null, 2, 'Backup job check', null from d
union all
-- Open since 2018: older than the 25-month history but still in the backlog.
select 6, timestamp '2018-03-01 09:00', null, 3, 1, null, 1, 1, null, 1, 'Old restore request', null from d
union all
-- Every ticket on the RMM Alerts board is an alert.
select 7, m1, m1 + interval '2 hours', 4, 2, null, 1, 2, null, 2, 'Disk latency high', null from d;

-- In this data local time = UTC.
update cw."SR_Service" set "Date_Entered_UTC" = "Date_Entered", "Date_Closed_UTC" = "Date_Closed";

with d as (
    select date_trunc('month', now() at time zone 'Australia/Perth') - interval '1 month' + interval '2 days 10 hours' as m1,
           date_trunc('month', now() at time zone 'Australia/Perth') - interval '2 months' + interval '5 days 9 hours' as m2
)
insert into cw."SR_Service_SLA_Workflow"
select 1, m1 + interval '10 minutes', m1 + interval '2 hours', 10, 120, 'TOtayco', 'TOtayco', m1 + interval '2 hours' from d
union all
select 3, m2 + interval '5 hours', null::timestamp, 300, null::int, 'ELlanos', null::text, m2 + interval '5 hours' from d;

with d as (
    select date_trunc('month', now() at time zone 'Australia/Perth') - interval '1 month' + interval '2 days 10 hours' as m1,
           date_trunc('month', now() at time zone 'Australia/Perth') - interval '2 months' + interval '5 days 9 hours' as m2
)
insert into cw."SR_Service_Calculated"
select 1, m1 + interval '1 hour', m1 + interval '8 hours' from d
union all
select 3, m2 + interval '1 hour', m2 + interval '8 hours' from d
union all
select 5, m1 + interval '2 hours', m1 + interval '8 hours' from d;

with d as (
    select date_trunc('month', now() at time zone 'Australia/Perth') - interval '1 month' + interval '3 days' as m1,
           date_trunc('month', now() at time zone 'Australia/Perth') - interval '2 months' + interval '6 days' as m2
)
insert into cw."Time_Entry"
select 1, m1, 'TOtayco',    2, true,  'ServiceTicket', 1,    null::int, null::int, 1, null::int from d
union all
select 2, m2, 'ELlanos',    3, false, 'ServiceTicket', 3,    null, null, 2, null from d
union all
select 3, m1, 'ELlanos',    1, false, 'ChargeCode',    null, null, null, 1, 1 from d
union all
select 4, m1, 'KDAbellana', 4, true,  'ProjectTicket', 4,    null, 5,    1, null from d
union all
-- A day of annual leave (not work: excluded from utilisation).
select 5, m1, 'ELlanos',    8, false, 'ChargeCode',    null, null, null, null, 2 from d;

-- Entry 2 started at 20:00 (after hours); the rest at 09:00.
update cw."Time_Entry"
set "Time_Start" = "Date_Start"::date + case when "Time_RecID" = 2 then time '20:00' else time '09:00' end;
