use catalog identifier(:catalog);
use schema identifier(:schema);

-- Quoted catalog.schema for the YAML sources, so names that need quoting (such as a hyphen) still resolve
declare or replace schema_path string = '`' || replace(:catalog, '`', '``') || '`.`' || replace(:schema, '`', '``') || '`';
declare or replace qry_str string;

set var qry_str =
  "create or replace view metv_usage
  with metrics
  language yaml
  as $$
  version: 1.1
  comment: DBSQL warehouse usage metrics sourced from system.billing.usage and priced with system.billing.list_prices (list price, USD). Use this metric view to analyze DBU consumption and list cost by warehouse, SKU tier, workspace, identity, and custom tags.

  source: '" || schema_path || ".fct_usage'

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
      display_name: Usage Date
      comment: Date of the usage record. Use this field for faster aggregation by date.
      synonyms:
        - date
        - usage date
        - billing date
        - consumption date
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
      comment: Human-readable name of the workspace where the usage was incurred. Null when the workspace has been cancelled (no longer present in system.access.workspaces_latest).
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
      comment: ID of the workspace where the usage was incurred. Retained even when the workspace has been cancelled.
      synonyms:
        - workspace identifier
    - name: account_id
      expr: source.account_id
      display_name: Account ID
      comment: ID of the Databricks account that generated the usage record.
      synonyms:
        - account
        - account identifier
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
      comment: T-shirt size of the SQL warehouse at the time of the usage.
      synonyms:
        - cluster size
        - t-shirt size
    - name: sql_tier
      expr: source.sql_tier
      display_name: SQL Tier
      comment: SQL warehouse pricing tier. Possible values are CLASSIC, PRO, or null.
      synonyms:
        - pricing tier
        - sql pricing tier
    - name: is_serverless
      expr: source.is_serverless
      display_name: Serverless
      comment: Whether the warehouse runs on serverless compute.
      synonyms:
        - serverless
        - serverless flag
    - name: is_photon
      expr: source.is_photon
      display_name: Photon
      comment: Whether Photon was used to process the usage.
      synonyms:
        - photon
        - photon engine
    - name: owned_by
      expr: source.owned_by
      display_name: Owned By
      comment: User or service principal that owns the SQL warehouse.
      synonyms:
        - warehouse owner
        - owner
    - name: run_as
      expr: source.run_as
      display_name: Run As
      comment: Identity that executed the workload.
      synonyms:
        - executed by
        - identity
    - name: usage_unit
      expr: source.usage_unit
      display_name: Unit
      comment: Unit this usage is measured in. Possible values include DBUs.
      synonyms:
        - unit of measure
        - billing unit
        - DBU
    - name: usage_type
      expr: source.usage_type
      display_name: Usage Type
      comment: The type of usage attributed to the product or workload for billing purposes. Possible values are COMPUTE_TIME, STORAGE_SPACE, NETWORK_BYTES, API_CALLS, TOKEN, or GPU_TIME.
      synonyms:
        - consumption type
        - billing type
        - workload type
    - name: billing_origin_product
      expr: source.billing_origin_product
      display_name: Product
      comment: The product that originated the usage. Always SQL in this metric view.
      synonyms:
        - product
        - origin product
        - billing product
    - name: sku_name
      expr: source.sku_name
      display_name: SKU
      comment: Name of the SKU.
      synonyms:
        - SKU
        - billing SKU
    - name: record_type
      expr: source.record_type
      display_name: Record Type
      comment: Whether the record is original, a retraction, or a restatement. Possible values are ORIGINAL, RETRACTION, and RESTATEMENT.
      synonyms:
        - correction type
        - usage record type
    - name: cloud
      expr: source.cloud
      display_name: Cloud
      comment: Cloud provider. Possible values are AWS, AZURE, and GCP.
      synonyms:
        - cloud provider
        - csp
    - name: currency_code
      expr: source.currency_code
      display_name: Currency
      comment: Currency code of the list price (typically USD).
      synonyms:
        - currency

  measures:
    - name: dbu_sum
      expr: SUM(source.usage_quantity)
      display_name: Total DBUs
      comment: Sum of usage_quantity. For DBSQL usage this is total DBUs consumed.
      synonyms:
        - total dbus
        - total usage
        - dbu usage
        - usage quantity
    - name: list_cost_usd
      expr: SUM(source.list_cost_usd)
      display_name: List Cost (USD)
      comment: Sum of list cost in USD (usage_quantity * list price). Uses system.billing.list_prices.pricing.default, so it does NOT reflect negotiated or promotional pricing.
      synonyms:
        - list cost
        - cost
        - spend
        - dollars
        - usd cost
    - name: avg_list_price_usd
      expr: SUM(source.list_cost_usd) / NULLIF(SUM(source.usage_quantity), 0)
      display_name: Avg List Price (USD/unit)
      comment: Effective average list price per usage unit (e.g., USD per DBU), weighted by usage_quantity.
      synonyms:
        - blended rate
        - effective price
        - average rate
    - name: usage_records
      expr: COUNT(source.record_id)
      display_name: Usage Records
      comment: Count of usage records.
      synonyms:
        - record count
        - billing record count
    - name: distinct_warehouses
      expr: COUNT(DISTINCT source.warehouse_id)
      display_name: Distinct Warehouses
      comment: Number of distinct SQL warehouses observed in the filtered window.
      synonyms:
        - warehouse count
        - unique warehouses
    - name: distinct_workspaces
      expr: COUNT(DISTINCT source.workspace_id)
      display_name: Distinct Workspaces
      comment: Number of distinct workspaces observed in the filtered window.
      synonyms:
        - workspace count
        - unique workspaces
  $$";

execute immediate qry_str;
