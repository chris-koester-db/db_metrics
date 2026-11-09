-- fct_warehouse_events is a view over system.compute.warehouse_events by default, or a table rebuilt on each run when the materialize
-- parameter is 'true'. Both modes share the column definitions and select statement below. See dim_compute.sql.

use catalog identifier(:catalog);
use schema identifier(:schema);

declare or replace materialize boolean = (lower(:materialize) = 'true');
declare or replace object_name string = 'fct_warehouse_events';
declare or replace object_comment string = 'DBSQL warehouse lifecycle and scaling events sourced from system.compute.warehouse_events, restricted to the last 6 months. Use this fact for warehouse scaling, utilization, and concurrency analysis.';
declare or replace columns array<struct<name: string, type: string, comment: string>> = array(
  named_struct('name', 'calendar_key', 'type', 'int', 'comment', 'FK for calendar dimension (dim_calendar).'),
  named_struct('name', 'compute_key', 'type', 'bigint', 'comment', 'FK for compute dimension (dim_compute).'),
  named_struct('name', 'workspace_key', 'type', 'bigint', 'comment', 'FK for workspace dimension (dim_workspace). A hash of workspace_id. Has no matching dim_workspace row when the workspace no longer exists in system.access.workspaces_latest (e.g., cancelled workspace).'),
  named_struct('name', 'account_id', 'type', 'string', 'comment', 'The ID of the Databricks account.'),
  named_struct('name', 'workspace_id', 'type', 'string', 'comment', 'The ID of the workspace where the warehouse is deployed.'),
  named_struct('name', 'warehouse_id', 'type', 'string', 'comment', 'The ID of the SQL warehouse the event is related to.'),
  named_struct('name', 'event_type', 'type', 'string', 'comment', 'Lifecycle/scaling event type. Possible values are STARTING, RUNNING, SCALED_UP, SCALED_DOWN, STOPPING, STOPPED.'),
  named_struct('name', 'cluster_count', 'type', 'int', 'comment', 'The number of clusters that are actively running at the time of the event.'),
  named_struct('name', 'event_time', 'type', 'timestamp', 'comment', 'Timestamp of when the event took place in UTC.'),
  named_struct('name', 'event_date', 'type', 'date', 'comment', 'Date portion of event_time, in UTC. Use this field for faster aggregation by date.')
);
-- Table mode only
declare or replace table_constraints string = 'constraint fk_fct_warehouse_events_dim_calendar foreign key (calendar_key) references dim_calendar (calendar_key), constraint fk_fct_warehouse_events_dim_compute foreign key (compute_key) references dim_compute (compute_key), constraint fk_fct_warehouse_events_dim_workspace foreign key (workspace_key) references dim_workspace (workspace_key)';
declare or replace cluster_by string = 'calendar_key, compute_key';

-- calendar_key is the UTC date of event_time, computed from epoch seconds so that it doesn't depend on the session time zone.
declare or replace select_stmt string = "
select
  cast(replace(cast(date_from_unix_date(cast(unix_seconds(we.event_time) div 86400 as int)) as string), '-', '') as int) as calendar_key,
  dc.compute_key,
  xxhash64(we.workspace_id) as workspace_key,
  we.account_id,
  we.workspace_id,
  we.warehouse_id,
  we.event_type,
  we.cluster_count,
  we.event_time,
  date_from_unix_date(cast(unix_seconds(we.event_time) div 86400 as int)) as event_date
from system.compute.warehouse_events we
inner join dim_compute dc
  on dc.warehouse_id = we.warehouse_id
  and we.event_time >= dc.effective_start
  and we.event_time < coalesce(dc.effective_end, timestamp('9999-12-31'))
where we.event_time >= current_date() - interval 6 months";

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
