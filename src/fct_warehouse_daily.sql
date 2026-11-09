-- fct_warehouse_daily summarizes each warehouse configuration (compute_key) per day: query demand and peaks, queueing,
-- cold starts, spill, time at max clusters, and list cost. It is the source of the warehouse sizing metric view
-- (metv_warehouse_sizing). Like the other dim_*/fct_* objects, it is a view by default, or a table rebuilt on each
-- run when the materialize parameter is 'true'. See dim_compute.sql.

use catalog identifier(:catalog);
use schema identifier(:schema);

declare or replace materialize boolean = (lower(:materialize) = 'true');
declare or replace object_name string = 'fct_warehouse_daily';
declare or replace object_comment string = 'Daily DBSQL warehouse sizing signals, one row per warehouse configuration (compute_key) per day. Built from fct_query_history, fct_warehouse_events, and fct_usage. Use this fact for right-sizing warehouses: size, min/max clusters, serverless, and auto-stop.';
declare or replace columns array<struct<name: string, type: string, comment: string>> = array(
  named_struct('name', 'calendar_key', 'type', 'int', 'comment', 'FK for calendar dimension (dim_calendar).'),
  named_struct('name', 'compute_key', 'type', 'bigint', 'comment', 'FK for compute dimension (dim_compute): the warehouse configuration in effect.'),
  named_struct('name', 'workspace_key', 'type', 'bigint', 'comment', 'FK for workspace dimension (dim_workspace).'),
  named_struct('name', 'warehouse_id', 'type', 'string', 'comment', 'ID of the SQL warehouse.'),
  named_struct('name', 'query_count', 'type', 'bigint', 'comment', 'Number of statements received.'),
  named_struct('name', 'total_duration_ms', 'type', 'bigint', 'comment', 'Sum of statement total duration in milliseconds.'),
  named_struct('name', 'peak_1m_queries', 'type', 'bigint', 'comment', 'Most statements received in any 1-minute bucket of the day.'),
  named_struct('name', 'peak_5m_queries', 'type', 'bigint', 'comment', 'Most statements received in any 5-minute bucket of the day. Divide by 5 for queries per minute.'),
  named_struct('name', 'queued_query_count', 'type', 'bigint', 'comment', 'Statements that waited for available capacity (waiting_at_capacity_duration_ms > 0).'),
  named_struct('name', 'queue_duration_ms', 'type', 'bigint', 'comment', 'Sum of time statements waited for available capacity, in milliseconds.'),
  named_struct('name', 'p95_queue_duration_ms', 'type', 'bigint', 'comment', '95th percentile of capacity queue time across statements that day, in milliseconds.'),
  named_struct('name', 'cold_start_query_count', 'type', 'bigint', 'comment', 'Statements that waited for compute to be provisioned (waiting_for_compute_duration_ms > 0).'),
  named_struct('name', 'cold_start_duration_ms', 'type', 'bigint', 'comment', 'Sum of time statements waited for compute to be provisioned, in milliseconds.'),
  named_struct('name', 'spill_query_count', 'type', 'bigint', 'comment', 'Statements that spilled to local disk.'),
  named_struct('name', 'spilled_bytes', 'type', 'bigint', 'comment', 'Sum of bytes spilled to local disk.'),
  named_struct('name', 'running_minutes', 'type', 'double', 'comment', 'Minutes the warehouse had at least one cluster running, from system.compute.warehouse_events.'),
  named_struct('name', 'cluster_minutes', 'type', 'double', 'comment', 'Sum of running clusters times minutes.'),
  named_struct('name', 'minutes_at_max_clusters', 'type', 'double', 'comment', 'Minutes the warehouse ran at its configured max_clusters, when it could not scale out further.'),
  named_struct('name', 'peak_cluster_count', 'type', 'int', 'comment', 'Most clusters running at once during the day.'),
  named_struct('name', 'dbus', 'type', 'decimal(38, 18)', 'comment', 'DBUs consumed, from system.billing.usage.'),
  named_struct('name', 'list_cost_usd', 'type', 'decimal(38, 18)', 'comment', 'List cost in USD, from system.billing.usage and system.billing.list_prices. This is list price, not negotiated price.')
);
-- Table mode only
declare or replace table_constraints string = 'constraint fk_fct_warehouse_daily_dim_calendar foreign key (calendar_key) references dim_calendar (calendar_key), constraint fk_fct_warehouse_daily_dim_compute foreign key (compute_key) references dim_compute (compute_key), constraint fk_fct_warehouse_daily_dim_workspace foreign key (workspace_key) references dim_workspace (workspace_key)';
declare or replace cluster_by string = 'calendar_key, compute_key';

