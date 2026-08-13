/* =========================================================================
   05_reconciliation.sql

   The proof harness. Each query returns the SQL-side value for a metric
   that also exists as a DAX measure in powerbi/measures.dax. Run these,
   put the same measure on a Power BI table visual at the same grain with
   the same filters, and compare.

   Agreement is the deliverable. Paste the results into
   docs/reconciliation-findings.md.

   NOTE ON HANDLE TIME: these queries use AVG(CAST(duration_sec AS FLOAT))
   throughout, matching 03_views_for_tableau.sql. The truncating INT
   version in 02_dedup_and_aggregation.sql B1/B3 will NOT match DAX. That
   is finding 1, not a reconciliation failure.
   ========================================================================= */


/* -------------------------------------------------------------------------
   R1 — Dedup integrity. Must hold before anything else is worth checking.
   Compare to: [Recon - Fact Row Count], [Recon - Distinct Call Refs],
               [Recon - Dedup Integrity]
   Expected against the current synthetic dataset: 28,864 / 28,864 / PASS
   ------------------------------------------------------------------------- */
SELECT
    COUNT(*)                    AS fact_row_count,
    COUNT(DISTINCT call_ref)    AS distinct_call_refs,
    CASE WHEN COUNT(*) = COUNT(DISTINCT call_ref)
         THEN 'PASS'
         ELSE 'FAIL - duplicate call_ref present'
    END                         AS dedup_integrity
FROM callcenter.fact_call_clean;
GO


/* -------------------------------------------------------------------------
   R2 — Grand totals, no filters. The fastest way to catch a broken
   relationship or an unintended filter in the Power BI model.
   Compare to: [Calls Handled], [Avg Handle Time (sec)], [Resolution Rate],
               [Active Agents] with no slicers applied.
   ------------------------------------------------------------------------- */
