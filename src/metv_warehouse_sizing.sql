-- Warehouse right-sizing metric view. Measures normalize sizing signals by active day and query count, and
-- recommendation measures apply the sizing rules over whatever date range the caller filters to. The rules follow
-- Databricks field guidance for sizing SQL warehouses, with thresholds passed in as sizing_* job parameters.
--
-- Rules, in priority order (the first match wins):
--   1. Too little activity             -> no recommendation
--   2. Cold starts on Classic/Pro      -> switch to serverless
--   3. Spill and capacity queueing     -> one size up and one more max cluster
--   4. Spill only                      -> one size up
--   5. Queueing below max clusters     -> one more min cluster (scale-out lag at peaks). Needs warehouse event
--                                         data showing little time at max clusters, and min below max.
--   6. Other queueing                  -> one more max cluster
--   7. Low pressure                    -> one size down
--   8. Serverless auto-stop too long   -> lower auto-stop
-- Recommendations use the latest configuration in the filtered range, so filter to is_current_config = true to
-- judge the current configuration on evidence gathered under it.

use catalog identifier(:catalog);
use schema identifier(:schema);

-- Quoted catalog.schema for the YAML sources, so names that need quoting (such as a hyphen) still resolve
declare or replace schema_path string = '`' || replace(:catalog, '`', '``') || '`.`' || replace(:schema, '`', '``') || '`';
declare or replace qry_str string;