-- Warehouse events record the cluster count after each event. Each event therefore starts an interval that lasts
-- until the next event, or until the warehouse was deleted. Running intervals are split at midnight UTC so that
-- minutes land on the right day. Day boundaries are computed from epoch seconds (unix_seconds div 86400), which don't
-- depend on the session time zone. A view and the session that reads it can disagree on the time zone. When events share a timestamp, the one with the higher cluster count covers the
-- following interval.
declare or replace select_stmt string = "
with query_daily as (
  select
    compute_key,
    calendar_key,
    count(*) as query_count,
    sum(total_duration_ms) as total_duration_ms,
    count_if(waiting_at_capacity_duration_ms > 0) as queued_query_count,
    sum(waiting_at_capacity_duration_ms) as queue_duration_ms,
    percentile_approx(waiting_at_capacity_duration_ms, 0.95) as p95_queue_duration_ms,
    count_if(waiting_for_compute_duration_ms > 0) as cold_start_query_count,
    sum(waiting_for_compute_duration_ms) as cold_start_duration_ms,
    count_if(spilled_local_bytes > 0) as spill_query_count,
    sum(spilled_local_bytes) as spilled_bytes
  from fct_query_history
  group by all
),
query_minutes as (
  select compute_key, calendar_key, date_trunc('minute', start_time) as minute_start, count(*) as queries
  from fct_query_history
  group by all
),
query_5_minutes as (
  select compute_key, calendar_key, sum(queries) as queries
  from query_minutes
  group by compute_key, calendar_key, floor(unix_timestamp(minute_start) / 300)
),
query_peaks as (
  select q1.compute_key, q1.calendar_key, q1.peak_1m_queries, q5.peak_5m_queries
  from (select compute_key, calendar_key, max(queries) as peak_1m_queries from query_minutes group by all) q1
  join (select compute_key, calendar_key, max(queries) as peak_5m_queries from query_5_minutes group by all) q5
    using (compute_key, calendar_key)
),
event_intervals as (
  select
    we.compute_key,
    unix_seconds(we.event_time) as interval_start,
    unix_seconds(least(
      coalesce(
        lead(we.event_time) over (partition by we.warehouse_id order by we.event_time, we.cluster_count),
        current_timestamp()
      ),
      coalesce(wd.delete_time, current_timestamp())
    )) as interval_end,
    we.cluster_count,
    dc.max_clusters
  from fct_warehouse_events we
  inner join dim_compute dc
    on dc.compute_key = we.compute_key
  left join (select warehouse_id, max(delete_time) as delete_time from dim_compute group by warehouse_id) wd
    on wd.warehouse_id = we.warehouse_id
),
running_day_slices as (
  select
    compute_key,
    cast(replace(cast(date_from_unix_date(cast(slice_day as int)) as string), '-', '') as int) as calendar_key,
    least(interval_end, (slice_day + 1) * 86400) - greatest(interval_start, slice_day * 86400) as seconds,
    cluster_count,
    max_clusters
  from event_intervals
  lateral view explode(sequence(interval_start div 86400, interval_end div 86400)) as slice_day
  where cluster_count > 0
),
event_daily as (
  select
    compute_key,
    calendar_key,
    sum(seconds) / 60 as running_minutes,
    sum(seconds * cluster_count) / 60 as cluster_minutes,
    sum(if(cluster_count >= max_clusters, seconds, 0)) / 60 as minutes_at_max_clusters,
    max(cluster_count) as peak_cluster_count
  from running_day_slices
  where seconds > 0
  group by all
),
usage_daily as (
  select compute_key, calendar_key, sum(usage_quantity) as dbus, sum(list_cost_usd) as list_cost_usd
  from fct_usage
  group by all
),
day_keys as (
  select compute_key, calendar_key from query_daily
  union
  select compute_key, calendar_key from event_daily
  union
  select compute_key, calendar_key from usage_daily
)
select
  k.calendar_key,
  k.compute_key,
  xxhash64(dc.workspace_id) as workspace_key,
  dc.warehouse_id,
  coalesce(q.query_count, 0) as query_count,
  coalesce(q.total_duration_ms, 0) as total_duration_ms,
  coalesce(p.peak_1m_queries, 0) as peak_1m_queries,
  coalesce(p.peak_5m_queries, 0) as peak_5m_queries,
  coalesce(q.queued_query_count, 0) as queued_query_count,
  coalesce(q.queue_duration_ms, 0) as queue_duration_ms,
  coalesce(q.p95_queue_duration_ms, 0) as p95_queue_duration_ms,
  coalesce(q.cold_start_query_count, 0) as cold_start_query_count,
  coalesce(q.cold_start_duration_ms, 0) as cold_start_duration_ms,
  coalesce(q.spill_query_count, 0) as spill_query_count,
  coalesce(q.spilled_bytes, 0) as spilled_bytes,
  coalesce(e.running_minutes, 0) as running_minutes,
  coalesce(e.cluster_minutes, 0) as cluster_minutes,
  coalesce(e.minutes_at_max_clusters, 0) as minutes_at_max_clusters,
  coalesce(e.peak_cluster_count, 0) as peak_cluster_count,
  coalesce(u.dbus, 0) as dbus,
  coalesce(u.list_cost_usd, 0) as list_cost_usd
