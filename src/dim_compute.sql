-- dim_compute is a view over system.compute.warehouses by default, or a table rebuilt on each run when the
-- materialize parameter is 'true'. Both modes share the column definitions and select statement below, so
-- downstream objects work unchanged in either mode.

use catalog identifier(:catalog);
use schema identifier(:schema);

declare or replace materialize boolean = (lower(:materialize) = 'true');
declare or replace object_name string = 'dim_compute';
declare or replace object_comment string = 'DBSQL warehouse dimension (SCD Type 2) sourced from system.compute.warehouses. The earliest record per warehouse is backdated to 1970-01-01 so that historical usage joins always find a match.';
declare or replace columns array<struct<name: string, type: string, comment: string>> = array(
  named_struct('name', 'compute_key', 'type', 'bigint not null', 'comment', 'Primary key (PK) of the table: a hash of warehouse_id and change_time, so the key is stable across rebuilds and in view mode.'),
  named_struct('name', 'warehouse_id', 'type', 'string', 'comment', 'The natural key of the warehouse from system.compute.warehouses.'),
  named_struct('name', 'workspace_id', 'type', 'string', 'comment', 'The ID of the workspace where the warehouse is deployed.'),
  named_struct('name', 'account_id', 'type', 'string', 'comment', 'The ID of the Databricks account.'),
  named_struct('name', 'warehouse_name', 'type', 'string', 'comment', 'The name of the SQL warehouse.'),
  named_struct('name', 'warehouse_type', 'type', 'string', 'comment', 'The type of SQL warehouse. Possible values are CLASSIC, PRO, and SERVERLESS.'),
  named_struct('name', 'warehouse_channel', 'type', 'string', 'comment', 'The release channel of the SQL warehouse. Possible values are CURRENT and PREVIEW.'),
  named_struct('name', 'warehouse_size', 'type', 'string', 'comment', 'The cluster size of the SQL warehouse. Possible values are 2X_SMALL, X_SMALL, SMALL, MEDIUM, LARGE, X_LARGE, 2X_LARGE, 3X_LARGE, 4X_LARGE, and 5X_LARGE.'),
  named_struct('name', 'min_clusters', 'type', 'int', 'comment', 'The minimum number of clusters permitted.'),
  named_struct('name', 'max_clusters', 'type', 'int', 'comment', 'The maximum number of clusters permitted.'),
  named_struct('name', 'auto_stop_minutes', 'type', 'int', 'comment', 'The number of minutes before the SQL warehouse auto-stops due to inactivity.'),
  named_struct('name', 'tags', 'type', 'map<string, string>', 'comment', 'Warehouse-level tags applied at the time of the change record.'),
  named_struct('name', 'change_time', 'type', 'timestamp', 'comment', 'Timestamp of change to the SQL warehouse definition.'),
  named_struct('name', 'delete_time', 'type', 'timestamp', 'comment', 'Timestamp of when the SQL warehouse was deleted. The value is null if the SQL warehouse is not deleted.'),
  named_struct('name', 'effective_start', 'type', 'timestamp', 'comment', 'Timestamp when this version of the record became effective.'),
  named_struct('name', 'effective_end', 'type', 'timestamp', 'comment', 'Timestamp when this version was superseded. NULL indicates the current active record.'),
  named_struct('name', 'is_current', 'type', 'boolean', 'comment', 'Flag indicating whether this is the current active version of the record.')
);
-- Table mode only
declare or replace table_constraints string = 'primary key (compute_key) rely';
declare or replace cluster_by string = 'compute_key';

-- Warehouses SCD Type 2: retain full history of configuration changes
-- The earliest record per warehouse is backdated to cover usage that predates
-- the first recorded change_time in system.compute.warehouses. The subquery keeps one record per warehouse and
-- change_time, so that compute_key stays unique even if the source has tied change records.
declare or replace select_stmt string = "
select
  xxhash64(warehouse_id, change_time) as compute_key,
  warehouse_id,
  workspace_id,
  account_id,
  warehouse_name,
  warehouse_type,
  warehouse_channel,
  warehouse_size,
  min_clusters,
  max_clusters,
  auto_stop_minutes,
  tags,
  change_time,
  delete_time,
  case
    when row_number() over (partition by warehouse_id order by change_time) = 1
    then timestamp('1970-01-01')
    else change_time
  end as effective_start,
  lead(change_time) over (partition by warehouse_id order by change_time) as effective_end,
  row_number() over (partition by warehouse_id order by change_time desc) = 1 as is_current
from (
  select *
  from system.compute.warehouses
  qualify row_number() over (
    partition by warehouse_id, change_time
    order by delete_time desc nulls last, warehouse_name, warehouse_size, min_clusters, max_clusters, auto_stop_minutes
  ) = 1
)";

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
