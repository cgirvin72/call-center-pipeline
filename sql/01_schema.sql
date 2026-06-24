/* =========================================================================
   01_schema.sql

   Call Center Reporting Consolidation — SQL Server Schema

   Real-world context: this schema is the destination for the Python ETL
   layer (etl_pipeline.py) once it has standardized, deduplicated, and
   enriched the legacy Access export data. Tableau connects directly to
   the views/tables defined here (see 03_views_for_tableau.sql) — Python
   and SQL Server never produce reports themselves; that's the Tableau
   consumption layer's job.

   Design notes:
     - stg_call_raw exists to receive the RAW union of all legacy sources
       BEFORE deduplication, preserving a full audit trail. This is what
       gets bulk-loaded directly from the legacy exports.
     - fact_call_clean is the deduplicated, enriched table the Python ETL
       produces (mirrors source_data/clean/fact_call_clean.csv exactly).
       In production this is populated by the window-function dedup logic
       in 02_dedup_and_aggregation.sql, run as a scheduled SQL Agent job
       immediately after the bulk load — this is what cut the reporting
       lag from 2.5 hours to under 10 minutes.
     - dim_manager and dim_agent are small reference dimensions.
   ========================================================================= */

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'callcenter')
    EXEC('CREATE SCHEMA callcenter');
GO

/* -------------------------------------------------------------------------
   Staging table: raw union of ALL legacy exports, BEFORE dedup.
   This intentionally allows duplicate CallRef values — that's the whole
   point of staging it separately from the clean fact table.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('callcenter.stg_call_raw', 'U') IS NOT NULL
    DROP TABLE callcenter.stg_call_raw;
GO

CREATE TABLE callcenter.stg_call_raw (
    stg_call_raw_id    BIGINT IDENTITY(1,1) PRIMARY KEY,
    call_ref           VARCHAR(20)     NOT NULL,
    agent_id_raw       VARCHAR(20)     NOT NULL,   -- unstandardized, as it arrived
    agent_num          INT             NULL,       -- populated by ETL after normalization
    call_date          DATE            NOT NULL,
    start_ts           DATETIME2(0)    NOT NULL,
    duration_sec       INT             NOT NULL,
    reason             VARCHAR(100)    NULL,
    resolved_flag      BIT             NOT NULL,
    load_ts            DATETIME2(0)    NOT NULL,   -- when THIS version was exported/loaded
    source_system      VARCHAR(30)     NOT NULL,   -- which legacy export this row came from
    ingested_at        DATETIME2(0)    NOT NULL DEFAULT SYSDATETIME()
);
GO

CREATE INDEX ix_stg_call_raw_callref ON callcenter.stg_call_raw (call_ref, load_ts DESC);
GO

/* -------------------------------------------------------------------------
   Dimension: managers (small, clean reference table)
   ------------------------------------------------------------------------- */
IF OBJECT_ID('callcenter.dim_manager', 'U') IS NOT NULL
    DROP TABLE callcenter.dim_manager;
GO

CREATE TABLE callcenter.dim_manager (
    manager_id      VARCHAR(10)   NOT NULL PRIMARY KEY,
    manager_name    VARCHAR(100)  NOT NULL,
    title           VARCHAR(50)   NOT NULL
);
GO

/* -------------------------------------------------------------------------
   Dimension: agents, including a flag for org-chart mapping status.
   Populated from the org-chart legacy export. Agents missing from that
   export still get a row here (manager_id NULL) so their call volume is
   never silently excluded from totals — it's surfaced as a data quality
   gap instead.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('callcenter.dim_agent', 'U') IS NOT NULL
    DROP TABLE callcenter.dim_agent;
GO

CREATE TABLE callcenter.dim_agent (
    agent_num                   INT           NOT NULL PRIMARY KEY,
    agent_name                  VARCHAR(100)  NULL,
    manager_id                  VARCHAR(10)   NULL REFERENCES callcenter.dim_manager(manager_id),
    manager_assignment_status   VARCHAR(30)   NOT NULL DEFAULT 'MAPPED'
        CHECK (manager_assignment_status IN ('MAPPED', 'UNMAPPED_ORG_CHART_GAP'))
);
GO

/* -------------------------------------------------------------------------
   Fact table: the clean, deduplicated, query-ready call records.
   This is what Tableau connects to. One row per CallRef, guaranteed.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('callcenter.fact_call_clean', 'U') IS NOT NULL
    DROP TABLE callcenter.fact_call_clean;
GO

CREATE TABLE callcenter.fact_call_clean (
    call_ref            VARCHAR(20)     NOT NULL PRIMARY KEY,
    agent_num           INT             NOT NULL REFERENCES callcenter.dim_agent(agent_num),
    call_date           DATE            NOT NULL,
    start_ts            DATETIME2(0)    NOT NULL,
    duration_sec        INT             NOT NULL CHECK (duration_sec > 0),
    reason              VARCHAR(100)    NULL,
    resolved_flag       BIT             NOT NULL,
    winning_source      VARCHAR(30)     NOT NULL,  -- audit trail: which legacy export "won" dedup
    load_ts             DATETIME2(0)    NOT NULL,
    loaded_at           DATETIME2(0)    NOT NULL DEFAULT SYSDATETIME()
);
GO

CREATE INDEX ix_fact_call_clean_agent_date ON callcenter.fact_call_clean (agent_num, call_date);
CREATE INDEX ix_fact_call_clean_date ON callcenter.fact_call_clean (call_date);
GO

PRINT 'Schema created: callcenter.stg_call_raw, dim_manager, dim_agent, fact_call_clean';
