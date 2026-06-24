/* =========================================================================
   03_views_for_tableau.sql

   Views exposed as the connection point for Tableau. Tableau never queries
   stg_call_raw or runs its own dedup/window-function logic — it connects
   to these views, which already encapsulate the cleaning and aggregation
   work done in 02_dedup_and_aggregation.sql. This keeps the heavy lifting
   in the warehouse where it belongs and keeps the dashboards fast and
   simple to build/maintain.
   ========================================================================= */

IF OBJECT_ID('callcenter.vw_daily_agent_scorecard', 'V') IS NOT NULL
    DROP VIEW callcenter.vw_daily_agent_scorecard;
GO

CREATE VIEW callcenter.vw_daily_agent_scorecard AS
SELECT
    fc.call_date,
    a.manager_id,
    m.manager_name,
    fc.agent_num,
    a.agent_name,
    COUNT(*)                                         AS calls_handled,
    AVG(CAST(fc.duration_sec AS FLOAT))               AS avg_handle_time_sec,
    SUM(CASE WHEN fc.resolved_flag = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(*)                                   AS resolution_rate,
    RANK() OVER (
        PARTITION BY fc.call_date, a.manager_id
        ORDER BY COUNT(*) DESC
    )                                                 AS rank_within_team_by_volume
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
LEFT JOIN callcenter.dim_manager m ON m.manager_id = a.manager_id
GROUP BY fc.call_date, a.manager_id, m.manager_name, fc.agent_num, a.agent_name;
GO

IF OBJECT_ID('callcenter.vw_manager_daily_rollup', 'V') IS NOT NULL
    DROP VIEW callcenter.vw_manager_daily_rollup;
GO

CREATE VIEW callcenter.vw_manager_daily_rollup AS
SELECT
    fc.call_date,
    m.manager_id,
    m.manager_name,
    COUNT(*)                                          AS team_calls_handled,
    COUNT(DISTINCT fc.agent_num)                       AS active_agents,
    AVG(CAST(fc.duration_sec AS FLOAT))                AS team_avg_handle_time_sec,
    SUM(CASE WHEN fc.resolved_flag = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(*)                                     AS team_resolution_rate
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
JOIN callcenter.dim_manager m ON m.manager_id = a.manager_id
GROUP BY fc.call_date, m.manager_id, m.manager_name;
GO

IF OBJECT_ID('callcenter.vw_data_quality_unmapped', 'V') IS NOT NULL
    DROP VIEW callcenter.vw_data_quality_unmapped;
GO

CREATE VIEW callcenter.vw_data_quality_unmapped AS
SELECT
    fc.call_date,
    COUNT(*)                       AS unmapped_call_count,
    COUNT(DISTINCT fc.agent_num)   AS unmapped_agent_count
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
WHERE a.manager_assignment_status = 'UNMAPPED_ORG_CHART_GAP'
GROUP BY fc.call_date;
GO

PRINT 'Tableau-facing views created: vw_daily_agent_scorecard, vw_manager_daily_rollup, vw_data_quality_unmapped';
