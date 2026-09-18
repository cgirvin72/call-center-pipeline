/* ============================================================================
   callcenter.usp_load_clean_calls

   Loads one call date from the staging table into the clean fact table.

   Wraps the deduplication logic from 02_dedup_and_aggregation.sql in a
   re-runnable, logged, transactional procedure so the load can be scheduled,
   re-run safely after a late correction, and audited afterward.

   Object names below follow 01_schema.sql. If a name differs in your copy of
   the schema, change it here rather than in the calling job.
   ========================================================================= */


/* ---------------------------------------------------------------------------
   Supporting objects: run log and the reject table for unmapped agents.
   Created here so the procedure is self-contained on a fresh database.
   ------------------------------------------------------------------------ */
IF OBJECT_ID('callcenter.etl_run_log', 'U') IS NULL
BEGIN
    CREATE TABLE callcenter.etl_run_log (
        run_id            INT IDENTITY(1,1) PRIMARY KEY,
        proc_name         SYSNAME        NOT NULL,
        call_date         DATE           NULL,
        started_at        DATETIME2(0)   NOT NULL,
        finished_at       DATETIME2(0)   NULL,
        status            VARCHAR(20)    NOT NULL,   -- STARTED | SUCCESS | FAILED
        rows_staged       INT            NULL,
        rows_deduped      INT            NULL,
        rows_loaded       INT            NULL,
        rows_unmapped     INT            NULL,
        error_number      INT            NULL,
        error_message     NVARCHAR(2048) NULL
    );
END;
GO

IF OBJECT_ID('callcenter.fact_call_reject', 'U') IS NULL
BEGIN
    CREATE TABLE callcenter.fact_call_reject (
        call_ref       VARCHAR(50)   NOT NULL,
        agent_num      VARCHAR(20)   NULL,
        call_date      DATE          NOT NULL,
        duration_sec   INT           NULL,
        source_system  VARCHAR(50)   NULL,
        reject_reason  VARCHAR(50)   NOT NULL,
        logged_at      DATETIME2(0)  NOT NULL CONSTRAINT DF_reject_logged DEFAULT SYSDATETIME()
    );
END;
GO


