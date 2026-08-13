/* =========================================================================
   02_dedup_and_aggregation.sql

   Window-function logic for:
     (A) Deduplicating overlapping legacy sources into fact_call_clean
     (B) Point-in-time aggregation and ranking for manager reporting

   This is the core of what replaced 2.5 hours of manual Excel
   reconciliation with a sub-10-minute scheduled SQL Agent job. Everything
   here operates on callcenter.stg_call_raw, which holds the raw union of
   every legacy export INCLUDING duplicates and overlapping records.

   -------------------------------------------------------------------------
   REVISED August 2026 following the metric reconciliation exercise.
   Two defects were corrected in Part B. See docs/Metric_Reconciliation_Findings.docx.

     Finding 1 - AVG over an INT column truncates. Every average handle time
                 in this file now casts to FLOAT first, matching
                 03_views_for_tableau.sql. The cast is applied inside the
                 ranking ORDER BY as well as the projected column, because
                 ranking on a truncated value manufactured ties between
                 agents whose true averages differ. 929 of 961 agent-days
                 were affected.

     Finding 2 - "ROWS BETWEEN 6 PRECEDING" counts result rows, not calendar
                 days, so the 7-day rolling average silently stretched past
                 seven days whenever an agent had a day with no calls. On
                 this dataset the weekend gap made that universal. B2 is now
                 framed on the calendar.

   Part A was not changed. It reconciled exactly.
   ========================================================================= */


/* =========================================================================
   PART A - DEDUPLICATION
   =========================================================================
   Problem: the same call (same CallRef) can appear in multiple legacy
   sources, AND can appear twice within the correction feed with a later
   load_ts and a corrected duration. A plain DISTINCT can't tell which
   version is "right" - only the load_ts ordering can.

   Solution: ROW_NUMBER() OVER (PARTITION BY call_ref ORDER BY load_ts DESC)
   ranks every version of a call from most-recent to oldest. Row #1 per
   call_ref is the version that should survive into the clean fact table.
   ========================================================================= */

WITH ranked_versions AS (
    SELECT
        call_ref,
        agent_num,
        call_date,
        start_ts,
        duration_sec,
        reason,
        resolved_flag,
        load_ts,
        source_system,
        ROW_NUMBER() OVER (
            PARTITION BY call_ref
            ORDER BY load_ts DESC, stg_call_raw_id DESC
        ) AS version_rank
    FROM callcenter.stg_call_raw
    WHERE agent_num IS NOT NULL   -- agent_num normalized by ETL before load
)
INSERT INTO callcenter.fact_call_clean
    (call_ref, agent_num, call_date, start_ts, duration_sec, reason,
     resolved_flag, winning_source, load_ts)
SELECT
    call_ref,
    agent_num,
    call_date,
    start_ts,
    duration_sec,
    reason,
    resolved_flag,
    source_system,
    load_ts
FROM ranked_versions
WHERE version_rank = 1;
GO

/* Audit query: how many competing versions existed per call, and from
   which sources. Useful for a data-quality report showing the scale of
   the overlap problem this solved. */
SELECT
    call_ref,
    COUNT(*) AS version_count,
    STRING_AGG(source_system, ', ') WITHIN GROUP (ORDER BY load_ts DESC) AS sources_seen
FROM callcenter.stg_call_raw
GROUP BY call_ref
HAVING COUNT(*) > 1
ORDER BY version_count DESC;
GO


/* =========================================================================
   PART B - POINT-IN-TIME AGGREGATION & RANKING
   =========================================================================
   Once fact_call_clean is reliable, the original reporting need was:
   "as of right now, how is each agent performing against their team
   today, this week, and trending?" These are the queries managers ran
   every morning - previously assembled by hand in Excel from multiple
   exports, now returned in milliseconds.
   ========================================================================= */

/* --- B1: Daily agent scorecard with rank-within-manager-team ---
   For each agent/day, total calls handled, average handle time, and
   resolution rate - plus that agent's RANK among peers under the same
   manager for that day, by call volume. This is the "point-in-time"
   ranking: it's always relative to a specific call_date, not a
   running total, so a manager pulling this for "yesterday" gets an
   honest day-over-day comparison instead of a number drifting with
   cumulative history.

   FIXED (finding 1): duration_sec is INT, so AVG over it truncates.
   The FLOAT cast now appears in the projected column AND inside the
   rank_within_team_by_speed ORDER BY. Fixing only the displayed value
   would leave the ranking disagreeing with the number beside it. */
