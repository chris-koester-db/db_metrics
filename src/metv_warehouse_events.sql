use catalog identifier(:catalog);
use schema identifier(:schema);

-- Quoted catalog.schema for the YAML sources, so names that need quoting (such as a hyphen) still resolve
declare or replace schema_path string = '`' || replace(:catalog, '`', '``') || '`.`' || replace(:schema, '`', '``') || '`';
declare or replace qry_str string;

set var qry_str =
  "create or replace view metv_warehouse_events
  with metrics
  language yaml
  as $$
  version: 1.1
  comment: DBSQL warehouse lifecycle and scaling events sourced from system.compute.warehouse_events. Use this metric view to analyze warehouse scaling behavior, cluster concurrency, and utilization over time.

  source: '" || schema_path || ".fct_warehouse_events'

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
    - name: event_date
      expr: calendar.calendar_date
      display_name: Event Date
      comment: Date when the warehouse event took place.
      synonyms:
        - date
        - event date
        - scaling date
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
      comment: Human-readable name of the workspace where the warehouse is deployed. Null when the workspace has been cancelled (no longer present in system.access.workspaces_latest).
      synonyms:
        - workspace
        - workspace name
    - name: workspace_id
      expr: source.workspace_id
      display_name: Workspace ID
      comment: ID of the workspace where the warehouse is deployed. Retained even when the workspace has been cancelled.
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
      expr: source.warehouse_id
      display_name: Warehouse ID
      comment: ID of the SQL warehouse the event is related to.
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
      comment: T-shirt size of the SQL warehouse. Possible values are 2X_SMALL through 5X_LARGE.
      synonyms:
        - cluster size
        - t-shirt size
    - name: event_type
      expr: source.event_type
      display_name: Event Type
      comment: Lifecycle/scaling event type. Possible values are STARTING, RUNNING, SCALED_UP, SCALED_DOWN, STOPPING, STOPPED.
      synonyms:
        - event
        - scaling event
        - lifecycle event

  measures:
    - name: event_count
      expr: COUNT(1)
      display_name: Event Count
      comment: Count of warehouse events.
      synonyms:
        - number of events
        - event volume
    - name: scale_up_events
      expr: COUNT_IF(source.event_type = 'SCALED_UP')
      display_name: Scale Up Events
      comment: Count of SCALED_UP events, where the warehouse added clusters to meet demand.
      synonyms:
        - scale ups
        - upscaling events
    - name: scale_down_events
      expr: COUNT_IF(source.event_type = 'SCALED_DOWN')
      display_name: Scale Down Events
      comment: Count of SCALED_DOWN events, where the warehouse removed clusters as demand fell.
      synonyms:
        - scale downs
        - downscaling events
    - name: start_events
      expr: COUNT_IF(source.event_type = 'STARTING')
      display_name: Start Events
      comment: Count of STARTING events, where the warehouse began provisioning from a stopped state.
      synonyms:
        - starts
        - cold starts
    - name: stop_events
      expr: COUNT_IF(source.event_type = 'STOPPING')
      display_name: Stop Events
      comment: Count of STOPPING events, where the warehouse began shutting down (typically after auto-stop).
      synonyms:
        - stops
        - shutdowns
    - name: avg_cluster_count
      expr: ROUND(AVG(source.cluster_count), 2)
      display_name: Avg Cluster Count
      comment: Average number of clusters actively running across the events in the filtered window.
      synonyms:
        - average clusters
        - mean cluster count
    - name: max_cluster_count
      expr: MAX(source.cluster_count)
      display_name: Max Cluster Count
      comment: Peak number of clusters actively running across the events in the filtered window.
      synonyms:
        - peak clusters
        - max concurrency
    - name: min_cluster_count
      expr: MIN(source.cluster_count)
      display_name: Min Cluster Count
      comment: Minimum number of clusters actively running across the events in the filtered window.
      synonyms:
        - min clusters
        - lowest cluster count
  $$";

execute immediate qry_str;
