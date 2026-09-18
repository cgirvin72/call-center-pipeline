/* =========================================================================
   05_bulk_load_staging.sql

   Loads the standardized staging export produced by etl_pipeline.py into
   callcenter.stg_call_raw.

   This is the seam between the two layers. Python's job ends at producing
   one trustworthy, query-ready file: all six legacy exports unioned, agent
   identifiers normalized to a canonical form, nothing deduplicated. SQL
   Server's job starts here. Dedup, ranking, and aggregation happen after
   the data has landed, where the engine is best at them.

   Input file: source_data/clean/stg_call_raw.csv
   Produced by: scripts/export_staging_csv.py (or the equivalent step in
   etl_pipeline.py)

   Column order in the CSV, which must match the INSERT below exactly:
       call_ref, agent_id_raw, agent_num, call_date, start_ts,
       duration_sec, reason, resolved_flag, load_ts, source_system

   agent_num is written empty by the ETL when the raw identifier could not
   be resolved. Those rows still load. the procedure in 07 captures them as
   AGENT_ID_NOT_NORMALIZED rather than discarding them silently, which is
   the behavior this staging design exists to make possible.
   ========================================================================= */


/* -------------------------------------------------------------------------
   Running against a SQL Server container

   BULK INSERT reads from the SQL Server's filesystem, not the client's. In
   a container the file has to be inside the container first:

       docker cp source_data/clean/stg_call_raw.csv <container>:/tmp/stg_call_raw.csv

   Then use '/tmp/stg_call_raw.csv' as the path below.

   Running against a local Windows install: use the full Windows path, and
   make sure the SQL Server service account can read it. A path under the
   user profile often cannot be read by the service. C:\sqldata\ or similar
   is safer.
   ------------------------------------------------------------------------- */

DECLARE @csv_path NVARCHAR(400) = N'/tmp/stg_call_raw.csv';   -- container
-- DECLARE @csv_path NVARCHAR(400) = N'C:\sqldata\stg_call_raw.csv';  -- local Windows


/* -------------------------------------------------------------------------
   Landing table. Every column text, nothing rejected at load time.

   The CSV is a text file, so it gets loaded as text and converted after.
   Converting during BULK INSERT means one malformed value fails the whole
   batch with an error that points at a byte offset rather than at a row you
   can look at. Landing first costs one extra table and makes bad rows
   inspectable.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('callcenter.land_call_raw', 'U') IS NOT NULL
    DROP TABLE callcenter.land_call_raw;
GO

CREATE TABLE callcenter.land_call_raw (
    call_ref        VARCHAR(50)   NULL,
    agent_id_raw    VARCHAR(50)   NULL,
    agent_num       VARCHAR(50)   NULL,
    call_date       VARCHAR(50)   NULL,
    start_ts        VARCHAR(50)   NULL,
    duration_sec    VARCHAR(50)   NULL,
    reason          VARCHAR(200)  NULL,
    resolved_flag   VARCHAR(50)   NULL,
    load_ts         VARCHAR(50)   NULL,
    source_system   VARCHAR(50)   NULL
);
GO


/* -------------------------------------------------------------------------
   Bulk load.

   FIRSTROW = 2 skips the header. FIELDQUOTE handles quoted fields, which
   matters because the reason column contains commas. ROWTERMINATOR is set
   to \n rather than \r\n because Python writes the file with newline=''
   and the trailing carriage return, if present, is trimmed in the convert
   step below.
   ------------------------------------------------------------------------- */
TRUNCATE TABLE callcenter.land_call_raw;

DECLARE @sql NVARCHAR(MAX) = N'
BULK INSERT callcenter.land_call_raw
FROM ''' + @csv_path + N'''
WITH (
    FORMAT          = ''CSV'',
    FIRSTROW        = 2,
    FIELDQUOTE      = ''"'',
    FIELDTERMINATOR = '','',
    ROWTERMINATOR   = ''0x0a'',
    TABLOCK
);';

EXEC sp_executesql @sql;

PRINT CONCAT('Landed rows: ', (SELECT COUNT(*) FROM callcenter.land_call_raw));
GO


/* -------------------------------------------------------------------------
   Convert and insert into staging.

   stg_call_raw is the raw union before dedup, so duplicate call_ref values
   are expected and correct here. TRY_CONVERT is used rather than CONVERT so
   a single unparseable value produces a NULL that the load procedure can
   report, rather than failing the whole batch.
   ------------------------------------------------------------------------- */
TRUNCATE TABLE callcenter.stg_call_raw;

INSERT INTO callcenter.stg_call_raw
    (call_ref, agent_id_raw, agent_num, call_date, start_ts,
     duration_sec, reason, resolved_flag, load_ts, source_system)
SELECT
    LTRIM(RTRIM(l.call_ref)),
    LTRIM(RTRIM(l.agent_id_raw)),
    TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(l.agent_num)), '')),
    TRY_CONVERT(DATE, LTRIM(RTRIM(l.call_date))),
    TRY_CONVERT(DATETIME2(0), LTRIM(RTRIM(l.start_ts))),
    TRY_CONVERT(INT, LTRIM(RTRIM(l.duration_sec))),
    NULLIF(LTRIM(RTRIM(l.reason)), ''),
    CASE WHEN LTRIM(RTRIM(l.resolved_flag)) IN ('1', 'True', 'TRUE', 'true', 'Y', 'Yes')
         THEN 1 ELSE 0 END,
    TRY_CONVERT(DATETIME2(0), LTRIM(RTRIM(l.load_ts))),
    LTRIM(RTRIM(l.source_system))
FROM callcenter.land_call_raw AS l
WHERE l.call_ref IS NOT NULL
  AND LTRIM(RTRIM(l.call_ref)) <> '';
GO


/* -------------------------------------------------------------------------
   Load check. Compare these against the counts etl_pipeline.py printed.

   unioned_rows should match the Python union count exactly. If it does not,
   the load is wrong and nothing downstream is worth running.
   ------------------------------------------------------------------------- */
SELECT
    unioned_rows       = COUNT(*),
    distinct_calls     = COUNT(DISTINCT call_ref),
    competing_versions = COUNT(*) - COUNT(DISTINCT call_ref),
    unresolved_agents  = SUM(CASE WHEN agent_num IS NULL THEN 1 ELSE 0 END),
    bad_dates          = SUM(CASE WHEN call_date IS NULL THEN 1 ELSE 0 END),
    first_date         = MIN(call_date),
    last_date          = MAX(call_date)
FROM callcenter.stg_call_raw;

SELECT source_system, row_count = COUNT(*)
FROM callcenter.stg_call_raw
GROUP BY source_system
ORDER BY source_system;
GO


/* -------------------------------------------------------------------------
   Next step: load the clean fact table one date at a time.

     DECLARE @d DATE = (SELECT MIN(call_date) FROM callcenter.stg_call_raw);
     WHILE @d <= (SELECT MAX(call_date) FROM callcenter.stg_call_raw)
     BEGIN
         EXEC callcenter.usp_load_clean_calls @call_date = @d;
         SET @d = DATEADD(DAY, 1, @d);
     END;

     SELECT * FROM callcenter.etl_run_log ORDER BY run_id;
   ------------------------------------------------------------------------- */