CREATE OR ALTER PROCEDURE callcenter.usp_load_clean_calls
    @call_date DATE,
    @debug     BIT = 0          -- 1 returns the result sets instead of staying silent
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;          -- any unhandled error rolls the transaction back

    DECLARE @run_id        INT,
            @rows_staged   INT = 0,
            @rows_deduped  INT = 0,
            @rows_loaded   INT = 0,
            @rows_unmapped INT = 0;

    INSERT INTO callcenter.etl_run_log (proc_name, call_date, started_at, status)
    VALUES (OBJECT_NAME(@@PROCID), @call_date, SYSDATETIME(), 'STARTED');

    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY

        /* -------------------------------------------------------------------
           1. Rank every staged version of each call and keep the newest.

              Duplicates here are not identical rows. They are competing
              versions of the same call: an enterprise export and a regional
              export covering the same call, or a QA correction re-exported
              days later with a new handle time. Newest load_ts wins.
           ---------------------------------------------------------------- */
        IF OBJECT_ID('tempdb..#ranked') IS NOT NULL DROP TABLE #ranked;

        WITH ranked_versions AS (
            SELECT
                s.call_ref,
                s.agent_num,
                s.call_date,
                s.duration_sec,
                s.resolved_flag,
                s.load_ts,
                s.source_system,
                ROW_NUMBER() OVER (
                    PARTITION BY s.call_ref
                    ORDER BY s.load_ts DESC
                ) AS version_rank
            FROM callcenter.stg_call_raw AS s
            WHERE s.call_date = @call_date
        )
        SELECT *
        INTO #ranked
        FROM ranked_versions;

        SELECT @rows_staged = COUNT(*) FROM #ranked;
        SELECT @rows_deduped = COUNT(*) FROM #ranked WHERE version_rank > 1;

        /* -------------------------------------------------------------------
           2. Separate the winning rows that have no current manager mapping.

              A stale org-chart export leaves agents unassigned. An INNER JOIN
              against the agent dimension would remove their call volume from
              team totals with no error raised, which understates the team and
              looks like a performance problem rather than a data problem.
              These rows are rejected explicitly and counted, never dropped.
           ---------------------------------------------------------------- */
        BEGIN TRANSACTION;

            DELETE FROM callcenter.fact_call_reject
            WHERE call_date = @call_date;

            INSERT INTO callcenter.fact_call_reject
                (call_ref, agent_num, call_date, duration_sec, source_system, reject_reason)
            SELECT
                r.call_ref,
                r.agent_num,
                r.call_date,
                r.duration_sec,
                r.source_system,
                'UNMAPPED_ORG_CHART_GAP'
            FROM #ranked AS r
            LEFT JOIN callcenter.dim_agent AS a
                   ON a.agent_num = r.agent_num
                  AND a.is_current = 1
            WHERE r.version_rank = 1
              AND a.agent_key IS NULL;

            SET @rows_unmapped = @@ROWCOUNT;

            /* ---------------------------------------------------------------
               3. Replace this date's rows, then insert the mapped winners.

                  Delete-then-insert scoped to @call_date is what makes the
                  procedure idempotent: re-running the same date after a late
                  QA correction replaces that day rather than doubling it.
               ------------------------------------------------------------ */
            DELETE FROM callcenter.fact_call
            WHERE call_date = @call_date;

            INSERT INTO callcenter.fact_call
                (call_ref, agent_key, call_date, duration_sec, resolved_flag, source_system, loaded_at)
            SELECT
                r.call_ref,
                a.agent_key,
                r.call_date,
                r.duration_sec,
                r.resolved_flag,
                r.source_system,
                SYSDATETIME()
            FROM #ranked AS r
            INNER JOIN callcenter.dim_agent AS a
                    ON a.agent_num = r.agent_num
                   AND a.is_current = 1
            WHERE r.version_rank = 1;

            SET @rows_loaded = @@ROWCOUNT;

            /* ---------------------------------------------------------------
               4. Reconciliation gate.

                  Winning rows must equal loaded rows plus rejected rows. If
                  they do not, something was lost between the ranking step and
                  the insert, and the load is failed rather than reported as a
                  success with a quietly short total.
               ------------------------------------------------------------ */
            DECLARE @winners INT = (SELECT COUNT(*) FROM #ranked WHERE version_rank = 1);

            IF @winners <> (@rows_loaded + @rows_unmapped)
                THROW 50001, 'Reconciliation failed: winning rows do not equal loaded plus rejected.', 1;

        COMMIT TRANSACTION;

        UPDATE callcenter.etl_run_log
           SET finished_at   = SYSDATETIME(),
               status        = 'SUCCESS',
               rows_staged   = @rows_staged,
               rows_deduped  = @rows_deduped,
               rows_loaded   = @rows_loaded,
               rows_unmapped = @rows_unmapped
         WHERE run_id = @run_id;

        IF @debug = 1
        BEGIN
            SELECT
                call_date     = @call_date,
                rows_staged   = @rows_staged,
                rows_deduped  = @rows_deduped,
                rows_loaded   = @rows_loaded,
                rows_unmapped = @rows_unmapped;

            SELECT * FROM callcenter.fact_call_reject WHERE call_date = @call_date;
        END;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        UPDATE callcenter.etl_run_log
           SET finished_at   = SYSDATETIME(),
               status        = 'FAILED',
               rows_staged   = @rows_staged,
               rows_deduped  = @rows_deduped,
               error_number  = ERROR_NUMBER(),
               error_message = ERROR_MESSAGE()
         WHERE run_id = @run_id;

        THROW;   -- re-raise so the scheduler sees a failure, not a silent no-op

    END CATCH;
END;
GO


/* ---------------------------------------------------------------------------
   Usage

     EXEC callcenter.usp_load_clean_calls @call_date = '2026-03-14';
     EXEC callcenter.usp_load_clean_calls @call_date = '2026-03-14', @debug = 1;

   Re-running the same date is safe and expected. It is how a late QA
   correction gets applied.
   ------------------------------------------------------------------------ */
