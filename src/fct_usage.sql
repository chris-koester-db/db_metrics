-- fct_usage is a view over system.billing.usage and system.billing.list_prices by default, or a table rebuilt on
-- each run when the materialize parameter is 'true'. Both modes share the column definitions and select statement
-- below. See dim_compute.sql.

use catalog identifier(:catalog);
use schema identifier(:schema);

declare or replace materialize boolean = (lower(:materialize) = 'true');
declare or replace object_name string = 'fct_usage';
declare or replace object_comment string = 'DBSQL warehouse billing usage records sourced from system.billing.usage, restricted to billing_origin_product = SQL and the last 6 months. Joined to system.billing.list_prices for list-price cost in USD.';
declare or replace columns array<struct<name: string, type: string, comment: string>> = array(
  named_struct('name', 'calendar_key', 'type', 'int', 'comment', 'FK for calendar dimension (dim_calendar).'),
  named_struct('name', 'compute_key', 'type', 'bigint', 'comment', 'FK for compute dimension (dim_compute).'),
  named_struct('name', 'workspace_key', 'type', 'bigint', 'comment', 'FK for workspace dimension (dim_workspace). A hash of workspace_id. Has no matching dim_workspace row when the workspace no longer exists in system.access.workspaces_latest (e.g., cancelled workspace).'),
  named_struct('name', 'record_id', 'type', 'string', 'comment', 'Unique ID for this usage record.'),
  named_struct('name', 'account_id', 'type', 'string', 'comment', 'ID of the Databricks account that generated this usage record.'),
  named_struct('name', 'workspace_id', 'type', 'string', 'comment', 'ID of the workspace where the usage was incurred.'),
  named_struct('name', 'warehouse_id', 'type', 'string', 'comment', 'ID of the SQL warehouse associated with the usage record (from usage_metadata.warehouse_id).'),
  named_struct('name', 'sku_name', 'type', 'string', 'comment', 'Name of the SKU.'),
  named_struct('name', 'cloud', 'type', 'string', 'comment', 'Cloud this usage is relevant for. Possible values are AWS, AZURE, and GCP.'),
  named_struct('name', 'usage_start_time', 'type', 'timestamp', 'comment', 'The start time relevant to this usage record. Timezone information is recorded at the end of the value with +00:00 representing UTC timezone.'),
  named_struct('name', 'usage_end_time', 'type', 'timestamp', 'comment', 'The end time relevant to this usage record. Timezone information is recorded at the end of the value with +00:00 representing UTC timezone.'),
  named_struct('name', 'usage_date', 'type', 'date', 'comment', 'Date of the usage record. Use this field for faster aggregation by date.'),
  named_struct('name', 'usage_unit', 'type', 'string', 'comment', 'Unit this usage is measured in. Possible values include DBUs.'),
  named_struct('name', 'usage_quantity', 'type', 'decimal(38, 18)', 'comment', 'Number of units consumed for this record.'),
  named_struct('name', 'list_price_usd', 'type', 'decimal(38, 18)', 'comment', 'List price per usage_unit at usage_start_time, sourced from system.billing.list_prices.pricing.default. Null if no matching price record.'),
  named_struct('name', 'list_cost_usd', 'type', 'decimal(38, 18)', 'comment', 'List cost in USD: usage_quantity * list_price_usd. Null if no matching price record. This is list price, not negotiated/effective price.'),
  named_struct('name', 'currency_code', 'type', 'string', 'comment', 'Currency code of list_price_usd from system.billing.list_prices.currency_code (typically USD).'),
  named_struct('name', 'record_type', 'type', 'string', 'comment', 'Whether the record is original, a retraction, or a restatement. Possible values are ORIGINAL, RETRACTION, and RESTATEMENT. See https://docs.databricks.com/en/admin/system-tables/billing.html#record-type.'),
  named_struct('name', 'ingestion_date', 'type', 'date', 'comment', 'Date the record was ingested into the usage table.'),
  named_struct('name', 'billing_origin_product', 'type', 'string', 'comment', 'The product that originated the usage. For DBSQL warehouse usage this value is SQL. See https://docs.databricks.com/en/admin/system-tables/billing.html#features for the full list.'),
  named_struct('name', 'usage_type', 'type', 'string', 'comment', 'The type of usage attributed to the product or workload for billing purposes. Possible values are COMPUTE_TIME, STORAGE_SPACE, NETWORK_BYTES, API_CALLS, TOKEN, or GPU_TIME.'),
  named_struct('name', 'sql_tier', 'type', 'string', 'comment', 'SQL warehouse pricing tier from product_features.sql_tier. Possible values are CLASSIC, PRO, or null.'),
  named_struct('name', 'is_serverless', 'type', 'boolean', 'comment', 'Whether the warehouse runs on serverless compute (from product_features.is_serverless).'),
  named_struct('name', 'is_photon', 'type', 'boolean', 'comment', 'Whether Photon was used to process the usage (from product_features.is_photon).'),
  named_struct('name', 'run_as', 'type', 'string', 'comment', 'Identity that executed the workload (from identity_metadata.run_as).'),
  named_struct('name', 'owned_by', 'type', 'string', 'comment', 'User or service principal that owns the SQL warehouse (from identity_metadata.owned_by).'),
  named_struct('name', 'custom_tags', 'type', 'map<string, string>', 'comment', 'Custom tags applied to the usage record (e.g. team, cost center, project).')
);
-- Table mode only
declare or replace table_constraints string = 'constraint fk_fct_usage_dim_calendar foreign key (calendar_key) references dim_calendar (calendar_key), constraint fk_fct_usage_dim_compute foreign key (compute_key) references dim_compute (compute_key), constraint fk_fct_usage_dim_workspace foreign key (workspace_key) references dim_workspace (workspace_key)';
declare or replace cluster_by string = 'calendar_key, compute_key';

declare or replace select_stmt string = "
select
  year(u.usage_date) * 10000 + month(u.usage_date) * 100 + day(u.usage_date) as calendar_key,
  dc.compute_key,
  xxhash64(u.workspace_id) as workspace_key,
  u.record_id,
  u.account_id,
  u.workspace_id,
  u.usage_metadata.warehouse_id,
  u.sku_name,
  u.cloud,
  u.usage_start_time,
  u.usage_end_time,
  u.usage_date,
  u.usage_unit,
  u.usage_quantity,
  lp.pricing.default as list_price_usd,
  u.usage_quantity * lp.pricing.default as list_cost_usd,
  lp.currency_code,
  u.record_type,
  u.ingestion_date,
  u.billing_origin_product,
  u.usage_type,
  u.product_features.sql_tier,
  u.product_features.is_serverless,
  u.product_features.is_photon,
  u.identity_metadata.run_as,
  u.identity_metadata.owned_by,
  u.custom_tags
from system.billing.usage u
inner join dim_compute dc
  on dc.warehouse_id = u.usage_metadata.warehouse_id
  and u.usage_start_time >= dc.effective_start
  and u.usage_start_time < coalesce(dc.effective_end, timestamp('9999-12-31'))
left join system.billing.list_prices lp
  on lp.account_id = u.account_id
  and lp.sku_name = u.sku_name
  and lp.cloud = u.cloud
  and lp.usage_unit = u.usage_unit
  and u.usage_start_time >= lp.price_start_time
  and u.usage_start_time < coalesce(lp.price_end_time, timestamp('9999-12-31'))
where u.usage_date >= current_date() - interval 6 months
  and u.billing_origin_product = 'SQL'
  and u.usage_metadata.warehouse_id is not null";

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
