/* =========================================================================
   02_dedup_and_aggregation.sql

   Window-function logic for:
     (A) Deduplicating overlapping legacy sources into fact_call_clean
     (B) Point-in-time aggregation and ranking for manager reporting

   This is the core of what replaced 2.5 hours of manual Excel
   reconciliation with a sub-10-minute scheduled SQL Agent job. Everything
   here operates on callcenter.stg_call_raw, which holds the raw union of
   every legacy export INCLUDING duplicates and overlapping records.
   ========================================================================= */


/* =========================================================================
   PART A — DEDUPLICATION
   =========================================================================
   Problem: the same call (same CallRef) can appear in multiple legacy
   sources, AND can appear twice within the correction feed with a later
   load_ts and a corrected duration. A plain DISTINCT can't tell which
   version is "right" — only the load_ts ordering can.

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
   PART B — POINT-IN-TIME AGGREGATION & RANKING
   =========================================================================
   Once fact_call_clean is reliable, the original reporting need was:
   "as of right now, how is each agent performing against their team
   today, this week, and trending?" These are the queries managers ran
   every morning — previously assembled by hand in Excel from multiple
   exports, now returned in milliseconds.
   ========================================================================= */

/* --- B1: Daily agent scorecard with rank-within-manager-team ---
   For each agent/day, total calls handled, average handle time, and
   resolution rate — plus that agent's RANK among peers under the same
   manager for that day, by call volume. This is the "point-in-time"
   ranking: it's always relative to a specific call_date, not a
   running total, so a manager pulling this for "yesterday" gets an
   honest day-over-day comparison instead of a number drifting with
   cumulative history. */
SELECT
    fc.call_date,
    a.manager_id,
    m.manager_name,
    fc.agent_num,
    a.agent_name,
    COUNT(*)                                         AS calls_handled,
    AVG(fc.duration_sec)                             AS avg_handle_time_sec,
    SUM(CASE WHEN fc.resolved_flag = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(*)                                   AS resolution_rate,
    RANK() OVER (
        PARTITION BY fc.call_date, a.manager_id
        ORDER BY COUNT(*) DESC
    )                                                 AS rank_within_team_by_volume,
    RANK() OVER (
        PARTITION BY fc.call_date, a.manager_id
        ORDER BY AVG(fc.duration_sec) ASC
    )                                                 AS rank_within_team_by_speed
FROM callcenter.fact_call_clean fc
JOIN callcenter.dim_agent a ON a.agent_num = fc.agent_num
LEFT JOIN callcenter.dim_manager m ON m.manager_id = a.manager_id
GROUP BY fc.call_date, a.manager_id, m.manager_name, fc.agent_num, a.agent_name
ORDER BY fc.call_date, a.manager_id, rank_within_team_by_volume;
GO


/* --- B2: 7-day rolling average handle time per agent ---
   A windowed moving average using a frame clause (RANGE/ROWS BETWEEN),
   distinct from the ranking window functions above. This is the kind of
   trend metric that's painful to compute correctly by hand in Excel
   (easy to get the window boundaries wrong) and trivial in SQL once the
   data is clean. */
WITH daily_agent_stats AS (
    SELECT
        agent_num,
        call_date,
        AVG(duration_sec) AS daily_avg_handle_time
    FROM callcenter.fact_call_clean
    GROUP BY agent_num, call_date
)
SELECT
    agent_num,
    call_date,
    daily_avg_handle_time,
    AVG(daily_avg_handle_time) OVER (
        PARTITION BY agent_num
        ORDER BY call_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS rolling_7day_avg_handle_time
FROM daily_agent_stats
ORDER BY agent_num, call_date;
GO


/* --- B3: Manager-level team rollup with senior-manager comparison ---
   Aggregates up one more level: each manager's team totals for the day,
   plus that manager's RANK among all managers — the number the senior
   manager (D. Whitfield) actually looked at each morning. */
SELECT
    fc.call_date,
    m.manager_id,
    m.manager_name,
    COUNT(*)                                          AS team_calls_handled,
    COUNT(DISTINCT fc.agent_num)                       AS active_agents,
    AVG(fc.duration_sec)                               AS team_avg_handle_time_sec,
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


/* --- B4: Data quality surface — unmapped agents, never silently dropped ---
   Call volume attributed to agents missing from the org chart export.
   This is run alongside the manager rollups so unmapped volume is visible
   as its own line item rather than vanishing from totals. */
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
