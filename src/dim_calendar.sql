-- dim_calendar is a view over a generated date range by default, or a table rebuilt on each run when the materialize
-- parameter is 'true'. Both modes share the column definitions and select statement below. See dim_compute.sql.

use catalog identifier(:catalog);
use schema identifier(:schema);

declare or replace materialize boolean = (lower(:materialize) = 'true');
declare or replace object_name string = 'dim_calendar';
declare or replace object_comment string = 'Calendar dimension';
declare or replace columns array<struct<name: string, type: string, comment: string>> = array(
  named_struct('name', 'calendar_key', 'type', 'int not null', 'comment', 'The primary key (PK) of the table and integer representation of the date'),
  named_struct('name', 'calendar_date', 'type', 'date not null', 'comment', 'Calendar date'),
  named_struct('name', 'calendar_year', 'type', 'int not null', 'comment', 'Calendar year'),
  named_struct('name', 'calendar_month', 'type', 'string not null', 'comment', 'Calendar month (January, February, March)'),
  named_struct('name', 'month_of_year', 'type', 'int not null', 'comment', 'Month of year (1 - 12)'),
  named_struct('name', 'calendar_day', 'type', 'string not null', 'comment', 'Calendar day (Monday, Tuesday, Wednesday)'),
  named_struct('name', 'day_of_week', 'type', 'int not null', 'comment', 'Day of week (1 - 7)'),
  named_struct('name', 'day_of_week_start_monday', 'type', 'int not null', 'comment', 'Day of week starting Monday (1 - 7)'),
  named_struct('name', 'is_week_day', 'type', 'string not null', 'comment', 'Flag for weekday, a day of the week other than Saturday or Sunday (Y, N)'),
  named_struct('name', 'day_of_month', 'type', 'int not null', 'comment', 'Day of the month (1 - 31)'),
  named_struct('name', 'is_last_day_of_month', 'type', 'string not null', 'comment', 'Flag for last day of the month (Y, N)'),
  named_struct('name', 'day_of_year', 'type', 'int not null', 'comment', 'Day of the year (1 - 365)'),
  named_struct('name', 'week_of_year_iso', 'type', 'int not null', 'comment', 'Week of the year (1 - 53)'),
  named_struct('name', 'quarter_of_year', 'type', 'int not null', 'comment', 'Quarter of the year (1 - 4)'),
  named_struct('name', 'fiscal_year_oct_to_sep', 'type', 'int not null', 'comment', 'Fiscal year for October to September'),
  named_struct('name', 'fiscal_month_oct_to_sep', 'type', 'int not null', 'comment', 'Fiscal month for October to September (1 - 12)'),
  named_struct('name', 'fiscal_year_jul_to_jun', 'type', 'int not null', 'comment', 'Fiscal year for July to June'),
  named_struct('name', 'fiscal_month_jul_to_jun', 'type', 'int not null', 'comment', 'Fiscal month for July to June (1 - 12)')
);
-- Table mode only
declare or replace table_constraints string = 'primary key (calendar_key) rely';
declare or replace cluster_by string = 'calendar_key';

-- Set the date range in the dates CTE. The fiscal columns are examples.
declare or replace select_stmt string = "
with dates as (
  select explode(sequence(current_date() - interval 5 years, current_date(), interval 1 day)) AS calendar_date
)
select
  year(calendar_date) * 10000 + month(calendar_date) * 100 + day(calendar_date) as calendar_key,
  calendar_date,
  year(calendar_date) AS calendar_year,
  date_format(calendar_date, 'MMMM') as calendar_month,
  month(calendar_date) as month_of_year,
  date_format(calendar_date, 'EEEE') as calendar_day,
  dayofweek(calendar_date) AS day_of_week,
  weekday(calendar_date) + 1 as day_of_week_start_monday,
  case
    when weekday(calendar_date) < 5 then 'Y'
    else 'N'
  end as is_week_day,
  dayofmonth(calendar_date) as day_of_month,
  case
    when calendar_date = last_day(calendar_date) then 'Y'
    else 'N'
  end as is_last_day_of_month,
  dayofyear(calendar_date) as day_of_year,
  weekofyear(calendar_date) as week_of_year_iso,
  quarter(calendar_date) as quarter_of_year,
  case
    when month(calendar_date) >= 10 then year(calendar_date) + 1
    else year(calendar_date)
  end as fiscal_year_oct_to_sep,
  (month(calendar_date) + 2) % 12 + 1 AS fiscal_month_oct_to_sep,
  case
    when month(calendar_date) >= 7 then year(calendar_date) + 1
    else year(calendar_date)
  end as fiscal_year_jul_to_jun,
  (month(calendar_date) + 5) % 12 + 1 AS fiscal_month_jul_to_jun
from
  dates";

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
