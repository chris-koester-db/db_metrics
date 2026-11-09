# DB Metrics - Metric Views on Databricks System Tables

`db_metrics` is a deployable solution that delivers governed, agent-ready metrics on top of Databricks [System Tables](https://docs.databricks.com/aws/en/admin/system-tables/) using [**Declarative Automation Bundles**](https://docs.databricks.com/aws/en/dev-tools/bundles/) and [**Unity Catalog Metric Views**](https://docs.databricks.com/aws/en/metric-views/). The bundle ships a dimensional model, metric views, and an AI/BI dashboard as a single deployable unit. Current scope covers **DBSQL warehouses**: query history, usage and cost, scaling events, and **right-sizing recommendations** for size, min/max clusters, serverless, and auto-stop.

This project is derived from the [metric-views example](https://github.com/databricks-solutions/databricks-dab-examples/tree/main/knowledge-base/metric-views) in the `databricks-solutions/databricks-dab-examples` repository, which serves as a basic example of how to deploy metric views with Declarative Automation Bundles.

## What's included

| Object | Type | Description |
|---|---|---|
| `dim_calendar`, `dim_compute`, `dim_workspace` | View or table | Calendar, warehouse configuration history (SCD Type 2), and workspaces |
| `fct_query_history`, `fct_usage`, `fct_warehouse_events` | View or table | Warehouse queries, billing usage at list price, and scaling events, for the last 6 months |
| `fct_warehouse_daily` | View or table | Daily sizing signals per warehouse configuration |
| `metv_query_history`, `metv_usage`, `metv_warehouse_events` | Metric view | Query performance, cost, and scaling metrics |
| `metv_warehouse_sizing` | Metric view | Sizing signals and one recommendation per warehouse |
| `sizing_rules`, `sizing_thresholds` | View | The sizing rules and thresholds in effect, for the dashboard and Genie Agents |
| `[dev yourname] db_metrics` | Job | Creates or refreshes all of the above |
| `DB Metrics` | Dashboard | Pages for query performance, warehouse events and scaling, right-sizing, and how recommendations work |

## View mode and table mode

The `materialize` bundle variable controls how the `dim_*` and `fct_*` objects are created. The object names are the same
in both modes, so the metric views and the dashboard work unchanged.

| | View mode (`materialize: "false"`, default) | Table mode (`materialize: "true"`) |
|---|---|---|
| Objects | Views over the system tables | Tables refreshed by the daily job |
| Freshness | Always current | As of the last job run |
| Job | Run once after each deploy | Daily (set `schedule_pause_status: UNPAUSED`) |
| History | Last 6 months (system tables keep about 12) | Last 6 months, replaced on each run |
| Dashboard speed | About 20-30 s per sizing query, in tests with over 100M rows in `system.query.history` on 2X-Small and Small warehouses | About 3 s for the same queries on a 2X-Small |

Start with view mode: it has the fewest moving parts. Switch to table mode when dashboard response time matters. Switching
is safe either way: each run drops an object that exists as the other type before creating it.

In table mode, each run replaces a table's data in one step, so readers never see an empty table, and a failed run
leaves the previous data in place. A table is recreated only when its columns change. Changes to column comments,
constraints, or clustering apply at that point; to apply them sooner, run once with `materialize=false`, then switch
back.

## Warehouse right-sizing

`fct_warehouse_daily` summarizes each warehouse configuration per day: queries, peak 1- and 5-minute queries per minute,
capacity queueing, cold starts, spill, time at max clusters (from `system.compute.warehouse_events`), and list cost.
`metv_warehouse_sizing` normalizes these signals per active day and applies the sizing rules to whatever date range the
caller filters to. The rules follow Databricks field guidance for sizing SQL warehouses.

### Rules

Each warehouse gets one recommendation. The rules are checked in this order, and the first match wins:

| # | Recommendation | When | Change |
|---|---|---|---|
| 1 | Too little activity | Fewer than `sizing_min_active_days` active days | None |
| 2 | Switch to serverless | Classic or Pro, with cold starts of at least `sizing_cold_start_minutes_per_day` | Type to serverless, or raise auto-stop |
| 3 | Size up and add a max cluster | Spill of at least `sizing_spill_gib_per_day`, queueing, and size below 5X_LARGE | Size up one, max clusters +1 |
| 4 | Size up | Spill of at least `sizing_spill_gib_per_day`, and size below 5X_LARGE | Size up one |
| 5 | Add a min cluster | Queueing, at max clusters less than `sizing_at_max_clusters_pct` of running time, and min clusters below max | Min clusters +1 |
| 6 | Add a max cluster | Any other queueing, including warehouses without warehouse event data | Max clusters +1 |
| 7 | Size down | Spill of at most `sizing_low_spill_gib_per_day`, queue of at most `sizing_low_queue_minutes_per_day`, worst-day p95 queue below `sizing_p95_queue_seconds`, and size above `sizing_min_size` | Size down one |
| 8 | Lower auto-stop | Serverless, with auto-stop above `sizing_serverless_auto_stop_minutes` | Auto-stop to `sizing_serverless_auto_stop_minutes` |
| 9 | No change | No rule above matches | None |

**Queueing** means queue minutes per day of at least `sizing_queue_minutes_per_day`, or a worst-day p95 queue of at least
`sizing_p95_queue_seconds`. Rule 5 separates scale-out lag (queueing while clusters are still available) from too few
clusters (queueing at max). Raising min clusters keeps capacity warm for peaks, such as when many BI users open
dashboards at once.

**Minimum size.** Databricks generally recommends Medium or larger for important workloads, because smaller sizes run on
smaller instances, with less local cache, memory, and network bandwidth. Rule 7 never recommends a size below
`sizing_min_size` (Medium by default). Smaller warehouses are flagged with `is_below_min_size`, shown as **Below Min
Size** on the dashboard, but they're only told to size up when spill shows they need it. That way, small dev and test
warehouses don't get size-up advice without evidence. Lower `sizing_min_size` if your small warehouses don't run
important workloads.

### Signals

Per-day signals are divided by **active days**: days with at least one query under the configuration.

- **Queue minutes per day:** `waiting_at_capacity_duration_ms` summed across statements. Concurrent waits add up: 60
  statements that each wait 1 minute count as 60 minutes, which is what users experience.
- **Worst-day p95 queue:** the highest daily 95th percentile of `waiting_at_capacity_duration_ms`, in seconds. It
  normalizes by query count and shows how bad queueing gets on the peak day.
- **Cold start minutes per day:** `waiting_for_compute_duration_ms` summed across statements.
- **Spill GiB per day:** `spilled_local_bytes`. Spill means the cluster size is too small for the queries.
- **Time at max clusters:** share of running time at the configured max clusters. Each warehouse event starts an
  interval that lasts until the next event, or until the warehouse was deleted, with that event's cluster count.
  Single-cluster warehouses are always at max.
- **Cost:** `system.billing.usage` priced with `system.billing.list_prices`. These are list prices, not negotiated prices.

### Thresholds

Thresholds are bundle variables, passed to the job as parameters. Override them per target in `databricks.yml`, or for
one run with `databricks bundle run db_metrics_job --params sizing_spill_gib_per_day=2`. The defaults are starting
points; calibrate them against your own workload.

| Variable | Default | Unit |
|---|---|---|
| `sizing_min_active_days` | 5 | days |
| `sizing_cold_start_minutes_per_day` | 5 | minutes per active day |
| `sizing_spill_gib_per_day` | 1 | GiB per active day |
| `sizing_queue_minutes_per_day` | 10 | minutes per active day |
| `sizing_p95_queue_seconds` | 10 | seconds |
| `sizing_at_max_clusters_pct` | 0.1 | share of running time (0-1) |
| `sizing_low_spill_gib_per_day` | 0.1 | GiB per active day |
| `sizing_low_queue_minutes_per_day` | 1 | minutes per active day |
| `sizing_serverless_auto_stop_minutes` | 10 | minutes |
| `sizing_min_size` | MEDIUM | warehouse size |

The job also writes the rules and thresholds in effect to the `sizing_rules` and `sizing_thresholds` views, so the
dashboard and Genie Agents always show what the metric view uses.

### Limits

- Recommendations use the latest configuration in the range. Filter to `is_current_config = true` to judge the current
  configuration on evidence gathered under it, as the dashboard does.
- Recommendations move one step at a time: one t-shirt size or one cluster. Change one setting, then compare a week or
  more of data under the new configuration.
- The rules see warehouse-level signals only. They don't tell inefficient queries apart from an undersized warehouse.
- System tables are account-level, so the recommendations cover warehouses in other workspaces too, not just the one
  the bundle is deployed to. Filter on `workspace_name` to narrow them.
- Usage, queries, and events join to `dim_compute`, so rows for warehouses missing from `system.compute.warehouses` are
  left out. Sizing is unaffected, because those warehouses have no query or event data either. But cost totals in
  `metv_usage` and `metv_warehouse_sizing` can be well below the account's SQL spend in `system.billing.usage`: in one
  test account, 90% of SQL list cost was for warehouses in neither `system.compute.warehouses` nor
  `system.query.history`.
- Dates are UTC, whatever the session time zone. The dashboard's lookback window ends at the session's current date,
  which is also UTC unless the warehouse sets another time zone.

### Dashboard

The **Right-Size Warehouses** page shows the recommendation, reason, current and recommended configuration, and the
evidence for each warehouse, plus daily trends. Its **Lookback Days** filter (default 30) sets the window, in full UTC
days. The **How Recommendations Work** page shows the rules and thresholds in effect, and what each signal means.

## Reusing the metrics: dashboards, SQL, and Genie Agents

The bundle is a starting point. All of the logic, including the sizing rules, lives in Unity Catalog metric views,
where each metric is defined once with a description and synonyms. Any dashboard, SQL query, or Genie Agent that uses
them gets the same numbers, so you can build your own views of the data without copying logic.

Query a metric view with `MEASURE()`:

```sql
SELECT
  warehouse_id,
  warehouse_name,
  MEASURE(recommendation) AS recommendation,
  MEASURE(recommendation_reason) AS reason
FROM your_catalog.your_schema.metv_warehouse_sizing
WHERE usage_date >= date_sub(current_date(), 30)
  AND usage_date < current_date()
  AND is_current_config
GROUP BY ALL
```

Group by `warehouse_id` as well as `warehouse_name`: names aren't unique across workspaces.

### Genie Agents

To explore the data in natural language, create a Genie Agent with these data sources:

- `metv_warehouse_sizing`: sizing signals and recommendations
- `metv_query_history`: query volume, latency, queueing, and errors
- `metv_usage` and `metv_warehouse_events`: cost and scaling, if needed
- `sizing_rules` and `sizing_thresholds`: the rules and thresholds in effect

Suggested instructions for the agent:

- For sizing recommendations, filter to `is_current_config = true`, use full days that exclude today, and group by
  `warehouse_id` and `warehouse_name`.
- To explain a recommendation, use `recommendation_reason` and the rule in `sizing_rules`.

Example questions:

- Which warehouses are recommended to add a cluster over the last 30 days?
- Why is the Power BI warehouse recommended to size down?
- What was the peak queries per minute on each warehouse during business hours last week?
- Which warehouses spend the most time at max clusters?
- What are the current sizing thresholds?

The rules are measures, so the agent applies them to whatever time window a question asks about.

## Prerequisites

### 1. System tables and permissions
The deploying user and the job's run-as identity need `USE` and `SELECT` on the following. So do dashboard viewers, unless
the dashboard is published with embedded credentials.
- `system.query.history`
- `system.compute.warehouses` and `system.compute.warehouse_events`
- `system.billing.usage` and `system.billing.list_prices`
- `system.access.workspaces_latest`

They also need `USE CATALOG`, `USE SCHEMA`, and `CREATE TABLE` on the target schema. `CREATE TABLE` covers views and
metric views too. The schema must already exist. An account admin may need to enable the `query`, `compute`,
`billing`, and `access` system schemas.

### 2. Install the Databricks CLI
Install the [Databricks CLI](https://docs.databricks.com/dev-tools/cli/install.html). The bundle requires version 0.281.0
or later.

### 3. Authenticate to your Databricks workspace
OAuth is recommended:

```bash
databricks auth login --host https://your-workspace.cloud.databricks.com --profile my-workspace
```

This opens your browser to sign in and saves a profile in `~/.databrickscfg`. Check it with:

```bash
databricks auth profiles
```

Alternatively, use a personal access token: generate one under **Settings** → **Developer** → **Access tokens**, then
run `databricks configure --token --profile my-workspace` and enter the host and token when prompted.

### 4. Configure databricks.yml
The `dev` and `prod` targets in `databricks.yml` have placeholder values. Replace them with your workspace URL,
catalog, schema, and SQL warehouse. Or keep your settings out of git in a `*.local.yml` file: the bundle includes it,
and `.gitignore` excludes it. A local file only needs the values it changes:

```yaml
# targets.local.yml
targets:
  dev:
    workspace:
      host: https://your-workspace.cloud.databricks.com
      profile: my-workspace
    variables:
      warehouse_id:
        lookup:
          warehouse: "Your SQL Warehouse"
      catalog: your_catalog
      schema: your_schema
```

The variables:

- **workspace.host** and **workspace.profile**: Your workspace URL and CLI profile
- **catalog**: The catalog where the objects are created
- **schema**: The schema within the catalog
- **warehouse_id**: The SQL warehouse that runs the job and the dashboard, by ID or looked up by name as above
- **materialize**: `"false"` (default) for views, `"true"` for tables. See [View mode and table mode](#view-mode-and-table-mode).
- **schedule_pause_status**: `PAUSED` (default) or `UNPAUSED`. Unpause the daily schedule only in table mode.
- **sizing_\***: Warehouse sizing thresholds. See [Thresholds](#thresholds).

For example, to run `prod` in table mode with a daily refresh and a higher queueing threshold:

```yaml
targets:
  prod:
    variables:
      materialize: "true"
      schedule_pause_status: UNPAUSED
      sizing_queue_minutes_per_day: 15
```

## Deployment

### Deploy
```bash
$ databricks bundle deploy --target prod
```
Without `--target`, the bundle deploys the default `dev` target. Development mode prefixes resource names with
`[dev yourname]` and pauses job schedules.

The deploy creates the job and the dashboard. It doesn't run any SQL, so run the job next. You can find the job under
**Jobs & Pipelines** in your workspace.

### Run the Job
Run the job once after each deploy. In view mode, that run creates the views and metric views; nothing needs to run
after that. In table mode, the daily schedule then keeps the tables current.
```bash
$ databricks bundle run db_metrics_job --target prod
```
To try table mode without changing the target, override the job parameter for one run:
```bash
$ databricks bundle run db_metrics_job --target prod --params materialize=true
```
The next run without the override switches the objects back to the target's mode.

## Project Structure

- `databricks.yml`: Bundle configuration, variables, and targets
- `*.local.yml`: Optional, git-ignored target overrides
- `resources/`: Bundle resource definitions for the job and the dashboard
- `src/`: SQL files for the job tasks, and the dashboard definition (`db_metrics.lvdash.json`)
  - `dim_*.sql`, `fct_*.sql`: The dimensional model
  - `metv_*.sql`: Metric views
  - `sizing_reference.sql`: The `sizing_rules` and `sizing_thresholds` views

Each `dim_*`/`fct_*` file declares its columns once, as an array of name/type/comment, plus one select statement. The
statements at the end of each file build a view or a table from those definitions. They use `execute immediate` rather
than `IF` blocks, because SQL file tasks split files on semicolons and don't support `BEGIN ... END`.

## Documentation

- [Declarative Automation Bundles](https://docs.databricks.com/dev-tools/bundles/index.html)
- [Unity Catalog metric views](https://docs.databricks.com/aws/en/metric-views/)
- [System tables](https://docs.databricks.com/aws/en/admin/system-tables/)
- [Databricks extension for Visual Studio Code](https://docs.databricks.com/dev-tools/vscode-ext.html)
