-- Reference views that document the warehouse sizing rules for the dashboard and Genie Agents. They are built from
-- the same sizing_* job parameters as metv_warehouse_sizing, so they always show the thresholds in effect. Both are
-- small constant views, created the same way in view mode and table mode.

use catalog identifier(:catalog);
use schema identifier(:schema);

-- Threshold values formatted for display
declare or replace min_active_days string = cast(cast(:sizing_min_active_days as int) as string);
declare or replace cold_start_minutes string = format_number(cast(:sizing_cold_start_minutes_per_day as double), '#,##0.##');
declare or replace spill_gib string = format_number(cast(:sizing_spill_gib_per_day as double), '#,##0.##');
declare or replace queue_minutes string = format_number(cast(:sizing_queue_minutes_per_day as double), '#,##0.##');
declare or replace p95_queue_seconds string = format_number(cast(:sizing_p95_queue_seconds as double), '#,##0.##');
declare or replace at_max_pct string = format_number(cast(:sizing_at_max_clusters_pct as double) * 100, '#,##0.##') || '%';
declare or replace low_spill_gib string = format_number(cast(:sizing_low_spill_gib_per_day as double), '#,##0.##');
declare or replace low_queue_minutes string = format_number(cast(:sizing_low_queue_minutes_per_day as double), '#,##0.##');
declare or replace auto_stop_minutes string = cast(cast(:sizing_serverless_auto_stop_minutes as int) as string);
declare or replace at_max_share string = format_number(cast(:sizing_at_max_clusters_pct as double), '#,##0.##');
declare or replace min_size string = upper(:sizing_min_size);
declare or replace queueing string = 'queue >= ' || queue_minutes || ' min/day or worst-day p95 queue >= ' || p95_queue_seconds || ' s';

declare or replace qry_str string;

set var qry_str = "create or replace view sizing_rules (
    priority comment 'Order in which the rules are checked. The first matching rule wins.',
    recommendation comment 'Recommendation produced by the rule, as returned by metv_warehouse_sizing.recommendation.',
    rule_condition comment 'When the rule matches, with the thresholds in effect. Per-day values are per active day.',
    config_change comment 'Configuration change the rule recommends.'
  )
  comment 'Warehouse sizing rules used by metv_warehouse_sizing, in priority order, with the thresholds in effect.'
  as select * from values
    (1, 'Too little activity', 'Fewer than " || min_active_days || " active days in the range', 'None'),
    (2, 'Switch to serverless', 'Classic or Pro warehouse with cold starts >= " || cold_start_minutes || " min/day', 'Type to serverless, or raise auto-stop'),
    (3, 'Size up and add a max cluster', 'Spill >= " || spill_gib || " GiB/day, " || queueing || ", and size below 5X_LARGE', 'Size up one, max clusters +1'),
    (4, 'Size up', 'Spill >= " || spill_gib || " GiB/day, and size below 5X_LARGE', 'Size up one'),
    (5, 'Add a min cluster', 'Queueing (" || queueing || "), at max clusters less than " || at_max_pct || " of running time, and min clusters below max', 'Min clusters +1'),
    (6, 'Add a max cluster', 'Any other queueing, including warehouses without warehouse event data', 'Max clusters +1'),
    (7, 'Size down', 'Spill <= " || low_spill_gib || " GiB/day, queue <= " || low_queue_minutes || " min/day, worst-day p95 queue < " || p95_queue_seconds || " s, and size above " || min_size || "', 'Size down one'),
    (8, 'Lower auto-stop', 'Serverless warehouse with auto-stop above " || auto_stop_minutes || " min', 'Auto-stop to " || auto_stop_minutes || " min'),
    (9, 'No change', 'No rule above matches', 'None')
  as t(priority, recommendation, rule_condition, config_change)";

execute immediate qry_str;

set var qry_str = "create or replace view sizing_thresholds (
    threshold_name comment 'Bundle variable (and job parameter) that sets the threshold.',
    threshold_value comment 'Value in effect, as text.',
    unit comment 'Unit of the value.',
    used_by comment 'Rules that use the threshold.',
    description comment 'What the threshold controls.'
  )
  comment 'Warehouse sizing thresholds in effect for metv_warehouse_sizing. Change them with the sizing_* bundle variables and rerun the job.'
  as select * from values
    ('sizing_min_active_days', '" || min_active_days || "', 'days', 'Too little activity', 'Fewest active days for a recommendation'),
    ('sizing_cold_start_minutes_per_day', '" || cold_start_minutes || "', 'minutes per active day', 'Switch to serverless', 'Cold start minutes that call for serverless on Classic/Pro'),
    ('sizing_spill_gib_per_day', '" || spill_gib || "', 'GiB per active day', 'Size up and add a max cluster, Size up', 'Spill that calls for a larger size'),
    ('sizing_queue_minutes_per_day', '" || queue_minutes || "', 'minutes per active day', 'Size up and add a max cluster, Add a min cluster, Add a max cluster', 'Capacity queue minutes that count as queueing'),
    ('sizing_p95_queue_seconds', '" || p95_queue_seconds || "', 'seconds', 'Size up and add a max cluster, Add a min cluster, Add a max cluster, Size down', 'Worst-day p95 queue time that counts as queueing'),
    ('sizing_at_max_clusters_pct', '" || at_max_share || "', 'share of running time (0-1)', 'Add a min cluster', 'Time at max clusters below which queueing points to scale-out lag'),
    ('sizing_low_spill_gib_per_day', '" || low_spill_gib || "', 'GiB per active day', 'Size down', 'Spill at or below which a smaller size is likely enough'),
    ('sizing_low_queue_minutes_per_day', '" || low_queue_minutes || "', 'minutes per active day', 'Size down', 'Queue minutes at or below which a smaller size is likely enough'),
    ('sizing_min_size', '" || min_size || "', 'warehouse size', 'Size down', 'Smallest size that Size down recommends. Smaller warehouses are flagged as below the minimum. Medium or larger is recommended for important workloads.'),
    ('sizing_serverless_auto_stop_minutes', '" || auto_stop_minutes || "', 'minutes', 'Lower auto-stop', 'Target auto-stop for serverless warehouses set higher')
  as t(threshold_name, threshold_value, unit, used_by, description)";

execute immediate qry_str;
