-- dim_workspace is a view over system.access.workspaces_latest by default, or a table rebuilt on each run when the materialize
-- parameter is 'true'. Both modes share the column definitions and select statement below. See dim_compute.sql.

use catalog identifier(:catalog);
use schema identifier(:schema);

declare or replace materialize boolean = (lower(:materialize) = 'true');
declare or replace object_name string = 'dim_workspace';
declare or replace object_comment string = 'Workspace dimension (snapshot) sourced from system.access.workspaces_latest. The source is a snapshot of active workspaces only; cancelled workspaces are removed, so historical fact rows for deleted workspaces have a workspace_key with no matching row.';
declare or replace columns array<struct<name: string, type: string, comment: string>> = array(
  named_struct('name', 'workspace_key', 'type', 'bigint not null', 'comment', 'Primary key (PK) of the table: a hash of workspace_id, so the key is stable across rebuilds and in view mode.'),
  named_struct('name', 'workspace_id', 'type', 'string', 'comment', 'The natural key of the workspace from system.access.workspaces_latest.'),
  named_struct('name', 'account_id', 'type', 'string', 'comment', 'The ID of the Databricks account.'),
  named_struct('name', 'workspace_name', 'type', 'string', 'comment', 'The human-readable name of the workspace.'),
  named_struct('name', 'workspace_url', 'type', 'string', 'comment', 'URL of the workspace.'),
  named_struct('name', 'create_time', 'type', 'timestamp', 'comment', 'Timestamp of when the workspace was created (second precision).'),
  named_struct('name', 'status', 'type', 'string', 'comment', 'The status of the workspace. Possible values are NOT_PROVISIONED, PROVISIONING, RUNNING, FAILED, BANNED.')
);
-- Table mode only
declare or replace table_constraints string = 'primary key (workspace_key) rely';
declare or replace cluster_by string = 'workspace_key';

declare or replace select_stmt string = "
select
  xxhash64(workspace_id) as workspace_key,
  workspace_id,
  account_id,
  workspace_name,
  workspace_url,
  create_time,
  status
from system.access.workspaces_latest";

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
