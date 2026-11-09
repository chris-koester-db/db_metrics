-- fct_query_history is a view over system.query.history by default, or a table rebuilt on each run when the materialize
-- parameter is 'true'. Both modes share the column definitions and select statement below. See dim_compute.sql.

use catalog identifier(:catalog);
use schema identifier(:schema);

declare or replace materialize boolean = (lower(:materialize) = 'true');
declare or replace object_name string = 'fct_query_history';
declare or replace object_comment string = 'DBSQL query execution history sourced from system.query.history, restricted to warehouse queries and the last 6 months.';
declare or replace columns array<struct<name: string, type: string, comment: string>> = array(
  named_struct('name', 'calendar_key', 'type', 'int', 'comment', 'FK for calendar dimension (dim_calendar).'),
  named_struct('name', 'compute_key', 'type', 'bigint', 'comment', 'FK for compute dimension (dim_compute).'),
  named_struct('name', 'workspace_key', 'type', 'bigint', 'comment', 'FK for workspace dimension (dim_workspace). A hash of workspace_id. Has no matching dim_workspace row when the workspace no longer exists in system.access.workspaces_latest (e.g., cancelled workspace).'),
  named_struct('name', 'statement_id', 'type', 'string', 'comment', 'The ID that uniquely identifies the execution of the statement. You can use this ID to find the statement execution in the Query History UI.'),
  named_struct('name', 'account_id', 'type', 'string', 'comment', 'ID of the Databricks account that executed the statement.'),
  named_struct('name', 'workspace_id', 'type', 'string', 'comment', 'ID of the workspace where the statement executed.'),
  named_struct('name', 'compute_type', 'type', 'string', 'comment', 'Type of compute that ran the statement. Possible values are WAREHOUSE and SERVERLESS_COMPUTE.'),
  named_struct('name', 'executed_by', 'type', 'string', 'comment', 'The email address or username of the user who ran the statement.'),
  named_struct('name', 'executed_by_user_id', 'type', 'string', 'comment', 'The ID of the user who ran the statement.'),
  named_struct('name', 'executed_as', 'type', 'string', 'comment', 'The name of the user or service principal whose privilege was used to run the statement.'),
  named_struct('name', 'executed_as_user_id', 'type', 'string', 'comment', 'The ID of the user or service principal whose privilege was used to run the statement.'),
  named_struct('name', 'session_id', 'type', 'string', 'comment', 'The Spark session ID.'),
  named_struct('name', 'execution_status', 'type', 'string', 'comment', 'The statement termination state. Possible values are FINISHED (execution was successful), FAILED (execution failed with the reason described in the accompanying error message), and CANCELED (execution was canceled).'),
  named_struct('name', 'statement_text', 'type', 'string', 'comment', 'Text of the SQL statement. If you have configured customer-managed keys, statement_text is empty.'),
  named_struct('name', 'statement_type', 'type', 'string', 'comment', 'The statement type. For example: ALTER, COPY, INSERT, SELECT, UPDATE, DELETE, MERGE.'),
  named_struct('name', 'error_message', 'type', 'string', 'comment', 'Message describing the error condition. If you have configured customer-managed keys, error_message is empty.'),
  named_struct('name', 'client_application', 'type', 'string', 'comment', 'Client application that ran the statement. For example: Databricks SQL, Tableau, Power BI. Nulls and blanks are labeled as Unknown.'),
  named_struct('name', 'client_driver', 'type', 'string', 'comment', 'The connector used to connect to Databricks to run the statement. For example: Databricks SQL Driver for Go, Databricks ODBC Driver, Databricks JDBC Driver.'),
  named_struct('name', 'cache_origin_statement_id', 'type', 'string', 'comment', 'If the result was served from the result cache, the ID of the original statement that produced it. Otherwise, the statement_id of this statement.'),
  named_struct('name', 'from_result_cache', 'type', 'boolean', 'comment', 'True indicates that the statement result was fetched from the result cache.'),
  named_struct('name', 'total_duration_ms', 'type', 'bigint', 'comment', 'Total execution time of the statement in milliseconds (excluding result fetch time).'),
  named_struct('name', 'waiting_for_compute_duration_ms', 'type', 'bigint', 'comment', 'Time spent waiting for compute resources to be provisioned in milliseconds.'),
  named_struct('name', 'waiting_at_capacity_duration_ms', 'type', 'bigint', 'comment', 'Time spent waiting in queue for available compute capacity in milliseconds.'),
  named_struct('name', 'execution_duration_ms', 'type', 'bigint', 'comment', 'Time spent executing the statement in milliseconds.'),
  named_struct('name', 'compilation_duration_ms', 'type', 'bigint', 'comment', 'Time spent loading metadata and optimizing the statement in milliseconds.'),
  named_struct('name', 'total_task_duration_ms', 'type', 'bigint', 'comment', 'Sum of all task durations in milliseconds across all cores of all nodes.'),
  named_struct('name', 'result_fetch_duration_ms', 'type', 'bigint', 'comment', 'Time spent, in milliseconds, fetching the statement results after the execution finished.'),
  named_struct('name', 'start_time', 'type', 'timestamp', 'comment', 'The time when Databricks received the request. Timezone information is recorded at the end of the value with +00:00 representing UTC.'),
  named_struct('name', 'end_time', 'type', 'timestamp', 'comment', 'The time the statement execution ended, excluding result fetch time. Timezone information is recorded at the end of the value with +00:00 representing UTC.'),
  named_struct('name', 'update_time', 'type', 'timestamp', 'comment', 'The time the statement last received a progress update. Timezone information is recorded at the end of the value with +00:00 representing UTC.'),
  named_struct('name', 'read_partitions', 'type', 'bigint', 'comment', 'The number of partitions read after pruning.'),
  named_struct('name', 'pruned_files', 'type', 'bigint', 'comment', 'The number of pruned files.'),
  named_struct('name', 'read_files', 'type', 'bigint', 'comment', 'The number of files read after pruning.'),
  named_struct('name', 'read_rows', 'type', 'bigint', 'comment', 'Total number of rows read by the statement.'),
  named_struct('name', 'produced_rows', 'type', 'bigint', 'comment', 'Total number of rows returned by the statement.'),
  named_struct('name', 'read_bytes', 'type', 'bigint', 'comment', 'Total size of data read by the statement in bytes.'),
  named_struct('name', 'read_io_cache_percent', 'type', 'int', 'comment', 'The percentage of bytes of persistent data read from the IO cache.'),
  named_struct('name', 'spilled_local_bytes', 'type', 'bigint', 'comment', 'Size of data, in bytes, temporarily written to disk while executing the statement.'),
  named_struct('name', 'written_bytes', 'type', 'bigint', 'comment', 'The size in bytes of persistent data written to cloud object storage.'),
  named_struct('name', 'written_rows', 'type', 'bigint', 'comment', 'Number of persistent rows written by the statement.'),
  named_struct('name', 'written_files', 'type', 'bigint', 'comment', 'Number of persistent files written by the statement.'),
  named_struct('name', 'shuffle_read_bytes', 'type', 'bigint', 'comment', 'The total amount of data in bytes sent over the network.'),
  named_struct('name', 'source_alert_id', 'type', 'string', 'comment', 'Alert ID if the statement was triggered by an alert (from query_source.alert_id).'),
  named_struct('name', 'source_sql_query_id', 'type', 'string', 'comment', 'SQL editor query ID if the statement was executed from the SQL editor (from query_source.sql_query_id).'),
  named_struct('name', 'source_dashboard_id', 'type', 'string', 'comment', 'Dashboard ID if the statement was executed from a dashboard (from query_source.dashboard_id).'),
  named_struct('name', 'source_legacy_dashboard_id', 'type', 'string', 'comment', 'Legacy dashboard ID if applicable (from query_source.legacy_dashboard_id).'),
  named_struct('name', 'source_notebook_id', 'type', 'string', 'comment', 'Notebook ID if the statement was executed from a notebook (from query_source.notebook_id).'),
  named_struct('name', 'source_job_id', 'type', 'bigint', 'comment', 'Job ID if the statement was executed by a job (from query_source.job_info.job_id).'),
  named_struct('name', 'source_job_run_id', 'type', 'string', 'comment', 'Job run ID if the statement was executed by a job (from query_source.job_info.job_run_id).'),
  named_struct('name', 'source_job_task_run_id', 'type', 'bigint', 'comment', 'Job task run ID if the statement was executed by a job (from query_source.job_info.job_task_run_id).'),
  named_struct('name', 'source_genie_space_id', 'type', 'string', 'comment', 'Genie Agent ID if the statement was executed from a Genie Agent (from query_source.genie_space_id).'),
  named_struct('name', 'query_tags', 'type', 'map<string, string>', 'comment', 'Custom key-value tags applied to the query.')
);
-- Table mode only
declare or replace table_constraints string = 'constraint fk_fct_query_history_dim_calendar foreign key (calendar_key) references dim_calendar (calendar_key), constraint fk_fct_query_history_dim_compute foreign key (compute_key) references dim_compute (compute_key), constraint fk_fct_query_history_dim_workspace foreign key (workspace_key) references dim_workspace (workspace_key)';
declare or replace cluster_by string = 'calendar_key, compute_key';