from day_keys k
inner join dim_compute dc
  on dc.compute_key = k.compute_key
left join query_daily q
  on q.compute_key = k.compute_key and q.calendar_key = k.calendar_key
left join query_peaks p
  on p.compute_key = k.compute_key and p.calendar_key = k.calendar_key
left join event_daily e
  on e.compute_key = k.compute_key and e.calendar_key = k.calendar_key
left join usage_daily u
  on u.compute_key = k.compute_key and u.calendar_key = k.calendar_key";

-- The statements below are identical in every dim_*/fct_* file. They build the object from the definitions above.

-- Drop the object if it exists as the other type, so that a target can switch modes.
declare or replace stmt string;
set var stmt = (
  select coalesce(max(case
    when materialize and table_type = 'VIEW' then 'drop view ' || object_name
    when not materialize and table_type <> 'VIEW' then 'drop table ' || object_name
  end), 'select 1')
  from information_schema.tables
  where table_schema = lower(:schema) and table_name = object_name
);
execute immediate stmt;

-- Create the view, or create the table on the first run or when its columns change. An existing table is kept, so
-- that the insert overwrite below replaces its data in one step and readers never see an empty table. Changes to
-- column comments, constraints, or clustering apply when the table is next recreated.
set var stmt = (
  select case
    when not materialize then
      'create or replace view ' || object_name || ' ('
        || array_join(transform(columns, c -> c.name || " comment '" || replace(c.comment, "'", "\\'") || "'"), ', ')
        || ") comment '" || replace(object_comment, "'", "\\'") || "'"
        || ' as ' || select_stmt
    when array_join(transform(array_sort(collect_list(struct(ordinal_position, column_name))), c -> c.column_name), ',')
      = array_join(transform(columns, c -> c.name), ',') then
      "comment on table " || object_name || " is '" || replace(object_comment, "'", "\\'") || "'"
    else
      'create or replace table ' || object_name || ' ('
        || array_join(transform(columns, c -> c.name || ' ' || c.type || " comment '" || replace(c.comment, "'", "\\'") || "'"), ', ')
        || nvl2(table_constraints, ', ' || table_constraints, '')
        || ") comment '" || replace(object_comment, "'", "\\'") || "'"
        || ' cluster by (' || cluster_by || ')'
  end
  from information_schema.columns
  where table_schema = lower(:schema) and table_name = object_name
);
execute immediate stmt;

-- Table mode: load and maintain the table
set var stmt = if(materialize, 'insert overwrite ' || object_name || ' ' || select_stmt, 'select 1');
execute immediate stmt;
set var stmt = if(materialize, 'optimize ' || object_name, 'select 1');
execute immediate stmt;
set var stmt = if(materialize, 'analyze table ' || object_name || ' compute statistics for all columns', 'select 1');
execute immediate stmt;
set var stmt = if(materialize, 'vacuum ' || object_name, 'select 1');
execute immediate stmt;
