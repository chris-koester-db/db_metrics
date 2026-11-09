use catalog identifier(:catalog);
use schema identifier(:schema);

-- Quoted catalog.schema for the YAML sources, so names that need quoting (such as a hyphen) still resolve
declare or replace schema_path string = '`' || replace(:catalog, '`', '``') || '`.`' || replace(:schema, '`', '``') || '`';
declare or replace qry_str string;

set var qry_str =
  "create or replace view metv_query_history
  with metrics
  language yaml
  as $$
  version: 1.1
  comment: DBSQL query performance metrics sourced from system.query.history. Use this metric view to analyze query volume, latency, queuing, spill, failures, result-cache reuse, and the source (dashboard, notebook, job, Genie) that triggered each query.

  source: '" || schema_path || ".fct_query_history'

  joins:
    - name: calendar
      source: '" || schema_path || ".dim_calendar'
      on: calendar.calendar_key = source.calendar_key

    - name: compute
      source: '" || schema_path || ".dim_compute'
      on: compute.compute_key = source.compute_key

    - name: workspace
      source: '" || schema_path || ".dim_workspace'
      on: workspace.workspace_key = source.workspace_key

  dimensions:
    - name: query_date
      expr: calendar.calendar_date
      display_name: Query Date
      comment: Date when Databricks received the request.
      synonyms:
        - date
        - run date
        - execution date
        - statement date
    - name: calendar_month
      expr: calendar.calendar_month
      display_name: Calendar Month
      comment: Calendar month name (January, February, ...).
      synonyms:
        - month
        - month name
    - name: calendar_year
      expr: calendar.calendar_year
      display_name: Calendar Year
      comment: Calendar year.
      synonyms:
        - year
    - name: workspace_name
      expr: workspace.workspace_name
      display_name: Workspace
      comment: Human-readable name of the workspace where the statement executed. Null when the workspace has been cancelled (no longer present in system.access.workspaces_latest).
      synonyms:
        - workspace
        - workspace name
    - name: workspace_status
      expr: workspace.status
      display_name: Workspace Status
      comment: Status of the workspace. Possible values are NOT_PROVISIONED, PROVISIONING, RUNNING, FAILED, BANNED.
      synonyms:
        - workspace state
    - name: workspace_id
      expr: source.workspace_id
      display_name: Workspace ID
      comment: ID of the workspace where the statement executed. Retained even when the workspace has been cancelled.
      synonyms:
        - workspace identifier
    - name: account_id
      expr: source.account_id
      display_name: Account ID
      comment: ID of the Databricks account.
      synonyms:
        - account
        - account identifier
    - name: warehouse_id
      expr: compute.warehouse_id
      display_name: Warehouse ID
      comment: ID of the SQL warehouse that ran the statement.
      synonyms:
        - warehouse identifier
        - endpoint id
    - name: warehouse_name
      expr: compute.warehouse_name
      display_name: Warehouse
      comment: The name of the SQL warehouse.
      synonyms:
        - warehouse
        - endpoint
        - SQL warehouse
    - name: warehouse_type
      expr: compute.warehouse_type
      display_name: Warehouse Type
      comment: The type of SQL warehouse. Possible values are CLASSIC, PRO, and SERVERLESS.
      synonyms:
        - warehouse tier
        - endpoint type
    - name: warehouse_size
      expr: compute.warehouse_size
      display_name: Warehouse Size
      comment: T-shirt size of the SQL warehouse at the time of the query. Possible values are 2X_SMALL through 5X_LARGE.
      synonyms:
        - cluster size
        - t-shirt size
    - name: client_application
      expr: source.client_application
      display_name: Client App
      comment: 'Client application that ran the statement. For example: Databricks SQL, Tableau, Power BI. Nulls and blanks are labeled as Unknown.'
      synonyms:
        - app
        - application
        - tool
        - BI tool
    - name: client_driver
      expr: source.client_driver
      display_name: Client Driver
      comment: 'The connector used to run the statement. For example: JDBC, ODBC, Go Driver.'
      synonyms:
        - driver
        - connector
    - name: executed_by
      expr: source.executed_by
      display_name: Executed By
      comment: Email or username of the user who ran the statement.
      synonyms:
        - user
        - run by
        - submitter
    - name: executed_as
      expr: source.executed_as
      display_name: Executed As
      comment: Name of the user or service principal whose privilege was used to run the statement.
      synonyms:
        - run as
        - effective user
    - name: execution_status
      expr: source.execution_status
      display_name: Execution Status
      comment: Statement termination state. Possible values are FINISHED, FAILED, and CANCELED.
      synonyms:
        - status
        - outcome
        - result
    - name: statement_type
      expr: source.statement_type
      display_name: Statement Type
      comment: 'Statement category. For example: SELECT, INSERT, UPDATE, DELETE, MERGE, COPY, ALTER.'
      synonyms:
        - query type
        - sql type
    - name: from_result_cache
      expr: source.from_result_cache
      display_name: Result Cache Hit
      comment: True if the statement result was served from the result cache.
      synonyms:
        - cache hit
        - cached result
    - name: query_source
      expr: |
        case
          when source.source_genie_space_id is not null then 'Genie'
          when source.source_dashboard_id is not null or source.source_legacy_dashboard_id is not null then 'Dashboard'
          when source.source_notebook_id is not null then 'Notebook'
          when source.source_job_id is not null then 'Job'
          when source.source_alert_id is not null then 'Alert'
          when source.source_sql_query_id is not null then 'SQL Editor'
          else 'Other'
        end
      display_name: Query Source
      comment: Where the query originated. Values are Genie, Dashboard, Notebook, Job, Alert, SQL Editor, or Other.
      synonyms:
        - origin
        - submitted from
        - triggered by
    - name: query_source_id
      expr: |
        coalesce(
          cast(source.source_job_id as string),
          source.source_legacy_dashboard_id,
          source.source_dashboard_id,
          source.source_alert_id,
          source.source_notebook_id,
          source.source_sql_query_id,
          source.source_genie_space_id,
          'UNKNOWN'
        )
      display_name: Query Source ID
      comment: Identifier of the object that triggered the query (job, dashboard, alert, notebook, SQL query, or Genie Agent). UNKNOWN when no source is recorded.
      synonyms:
        - source id
        - origin id
    - name: error_type
      expr: |
        CASE
          WHEN COALESCE(source.error_message, '') = '' THEN 'NO ERROR'
          ELSE COALESCE(
            NULLIF(REGEXP_EXTRACT(source.error_message, r'\\[(.*?)\\]', 1), ''),
            NULLIF(REGEXP_EXTRACT(source.error_message, r'^([A-Z][A-Z0-9_]+):', 1), ''),
            'OTHER'
          )
        END
      display_name: Error Type
      comment: Error code from error_message, taken from the first [BRACKETED] token or else a leading CODE prefix (such as PERMISSION_DENIED). OTHER for errors with neither, and NO ERROR when there is no error message.
      synonyms:
        - error code
        - error bucket
        - failure type
    - name: query_tag_raw
      expr: |
        NULLIF(
          REGEXP_REPLACE(
            REGEXP_EXTRACT(source.statement_text, r'/\\*.*?QUERY_TAG:(.*?)(?=\\*/)', 1),
            'QUERY_TAG:', ''
          ),
          ''
        )
      display_name: Query Tag
      comment: Value of a /* QUERY_TAG:... */ comment embedded in the SQL text. Null when no tag is present.
      synonyms:
        - query tag
        - tag
        - sql tag
    - name: used_cache_flag
      expr: |
        case when source.read_io_cache_percent > 0 then 'Used Cache' else 'No Cache' end
      display_name: Used Cache
      comment: Whether any bytes were served from the IO cache ('Used Cache' vs 'No Cache').
      synonyms:
        - cache usage
        - io cache flag
    - name: has_spill_flag
      expr: |
        case when source.spilled_local_bytes > 0 then 'Spilled Data To Disk' else 'No Spill' end
      display_name: Has Spill
      comment: Whether the query spilled data to local disk during execution.
      synonyms:
        - spill flag
        - spilled to disk
    - name: read_data_flag
      expr: |
        case when source.read_bytes > 0 then 'Did Read Data' else 'No Data Read' end
      display_name: Read Data
      comment: Whether the query read any data from storage.
      synonyms:
        - read flag
        - did read data
    - name: used_worker_tasks_flag
      expr: |
        case when coalesce(source.total_task_duration_ms, 0) > 0 then 'UsedWorkerTasks' else 'NoWorkers' end
      display_name: Used Worker Tasks
      comment: Whether the query used worker task time (as opposed to a metadata-only operation).
      synonyms:
        - used workers
        - worker tasks flag

  measures:
    - name: query_count
      expr: COUNT(source.statement_id)
      display_name: Total Queries
      comment: Count of queries.
      synonyms:
        - number of queries
        - statement count
        - query volume
    - name: failed_queries
      expr: SUM(CASE WHEN source.execution_status = 'FAILED' THEN 1 ELSE 0 END)
      display_name: Failed Queries
      comment: Count of queries with execution_status = FAILED.
      synonyms:
        - failures
        - error count
    - name: canceled_queries
      expr: COUNT_IF(source.execution_status = 'CANCELED')
      display_name: Canceled Queries
      comment: Count of queries with execution_status = CANCELED.
      synonyms:
        - cancellations
        - canceled count
    - name: failure_rate
      expr: COUNT_IF(source.execution_status = 'FAILED') * 1.0 / NULLIF(COUNT(source.statement_id), 0)
      display_name: Failure Rate
      comment: Share of queries that failed (failed / total).
      synonyms:
        - error rate
        - failure percentage
    - name: cache_hit_pct
      expr: TRY_DIVIDE(COUNT_IF(source.from_result_cache), COUNT(source.statement_id))
      display_name: Result Cache Hit Rate
      comment: Share of queries served from the result cache.
      synonyms:
        - cache hit rate
        - cached result rate
    - name: p90_runtime_sec
      expr: ROUND(PERCENTILE(source.total_duration_ms, 0.90) / 1000.0, 2)
      display_name: P90 Runtime (s)
      comment: P90 of total_duration_ms in seconds (excludes result fetch).
      synonyms:
        - p90 latency
        - 90th percentile runtime
    - name: p95_runtime_sec
      expr: ROUND(PERCENTILE(source.total_duration_ms, 0.95) / 1000.0, 2)
      display_name: P95 Runtime (s)
      comment: P95 of total_duration_ms in seconds.
      synonyms:
        - p95 latency
        - 95th percentile runtime
        - tail latency
    - name: max_runtime_sec
      expr: ROUND(MAX(COALESCE(TRY_DIVIDE(source.total_duration_ms, 1000), 0)), 2)
      display_name: Max Runtime (s)
      comment: Maximum total_duration_ms in seconds.
      synonyms:
        - longest query
        - max latency
    - name: queued_queries
      expr: SUM(CASE WHEN COALESCE(TRY_DIVIDE(source.waiting_at_capacity_duration_ms, 1000), 0) > 0 THEN 1 ELSE 0 END)
      display_name: Queued Queries
      comment: Count of queries that spent time waiting in queue at capacity.
      synonyms:
        - number queued
        - queued count
    - name: spill_queries
      expr: SUM(CASE WHEN source.spilled_local_bytes > 0 THEN 1 ELSE 0 END)
      display_name: Spill Queries
      comment: Count of queries that spilled data to local disk.
      synonyms:
        - spilling queries
        - spill count
    - name: avg_compile_sec
      expr: ROUND(AVG(COALESCE(TRY_DIVIDE(source.compilation_duration_ms, 1000), 0)), 2)
      display_name: Avg Compile (s)
      comment: Average time spent loading metadata and optimizing the statement in seconds.
      synonyms:
        - average compilation time
        - mean planning time
    - name: avg_queue_sec
      expr: ROUND(AVG(COALESCE(TRY_DIVIDE(source.waiting_at_capacity_duration_ms, 1000), 0)), 2)
      display_name: Avg Queue (s)
      comment: Average time spent waiting in queue at capacity, in seconds.
      synonyms:
        - average queue time
        - mean queue wait
    - name: avg_wait_compute_sec
      expr: ROUND(AVG(COALESCE(TRY_DIVIDE(source.waiting_for_compute_duration_ms, 1000), 0)), 2)
      display_name: Avg Wait For Compute (s)
      comment: Average time spent waiting for compute resources to be provisioned, in seconds.
      synonyms:
        - average startup wait
        - mean compute wait
    - name: p90_queue_sec
      expr: ROUND(PERCENTILE(source.waiting_at_capacity_duration_ms, 0.90) / 1000.0, 2)
      display_name: P90 Queue (s)
      comment: P90 of time waiting in queue at capacity, in seconds.
      synonyms:
        - p90 queue time
    - name: p95_queue_sec
      expr: ROUND(PERCENTILE(source.waiting_at_capacity_duration_ms, 0.95) / 1000.0, 2)
      display_name: P95 Queue (s)
      comment: P95 of time waiting in queue at capacity, in seconds.
      synonyms:
        - p95 queue time
        - tail queue
    - name: total_duration_sec
      expr: SUM(source.total_duration_ms) / 1000.0
      display_name: Total Duration (s)
      comment: Sum of total_duration_ms expressed in seconds.
      synonyms:
        - cumulative duration
        - total runtime
    - name: avg_duration_sec
      expr: AVG(source.total_duration_ms) / 1000.0
      display_name: Avg Duration (s)
      comment: Average total_duration_ms in seconds.
      synonyms:
        - mean duration
        - average latency
    - name: p50_runtime_sec
      expr: PERCENTILE(source.total_duration_ms / 1000.0, 0.5)
      display_name: Median Runtime (s)
      comment: P50 of total_duration_ms in seconds (excludes result fetch).
      synonyms:
        - median latency
        - p50 duration
        - typical query time
    - name: avg_cpu_time_sec
      expr: AVG(source.total_task_duration_ms) / 1000.0
      display_name: Avg CPU Time (s)
      comment: Average total task (CPU) time per query in seconds (sum of task durations across all cores).
      synonyms:
        - average cpu time
        - mean task time
    - name: avg_execution_sec
      expr: AVG(source.execution_duration_ms) / 1000.0
      display_name: Avg Execution (s)
      comment: Average time spent executing the statement in seconds (excludes compilation, queue, and result fetch).
      synonyms:
        - average execution time
        - mean execution time
    - name: avg_result_fetch_sec
      expr: AVG(source.result_fetch_duration_ms) / 1000.0
      display_name: Avg Result Fetch (s)
      comment: Average time spent fetching statement results in seconds.
      synonyms:
        - average fetch time
        - mean result fetch
    - name: queue_proportion_p50
      expr: PERCENTILE((source.waiting_for_compute_duration_ms + source.waiting_at_capacity_duration_ms) * 1.0 / NULLIF(source.total_duration_ms, 0), 0.5)
      display_name: Median Queue Proportion
      comment: P50 of the share of total duration spent queuing (total queue time / total duration).
      synonyms:
        - median queue share
        - p50 queue proportion
    - name: bytes_read
      expr: SUM(source.read_bytes)
      display_name: Bytes Read
      comment: Total bytes read across queries.
      synonyms:
        - data read
        - read volume
    - name: bytes_written
      expr: SUM(source.written_bytes)
      display_name: Bytes Written
      comment: Total bytes of persistent data written across queries.
      synonyms:
        - data written
        - write volume
    - name: avg_read_gb
      expr: AVG(source.read_bytes) / (1024.0 * 1024.0 * 1024.0)
      display_name: Avg Read (GB)
      comment: Average data read per query in gigabytes.
      synonyms:
        - average gb read
        - mean read volume
    - name: avg_written_gb
      expr: AVG(source.written_bytes) / (1024.0 * 1024.0 * 1024.0)
      display_name: Avg Written (GB)
      comment: Average persistent data written per query in gigabytes.
      synonyms:
        - average gb written
        - mean write volume
    - name: avg_spilled_gb
      expr: AVG(source.spilled_local_bytes) / (1024.0 * 1024.0 * 1024.0)
      display_name: Avg Spilled (GB)
      comment: Average data spilled to local disk per query in gigabytes.
      synonyms:
        - average gb spilled
        - mean spill volume
    - name: total_read_gb
      expr: SUM(source.read_bytes) / (1024.0 * 1024.0 * 1024.0)
      display_name: Total Read (GB)
      comment: Total data read across queries in gigabytes.
      synonyms:
        - gb read
        - total read volume
    - name: total_written_gb
      expr: SUM(source.written_bytes) / (1024.0 * 1024.0 * 1024.0)
      display_name: Total Written (GB)
      comment: Total persistent data written across queries in gigabytes.
      synonyms:
        - gb written
        - total write volume
    - name: total_spilled_gb
      expr: SUM(source.spilled_local_bytes) / (1024.0 * 1024.0 * 1024.0)
      display_name: Total Spilled (GB)
      comment: Total data spilled to local disk across queries in gigabytes.
      synonyms:
        - gb spilled
        - total spill volume
    - name: spilling_query_rate
      expr: COUNT_IF(source.spilled_local_bytes > 0) * 1.0 / NULLIF(COUNT(source.statement_id), 0)
      display_name: Spilling Query Rate
      comment: Share of queries that spilled data to local disk.
      synonyms:
        - spill rate
        - percent spilling
    - name: io_cache_hit_rate
      expr: COUNT_IF(source.read_io_cache_percent > 0) * 1.0 / NULLIF(COUNT(source.statement_id), 0)
      display_name: IO Cache Hit Rate
      comment: Share of queries that read at least some data from the IO cache. Distinct from cache_hit_pct, which measures full result reuse.
      synonyms:
        - io cache rate
        - disk cache hit rate
    - name: distinct_users
      expr: COUNT(DISTINCT source.executed_by_user_id)
      display_name: Distinct Users
      comment: Number of distinct users that ran a statement in the filtered window.
      synonyms:
        - active users
        - user count
    - name: distinct_workspaces
      expr: COUNT(DISTINCT source.workspace_id)
      display_name: Distinct Workspaces
      comment: Number of distinct workspaces observed in the filtered window.
      synonyms:
        - workspace count
        - unique workspaces
  $$";

execute immediate qry_str;