-- calendar_key is the UTC date of start_time, computed from epoch seconds so that it doesn't depend on the session time zone.
declare or replace select_stmt string = "
select
  cast(replace(cast(date_from_unix_date(cast(unix_seconds(qh.start_time) div 86400 as int)) as string), '-', '') as int) as calendar_key,
  dc.compute_key,
  xxhash64(qh.workspace_id) as workspace_key,
  qh.statement_id,
  qh.account_id,
  qh.workspace_id,
  qh.compute.type as compute_type,
  qh.executed_by,
  qh.executed_by_user_id,
  qh.executed_as,
  qh.executed_as_user_id,
  qh.session_id,
  qh.execution_status,
  qh.statement_text,
  qh.statement_type,
  qh.error_message,
  case
    when qh.client_application is null or lower(qh.client_application) in ('', 'unknown') then 'Unknown'
    else qh.client_application
  end as client_application,
  qh.client_driver,
  qh.cache_origin_statement_id,
  qh.from_result_cache,
  qh.total_duration_ms,
  qh.waiting_for_compute_duration_ms,
  qh.waiting_at_capacity_duration_ms,
  qh.execution_duration_ms,
  qh.compilation_duration_ms,
  qh.total_task_duration_ms,
  qh.result_fetch_duration_ms,
  qh.start_time,
  qh.end_time,
  qh.update_time,
  qh.read_partitions,
  qh.pruned_files,
  qh.read_files,
  qh.read_rows,
  qh.produced_rows,
  qh.read_bytes,
  qh.read_io_cache_percent,
  qh.spilled_local_bytes,
  qh.written_bytes,
  qh.written_rows,
  qh.written_files,
  qh.shuffle_read_bytes,
  qh.query_source.alert_id as source_alert_id,
  qh.query_source.sql_query_id as source_sql_query_id,
  qh.query_source.dashboard_id as source_dashboard_id,
  qh.query_source.legacy_dashboard_id as source_legacy_dashboard_id,
  qh.query_source.notebook_id as source_notebook_id,
  qh.query_source.job_info.job_id as source_job_id,
  qh.query_source.job_info.job_run_id as source_job_run_id,
  qh.query_source.job_info.job_task_run_id as source_job_task_run_id,
  qh.query_source.genie_space_id as source_genie_space_id,
  qh.query_tags
from system.query.history qh
inner join dim_compute dc
  on dc.warehouse_id = qh.compute.warehouse_id
  and qh.start_time >= dc.effective_start
  and qh.start_time < coalesce(dc.effective_end, timestamp('9999-12-31'))
where qh.start_time >= current_date() - interval 6 months";

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