SELECT
    COUNT(*)                                    AS calls_handled,
    AVG(CAST(duration_sec AS FLOAT))            AS avg_handle_time_sec,
    SUM(CASE WHEN resolved_flag = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(*)                              AS resolution_rate,
    COUNT(DISTINCT agent_num)                   AS active_agents
FROM callcenter.fact_call_clean;
GO


/* -------------------------------------------------------------------------
   R3 — Agent/day scorecard. The main grain. Restricted to one date to keep
   the comparison readable; widen the filter once it matches.
   Compare to: a Power BI table with call_date and agent_num on rows and
               [Calls Handled], [Avg Handle Time (sec)], [Resolution Rate],
               [Rank Within Team by Volume] as values.

   Set @check_date to a date that exists in your data before running.
   ------------------------------------------------------------------------- */
DECLARE @check_date DATE = (SELECT MIN(call_date) FROM callcenter.fact_call_clean);

SELECT
    fc.call_date,
    a.manager_id,
    fc.agent_num,
    COUNT(*)                                    AS calls_handled,
    AVG(CAST(fc.duration_sec AS FLOAT))         AS avg_handle_time_sec,
    SUM(CASE WHEN fc.resolved_flag = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(*)                              AS resolution_rate,
    RANK() OVER (
        PARTITION BY fc.call_date, a.manager_id
        ORDER BY COUNT(*) DESC
    )                                           AS rank_within_team_by_volume
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
WHERE fc.call_date = @check_date
GROUP BY fc.call_date, a.manager_id, fc.agent_num
ORDER BY a.manager_id, rank_within_team_by_volume;
GO


/* -------------------------------------------------------------------------
   R4 — Manager rollup and cross-team rank.
   Compare to: manager_name on rows, [Calls Handled], [Active Agents],
               [Avg Handle Time (sec)], [Resolution Rate],
               [Team Rank by Volume].

   Note the INNER JOIN to dim_manager, matching vw_manager_daily_rollup.
   Unmapped agents are excluded here by design and are accounted for in R5.
   R2 + R5 will therefore exceed the sum of R4. That is expected, and it is
   the behavior the org-chart finding exists to make visible.
   ------------------------------------------------------------------------- */
DECLARE @check_date_r4 DATE = (SELECT MIN(call_date) FROM callcenter.fact_call_clean);

SELECT
    fc.call_date,
    m.manager_id,
    m.manager_name,
    COUNT(*)                                    AS team_calls_handled,
    COUNT(DISTINCT fc.agent_num)                AS active_agents,
    AVG(CAST(fc.duration_sec AS FLOAT))         AS team_avg_handle_time_sec,
    SUM(CASE WHEN fc.resolved_flag = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(*)                              AS team_resolution_rate,
    RANK() OVER (
        PARTITION BY fc.call_date
        ORDER BY COUNT(*) DESC
    )                                           AS team_rank_by_volume
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a   ON a.agent_num = fc.agent_num
JOIN callcenter.dim_manager m ON m.manager_id = a.manager_id
WHERE fc.call_date = @check_date_r4
GROUP BY fc.call_date, m.manager_id, m.manager_name
ORDER BY team_rank_by_volume;
GO


/* -------------------------------------------------------------------------
   R5 — Data quality surface.
   Compare to: [Unmapped Call Count], [Unmapped Agent Count],
               [Unmapped Call %]
   Expected against the current synthetic dataset: 4 unmapped agents of 103.
   ------------------------------------------------------------------------- */
SELECT
    fc.call_date,
    COUNT(*)                                    AS unmapped_call_count,
    COUNT(DISTINCT fc.agent_num)                AS unmapped_agent_count,
    CAST(COUNT(*) AS FLOAT) / NULLIF((
        SELECT COUNT(*) FROM callcenter.fact_call_clean f2
        WHERE f2.call_date = fc.call_date
    ), 0)                                       AS unmapped_call_pct
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
WHERE a.manager_assignment_status = 'UNMAPPED_ORG_CHART_GAP'
GROUP BY fc.call_date
ORDER BY fc.call_date;
GO


/* -------------------------------------------------------------------------
   R6 — Finding 1 demonstration. Run this to show the truncation with real
   numbers rather than describing it. Any row where the two columns differ
   is a row where the ad-hoc query and the Tableau view disagree.
   ------------------------------------------------------------------------- */
SELECT TOP 20
    fc.call_date,
    fc.agent_num,
    AVG(fc.duration_sec)                        AS aht_int_truncated,   -- as in 02 B1/B3
    AVG(CAST(fc.duration_sec AS FLOAT))         AS aht_float_correct,   -- as in 03 views
    AVG(CAST(fc.duration_sec AS FLOAT))
        - AVG(fc.duration_sec)                  AS truncation_loss_sec
FROM callcenter.fact_call_clean fc
GROUP BY fc.call_date, fc.agent_num
HAVING AVG(CAST(fc.duration_sec AS FLOAT)) <> AVG(fc.duration_sec)
ORDER BY truncation_loss_sec DESC;
GO


/* -------------------------------------------------------------------------
   R7 — Finding 2 demonstration. Shows how far back the row-based window
   actually reaches in calendar terms. Any row where window_calendar_span
   exceeds 7 is an agent whose "7-day rolling average" covers more than
   seven days.
   ------------------------------------------------------------------------- */
WITH daily_agent_stats AS (
    SELECT agent_num, call_date, AVG(CAST(duration_sec AS FLOAT)) AS daily_avg
    FROM callcenter.fact_call_clean
    GROUP BY agent_num, call_date
),
windowed AS (
    SELECT
        agent_num,
        call_date,
        MIN(call_date) OVER (
            PARTITION BY agent_num ORDER BY call_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS window_start_date,
        COUNT(*) OVER (
            PARTITION BY agent_num ORDER BY call_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rows_in_window
    FROM daily_agent_stats
)
SELECT
    agent_num,
    call_date,
    window_start_date,
    rows_in_window,
    DATEDIFF(DAY, window_start_date, call_date) + 1 AS window_calendar_span
FROM windowed
WHERE rows_in_window = 7
  AND DATEDIFF(DAY, window_start_date, call_date) + 1 > 7
ORDER BY window_calendar_span DESC, agent_num, call_date;
GO