SELECT
    fc.call_date,
    a.manager_id,
    m.manager_name,
    fc.agent_num,
    a.agent_name,
    COUNT(*)                                         AS calls_handled,
    AVG(CAST(fc.duration_sec AS FLOAT))              AS avg_handle_time_sec,
    SUM(CASE WHEN fc.resolved_flag = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(*)                                   AS resolution_rate,
    RANK() OVER (
        PARTITION BY fc.call_date, a.manager_id
        ORDER BY COUNT(*) DESC
    )                                                 AS rank_within_team_by_volume,
    RANK() OVER (
        PARTITION BY fc.call_date, a.manager_id
        ORDER BY AVG(CAST(fc.duration_sec AS FLOAT)) ASC
    )                                                 AS rank_within_team_by_speed
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
LEFT JOIN callcenter.dim_manager m ON m.manager_id = a.manager_id
GROUP BY fc.call_date, a.manager_id, m.manager_name, fc.agent_num, a.agent_name
ORDER BY fc.call_date, a.manager_id, rank_within_team_by_volume;
GO


/* --- B2: 7-day rolling average handle time per agent ---

   FIXED (finding 2). The previous version used:

       ROWS BETWEEN 6 PRECEDING AND CURRENT ROW

   ROWS counts rows in the result set, not calendar days. daily_agent_stats
   only produces a row on a date where the agent actually handled a call,
   so days off produce no row and the window reached backward until it
   found seven rows that existed. On this dataset, which covers two work
   weeks with no weekend volume, every agent in week two carried a window
   spanning NINE calendar days under a metric named "7 day". Agent-to-agent
   comparison on that metric was not valid.

   This version frames the window on the calendar. Days with no calls are
   skipped rather than reached past, so every agent's window covers the
   same seven-day period. This matches the DAX measure
   [Rolling 7-Day Avg Handle Time] exactly.

   Note: SQL Server does not support RANGE with an INTERVAL offset, so the
   calendar frame is expressed as a correlated aggregate rather than a
   window frame. The result is the same and the intent is clearer. */
WITH daily_agent_stats AS (
    SELECT
        agent_num,
        call_date,
        AVG(CAST(duration_sec AS FLOAT)) AS daily_avg_handle_time
    FROM callcenter.fact_call_clean
    GROUP BY agent_num, call_date
)
SELECT
    d.agent_num,
    d.call_date,
    d.daily_avg_handle_time,
    (
        SELECT AVG(d2.daily_avg_handle_time)
        FROM daily_agent_stats d2
        WHERE d2.agent_num = d.agent_num
          AND d2.call_date BETWEEN DATEADD(DAY, -6, d.call_date) AND d.call_date
    ) AS rolling_7day_avg_handle_time,
    (
        SELECT COUNT(*)
        FROM daily_agent_stats d3
        WHERE d3.agent_num = d.agent_num
          AND d3.call_date BETWEEN DATEADD(DAY, -6, d.call_date) AND d.call_date
    ) AS days_with_calls_in_window   -- transparency: how many of the 7 days had volume
FROM daily_agent_stats d
ORDER BY d.agent_num, d.call_date;
GO


/* --- B3: Manager-level team rollup with senior-manager comparison ---
   Aggregates up one more level: each manager's team totals for the day,
   plus that manager's RANK among all managers - the number the senior
   manager (D. Whitfield) actually looked at each morning.

   FIXED (finding 1): FLOAT cast applied to team_avg_handle_time_sec. */
SELECT
    fc.call_date,
    m.manager_id,
    m.manager_name,
    COUNT(*)                                          AS team_calls_handled,
    COUNT(DISTINCT fc.agent_num)                       AS active_agents,
    AVG(CAST(fc.duration_sec AS FLOAT))                AS team_avg_handle_time_sec,
    SUM(CASE WHEN fc.resolved_flag = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(*)                                     AS team_resolution_rate,
    RANK() OVER (
        PARTITION BY fc.call_date
        ORDER BY COUNT(*) DESC
    )                                                   AS team_rank_by_volume
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
JOIN callcenter.dim_manager m ON m.manager_id = a.manager_id
GROUP BY fc.call_date, m.manager_id, m.manager_name
ORDER BY fc.call_date, team_rank_by_volume;
GO


/* --- B4: Data quality surface - unmapped agents, never silently dropped ---
   Call volume attributed to agents missing from the org chart export.
   This is run alongside the manager rollups so unmapped volume is visible
   as its own line item rather than vanishing from totals.

   Counted on agent_num, never agent_name. The four unmapped agents have no
   name of record anywhere upstream, so a distinct count of names returns
   zero during the exact incident this query exists to measure. See finding 4. */
SELECT
    fc.call_date,
    COUNT(*)            AS unmapped_call_count,
    COUNT(DISTINCT fc.agent_num) AS unmapped_agent_count
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
WHERE a.manager_assignment_status = 'UNMAPPED_ORG_CHART_GAP'
GROUP BY fc.call_date
ORDER BY fc.call_date;
GO
