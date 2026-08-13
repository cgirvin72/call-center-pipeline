/* =========================================================================
   04_dim_date.sql

   Date dimension for the Power BI semantic layer.

   Why this exists: the SQL consumption layer computes everything against
   fact_call_clean.call_date directly, which is fine for set-based queries.
   A tabular semantic model cannot do that. DAX time intelligence requires
   a contiguous, gap-free date table marked as the model's date table.
   Without one, a rolling average silently skips days that had no calls,
   which is the exact defect documented in docs/reconciliation-findings.md.

   This table is additive. Nothing in 01, 02, or 03 changes.
   ========================================================================= */

IF OBJECT_ID('callcenter.dim_date', 'U') IS NOT NULL
    DROP TABLE callcenter.dim_date;
GO

CREATE TABLE callcenter.dim_date (
    date_key        DATE         NOT NULL PRIMARY KEY,
    day_of_week     TINYINT      NOT NULL,   -- 1 = Monday, ISO
    day_name        VARCHAR(10)  NOT NULL,
    is_weekday      BIT          NOT NULL,
    iso_week        TINYINT      NOT NULL,
    month_num       TINYINT      NOT NULL,
    month_name      VARCHAR(10)  NOT NULL,
    year_num        SMALLINT     NOT NULL,
    year_month      CHAR(7)      NOT NULL    -- 'YYYY-MM', for sorting
);
GO

/* Build a contiguous calendar covering the full fact range, padded 30 days
   on each side so trailing-window calculations have room at the boundaries. */
DECLARE @min_date DATE, @max_date DATE;

SELECT
    @min_date = DATEADD(DAY, -30, MIN(call_date)),
    @max_date = DATEADD(DAY,  30, MAX(call_date))
FROM callcenter.fact_call_clean;

/* Fall back to a sane default if the fact table is empty at build time. */
IF @min_date IS NULL
BEGIN
    SET @min_date = '2026-01-01';
    SET @max_date = '2026-12-31';
END

;WITH n AS (
    SELECT TOP (DATEDIFF(DAY, @min_date, @max_date) + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS offset_days
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO callcenter.dim_date
    (date_key, day_of_week, day_name, is_weekday, iso_week,
     month_num, month_name, year_num, year_month)
SELECT
    d.date_key,
    CAST(((DATEPART(WEEKDAY, d.date_key) + @@DATEFIRST - 2) % 7) + 1 AS TINYINT),
    DATENAME(WEEKDAY, d.date_key),
    CASE WHEN ((DATEPART(WEEKDAY, d.date_key) + @@DATEFIRST - 2) % 7) + 1 <= 5
         THEN 1 ELSE 0 END,
    CAST(DATEPART(ISO_WEEK, d.date_key) AS TINYINT),
    CAST(MONTH(d.date_key) AS TINYINT),
    DATENAME(MONTH, d.date_key),
    CAST(YEAR(d.date_key) AS SMALLINT),
    FORMAT(d.date_key, 'yyyy-MM')
FROM (SELECT DATEADD(DAY, offset_days, @min_date) AS date_key FROM n) d;
GO

CREATE INDEX ix_dim_date_year_month ON callcenter.dim_date (year_month);
GO

PRINT 'Date dimension created: callcenter.dim_date';
GO

/* -------------------------------------------------------------------------
   Power BI model setup, done once in Power BI Desktop after import:

     1. Relationships (all single-direction, one to many):
          dim_date[date_key]        1 --> * fact_call_clean[call_date]
          dim_agent[agent_num]      1 --> * fact_call_clean[agent_num]
          dim_manager[manager_id]   1 --> * dim_agent[manager_id]

     2. Mark dim_date as the model date table, using date_key.
        Without this, DATESINPERIOD and every other time-intelligence
        function returns wrong results silently.

     3. dim_agent[manager_id] is nullable by design. Agents carrying
        'UNMAPPED_ORG_CHART_GAP' have no manager and will land in a blank
        row on the dim_manager side. That is intended: the org-chart gap
        stays visible instead of being dropped. Do not "fix" it by making
        the join inner.
   ------------------------------------------------------------------------- */