set var qry_str =
  "create or replace view metv_warehouse_sizing
  with metrics
  language yaml
  as $$
  version: 1.1
  comment: DBSQL warehouse right-sizing signals and recommendations, one row per warehouse configuration per day. Use this metric view to decide warehouse size, min and max clusters, serverless vs. Classic/Pro, and auto-stop. Signals are normalized per active day so that they do not depend on the length of the date range.

  source: '" || schema_path || ".fct_warehouse_daily'

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
    - name: usage_date
      expr: calendar.calendar_date
      display_name: Date
      comment: Calendar date (UTC) of the warehouse activity.
      synonyms:
        - date
        - day
    - name: calendar_month
      expr: calendar.calendar_month
      display_name: Calendar Month
      comment: Calendar month name (January, February, ...).
      synonyms:
        - month
    - name: calendar_year
      expr: calendar.calendar_year
      display_name: Calendar Year
      comment: Calendar year.
      synonyms:
        - year
    - name: is_week_day
      expr: calendar.is_week_day
      display_name: Is Weekday
      comment: Flag for weekdays (Y) vs. weekends (N).
      synonyms:
        - weekday
    - name: workspace_name
      expr: workspace.workspace_name
      display_name: Workspace
      comment: Human-readable name of the workspace where the warehouse is deployed. Null when the workspace has been cancelled.
      synonyms:
        - workspace
    - name: warehouse_id
      expr: source.warehouse_id
      display_name: Warehouse ID
      comment: ID of the SQL warehouse.
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
      comment: The type of SQL warehouse for the configuration in effect. Possible values are CLASSIC, PRO, and SERVERLESS.
      synonyms:
        - warehouse tier
        - serverless
    - name: warehouse_size
      expr: compute.warehouse_size
      display_name: Warehouse Size
      comment: T-shirt size for the configuration in effect. Possible values are 2X_SMALL through 5X_LARGE.
      synonyms:
        - cluster size
        - t-shirt size
    - name: min_clusters
      expr: compute.min_clusters
      display_name: Min Clusters
      comment: Minimum number of clusters for the configuration in effect.
    - name: max_clusters
      expr: compute.max_clusters
      display_name: Max Clusters
      comment: Maximum number of clusters for the configuration in effect.
    - name: auto_stop_minutes
      expr: compute.auto_stop_minutes
      display_name: Auto-Stop Minutes
      comment: Minutes of inactivity before the warehouse auto-stops, for the configuration in effect.
    - name: is_current_config
      expr: compute.is_current
      display_name: Is Current Config
      comment: True for days that ran under the current warehouse configuration. Filter to true to judge the current configuration on evidence gathered under it.
      synonyms:
        - current configuration

  measures:
    # Demand
    - name: query_count
      expr: SUM(source.query_count)
      display_name: Queries
      comment: Number of statements received.
      synonyms:
        - query volume
    - name: active_days
      expr: COUNT(DISTINCT CASE WHEN source.query_count > 0 THEN source.calendar_key END)
      display_name: Active Days
      comment: Days with at least one statement. Per-day measures divide by this.
    - name: queries_per_day
      expr: MEASURE(query_count) / NULLIF(MEASURE(active_days), 0)
      display_name: Queries per Day
      comment: Average statements received per active day.
    - name: peak_queries_per_minute
      expr: MAX(source.peak_1m_queries)
      display_name: Peak Queries per Minute
      comment: Most statements received in any single minute.
      synonyms:
        - peak qpm
        - peak concurrency
    - name: peak_5m_queries_per_minute
      expr: MAX(source.peak_5m_queries) / 5.0
      display_name: Peak Queries per Minute (5-min)
      comment: Highest queries-per-minute rate sustained over a 5-minute bucket. Steadier than the 1-minute peak.
      synonyms:
        - sustained peak qpm

    # Capacity queueing
    - name: queued_query_pct
      expr: SUM(source.queued_query_count) * 1.0 / NULLIF(SUM(source.query_count), 0)
      display_name: Queued Query Rate
      comment: Share of statements that waited for available capacity.
    - name: queue_minutes
      expr: SUM(source.queue_duration_ms) / 60000.0
      display_name: Queue Minutes
      comment: Total time statements waited for available capacity, in minutes.
    - name: queue_minutes_per_day
      expr: MEASURE(queue_minutes) / NULLIF(MEASURE(active_days), 0)
      display_name: Queue Minutes per Day
      comment: Capacity queue minutes per active day.
      synonyms:
        - queueing
    - name: worst_day_p95_queue_seconds
      expr: MAX(source.p95_queue_duration_ms) / 1000.0
      display_name: Worst-Day p95 Queue Seconds
      comment: The highest daily 95th percentile of capacity queue time, in seconds. Shows how bad queueing gets on the peak day.

    # Cold starts
    - name: cold_start_minutes_per_day
      expr: SUM(source.cold_start_duration_ms) / 60000.0 / NULLIF(MEASURE(active_days), 0)
      display_name: Cold Start Minutes per Day
      comment: Minutes per active day that statements waited for compute to be provisioned.
      synonyms:
        - startup wait

    # Spill
    - name: spill_gib_per_day
      expr: SUM(source.spilled_bytes) / POWER(1024, 3) / NULLIF(MEASURE(active_days), 0)
      display_name: Spill GiB per Day
      comment: GiB spilled to local disk per active day. Spill means the cluster size is too small for the queries.
      synonyms:
        - disk spill
    - name: spill_query_pct
      expr: SUM(source.spill_query_count) * 1.0 / NULLIF(SUM(source.query_count), 0)
      display_name: Spilling Query Rate
      comment: Share of statements that spilled to local disk.

    # Scaling
    - name: running_hours
      expr: SUM(source.running_minutes) / 60.0
      display_name: Running Hours
      comment: Hours the warehouse had at least one cluster running.
    - name: avg_running_clusters
      expr: SUM(source.cluster_minutes) / NULLIF(SUM(source.running_minutes), 0)
      display_name: Avg Running Clusters
      comment: Average number of clusters while the warehouse was running.
    - name: peak_cluster_count
      expr: MAX(source.peak_cluster_count)
      display_name: Peak Clusters
      comment: Most clusters running at once.
    - name: hours_at_max_clusters
      expr: SUM(source.minutes_at_max_clusters) / 60.0
      display_name: Hours at Max Clusters
      comment: Hours the warehouse ran at its configured max clusters and could not scale out further.
    - name: at_max_clusters_pct
      expr: SUM(source.minutes_at_max_clusters) / NULLIF(SUM(source.running_minutes), 0)
      display_name: Time at Max Clusters
      comment: Share of running time spent at max clusters. Always 100% for single-cluster warehouses.

    # Cost
    - name: dbus
      expr: SUM(source.dbus)
      display_name: DBUs
      comment: DBUs consumed.
    - name: list_cost_usd
      expr: SUM(source.list_cost_usd)
      display_name: List Cost (USD)
      comment: List cost in USD. This is list price, not negotiated price.
      synonyms:
        - cost
        - spend
    - name: list_cost_usd_per_day
      expr: MEASURE(list_cost_usd) / NULLIF(COUNT(DISTINCT source.calendar_key), 0)
      display_name: List Cost per Day (USD)
      comment: List cost in USD per day with any warehouse activity.
    - name: list_cost_usd_per_1k_queries
      expr: MEASURE(list_cost_usd) * 1000 / NULLIF(MEASURE(query_count), 0)
      display_name: List Cost per 1K Queries (USD)
      comment: List cost in USD per thousand statements.

    # Configuration: the latest configuration in the filtered range
    - name: config_type
      expr: MAX_BY(compute.warehouse_type, compute.effective_start)
      display_name: Type
      comment: Warehouse type of the latest configuration in the filtered range.
    - name: config_size
      expr: MAX_BY(compute.warehouse_size, compute.effective_start)
      display_name: Size
      comment: Warehouse size of the latest configuration in the filtered range.
    - name: config_min_clusters
      expr: MAX_BY(compute.min_clusters, compute.effective_start)
      display_name: Min Clusters
      comment: Min clusters of the latest configuration in the filtered range.
    - name: config_max_clusters
      expr: MAX_BY(compute.max_clusters, compute.effective_start)
      display_name: Max Clusters
      comment: Max clusters of the latest configuration in the filtered range.
    - name: config_auto_stop_minutes
      expr: MAX_BY(compute.auto_stop_minutes, compute.effective_start)
      display_name: Auto-Stop Minutes
      comment: Auto-stop minutes of the latest configuration in the filtered range.

    # Sizing signals, compared with the sizing_* thresholds
    - name: has_enough_activity
      expr: MEASURE(active_days) >= " || cast(:sizing_min_active_days as int) || "
      display_name: Has Enough Activity
      comment: True when the warehouse has enough active days for a recommendation.
    - name: has_cold_start_pressure
      expr: MEASURE(config_type) IN ('CLASSIC', 'PRO') AND MEASURE(cold_start_minutes_per_day) >= " || cast(:sizing_cold_start_minutes_per_day as double) || "
      display_name: Has Cold Start Pressure
      comment: True when a Classic or Pro warehouse makes statements wait for compute to start.
    - name: has_spill_pressure
      expr: MEASURE(spill_gib_per_day) >= " || cast(:sizing_spill_gib_per_day as double) || "
      display_name: Has Spill Pressure
      comment: True when spill per day is at or above the threshold. Points to a cluster size that is too small.
    - name: has_queue_pressure
      expr: MEASURE(queue_minutes_per_day) >= " || cast(:sizing_queue_minutes_per_day as double) || " OR MEASURE(worst_day_p95_queue_seconds) >= " || cast(:sizing_p95_queue_seconds as double) || "
      display_name: Has Queue Pressure
      comment: True when capacity queue minutes per day or worst-day p95 queue seconds is at or above its threshold. Points to too few clusters.
    - name: has_scale_out_lag
      expr: MEASURE(at_max_clusters_pct) < " || cast(:sizing_at_max_clusters_pct as double) || " AND MEASURE(config_min_clusters) < MEASURE(config_max_clusters)
      display_name: Has Scale-Out Lag
      comment: True when the warehouse spends less than the threshold share of running time at max clusters and can still scale out. Queueing then points to scale-out lag, not too few max clusters. Null without warehouse event data.
    - name: is_low_pressure
      expr: >-
        MEASURE(spill_gib_per_day) <= " || cast(:sizing_low_spill_gib_per_day as double) || "
        AND MEASURE(queue_minutes_per_day) <= " || cast(:sizing_low_queue_minutes_per_day as double) || "
        AND COALESCE(MEASURE(worst_day_p95_queue_seconds), 0) < " || cast(:sizing_p95_queue_seconds as double) || "
      display_name: Is Low Pressure
      comment: True when spill and queueing are both negligible, so a smaller size is likely enough.

    # Recommendation
    - name: next_size_up
      expr: >-
        COALESCE(ELEMENT_AT(
          ARRAY('2X_SMALL', 'X_SMALL', 'SMALL', 'MEDIUM', 'LARGE', 'X_LARGE', '2X_LARGE', '3X_LARGE', '4X_LARGE', '5X_LARGE'),
          LEAST(CAST(ARRAY_POSITION(
            ARRAY('2X_SMALL', 'X_SMALL', 'SMALL', 'MEDIUM', 'LARGE', 'X_LARGE', '2X_LARGE', '3X_LARGE', '4X_LARGE', '5X_LARGE'),
            MEASURE(config_size)) AS INT) + 1, 10)), MEASURE(config_size))
      display_name: Next Size Up
      comment: One t-shirt size larger than the current size, capped at 5X_LARGE.
    - name: next_size_down
      expr: >-
        COALESCE(ELEMENT_AT(
          ARRAY('2X_SMALL', 'X_SMALL', 'SMALL', 'MEDIUM', 'LARGE', 'X_LARGE', '2X_LARGE', '3X_LARGE', '4X_LARGE', '5X_LARGE'),
          GREATEST(CAST(ARRAY_POSITION(
            ARRAY('2X_SMALL', 'X_SMALL', 'SMALL', 'MEDIUM', 'LARGE', 'X_LARGE', '2X_LARGE', '3X_LARGE', '4X_LARGE', '5X_LARGE'),
            MEASURE(config_size)) AS INT) - 1, 1)), MEASURE(config_size))
      display_name: Next Size Down
      comment: One t-shirt size smaller than the current size, floored at 2X_SMALL.
    - name: recommendation
      expr: >-
        CASE
          WHEN NOT MEASURE(has_enough_activity) THEN 'Too little activity'
          WHEN MEASURE(has_cold_start_pressure) THEN 'Switch to serverless'
          WHEN MEASURE(has_spill_pressure) AND MEASURE(has_queue_pressure) AND MEASURE(config_size) <> '5X_LARGE' THEN 'Size up and add a max cluster'
          WHEN MEASURE(has_spill_pressure) AND MEASURE(config_size) <> '5X_LARGE' THEN 'Size up'
          WHEN MEASURE(has_queue_pressure) AND MEASURE(has_scale_out_lag) THEN 'Add a min cluster'
          WHEN MEASURE(has_queue_pressure) THEN 'Add a max cluster'
          WHEN MEASURE(is_low_pressure) AND MEASURE(config_size) <> '2X_SMALL' THEN 'Size down'
          WHEN MEASURE(config_type) = 'SERVERLESS' AND MEASURE(config_auto_stop_minutes) > " || cast(:sizing_serverless_auto_stop_minutes as int) || " THEN 'Lower auto-stop'
          ELSE 'No change'
        END
      display_name: Recommendation
      comment: 'The single highest-priority sizing action for the warehouse: Too little activity, Switch to serverless, Size up and add a max cluster, Size up, Add a max cluster, Add a min cluster, Size down, Lower auto-stop, or No change.'
      synonyms:
        - sizing recommendation
        - right-size
        - action
    - name: recommended_type
      expr: IF(MEASURE(recommendation) = 'Switch to serverless', 'SERVERLESS', MEASURE(config_type))
      display_name: Recommended Type
      comment: Warehouse type after applying the recommendation.
    - name: recommended_size
      expr: >-
        CASE MEASURE(recommendation)
          WHEN 'Size up and add a max cluster' THEN MEASURE(next_size_up)
          WHEN 'Size up' THEN MEASURE(next_size_up)
          WHEN 'Size down' THEN MEASURE(next_size_down)
          ELSE MEASURE(config_size)
        END
      display_name: Recommended Size
      comment: Warehouse size after applying the recommendation.
    - name: recommended_min_clusters
      expr: MEASURE(config_min_clusters) + IF(MEASURE(recommendation) = 'Add a min cluster', 1, 0)
      display_name: Recommended Min Clusters
      comment: Min clusters after applying the recommendation.
    - name: recommended_max_clusters
      expr: MEASURE(config_max_clusters) + IF(MEASURE(recommendation) IN ('Size up and add a max cluster', 'Add a max cluster'), 1, 0)
      display_name: Recommended Max Clusters
      comment: Max clusters after applying the recommendation.
    - name: recommended_auto_stop_minutes
      expr: IF(MEASURE(recommendation) = 'Lower auto-stop', " || cast(:sizing_serverless_auto_stop_minutes as int) || ", MEASURE(config_auto_stop_minutes))
      display_name: Recommended Auto-Stop Minutes
      comment: Auto-stop minutes after applying the recommendation.
    - name: recommendation_reason
      expr: >-
        COALESCE(CASE MEASURE(recommendation)
          WHEN 'Too little activity' THEN 'Active on ' || MEASURE(active_days) || ' days, fewer than the ' || " || cast(:sizing_min_active_days as int) || " || ' required'
          WHEN 'Switch to serverless' THEN 'Cold starts of ' || FORMAT_NUMBER(MEASURE(cold_start_minutes_per_day), 1) || ' min/day on ' || MEASURE(config_type) || '. Serverless starts in seconds. Alternatively, raise auto-stop.'
          WHEN 'Size up and add a max cluster' THEN 'Spill of ' || FORMAT_NUMBER(MEASURE(spill_gib_per_day), 1) || ' GiB/day and capacity queue of ' || FORMAT_NUMBER(MEASURE(queue_minutes_per_day), 1) || ' min/day (worst-day p95 ' || FORMAT_NUMBER(MEASURE(worst_day_p95_queue_seconds), 1) || ' s)'
          WHEN 'Size up' THEN 'Spill of ' || FORMAT_NUMBER(MEASURE(spill_gib_per_day), 1) || ' GiB/day, with ' || FORMAT_NUMBER(MEASURE(spill_query_pct) * 100, 1) || '% of queries spilling'
          WHEN 'Add a max cluster' THEN 'Capacity queue of ' || FORMAT_NUMBER(MEASURE(queue_minutes_per_day), 1) || ' min/day (worst-day p95 ' || FORMAT_NUMBER(MEASURE(worst_day_p95_queue_seconds), 1) || ' s), time at max clusters ' || COALESCE(FORMAT_NUMBER(MEASURE(at_max_clusters_pct) * 100, 0) || '%', 'unknown (no warehouse events)')
          WHEN 'Add a min cluster' THEN 'Capacity queue of ' || FORMAT_NUMBER(MEASURE(queue_minutes_per_day), 1) || ' min/day (worst-day p95 ' || FORMAT_NUMBER(MEASURE(worst_day_p95_queue_seconds), 1) || ' s) while at max clusters only ' || FORMAT_NUMBER(MEASURE(at_max_clusters_pct) * 100, 0) || '% of running time. Queueing below max points to scale-out lag at peaks.'
          WHEN 'Size down' THEN 'Spill of ' || FORMAT_NUMBER(MEASURE(spill_gib_per_day), 2) || ' GiB/day and capacity queue of ' || FORMAT_NUMBER(MEASURE(queue_minutes_per_day), 1) || ' min/day. Check latency after the change.'
          WHEN 'Lower auto-stop' THEN 'Serverless restarts in seconds, so idle minutes past ' || " || cast(:sizing_serverless_auto_stop_minutes as int) || " || ' cost more than they save'
          ELSE 'Signals are within thresholds'
        END, 'Some signals are missing for this warehouse')
      display_name: Recommendation Reason
      comment: The evidence behind the recommendation, with the numbers that triggered it.
      synonyms:
        - why
        - evidence
  $$";

execute immediate qry_str;
