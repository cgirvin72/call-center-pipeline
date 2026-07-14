# Call Center Reporting Consolidation
### Methodology Note — Python ETL + SQL Server Window Functions + Tableau

---

## Disclosure

This project rebuilds the **architecture and logic** of a data pipeline I designed and built during my time at Aventiv Technologies. No original code, files, or proprietary data survive from that engagement — this repository is a from-scratch reconstruction based on my own description of how the system worked. All data in `source_data/` is **synthetically generated** (see `generate_legacy_sources.py`); no real call records, agent names, or customer information are used or represented anywhere in this repository.

What's real: the problem, the architecture, the technique, and the outcome. What's synthetic: the data and the literal code (rewritten from scratch, not recovered from any original source).

---

## The Problem

A call center operation — roughly 100 agents organized under 4 regional managers and one senior manager — needed daily visibility into call volume, average handle time (AHT), and resolution rates, sliced by agent and by team. The data existed, but it lived across **more than 20 separate Microsoft Access databases**, each maintained by a different regional system with no shared schema discipline.

Three specific failure patterns made this worse than a simple "too many files" problem:

1. **Overlapping coverage.** An enterprise-wide nightly export covered every team, while regional exports also covered their own subset. The same call could legitimately appear in two or three different source files.
2. **Late corrections.** QA review periodically corrected handle-time entries days after a call was logged, re-exporting the same call record with a new value and a new export timestamp — but the same call identifier.
3. **Inconsistent identifiers.** Agent IDs were stored as free text across systems — `"A1042"` in one export, `"1042"` in another, `"AGT-1042"` in a third. Nothing enforced a canonical format.

The manual process to produce a daily manager report took roughly **2.5 hours**: pulling each Access export, opening them in Excel, manually reconciling overlaps by eye, and rebuilding pivot tables from scratch every morning. It was slow, error-prone, and entirely dependent on one person doing it the same way every time.

---

## The Architecture

```
Legacy Access Exports (20+ sources)
        │
        ▼
  Python ETL Layer  ──  extraction + standardization only
        │                (no report/dashboard generation here)
        ▼
  SQL Server  ──  staging table → window-function dedup → clean fact table
        │            (this is where deduplication and point-in-time
        │             ranking/aggregation actually happen)
        ▼
  Tableau  ──  connects directly to clean SQL Server views
               (this is the only layer that builds dashboards)
```

**A deliberate division of labor, and why it matters:**

- **Python's job ends at producing trustworthy, query-ready data.** It extracts, standardizes agent ID formats, and stages records for load. It does not aggregate, rank, or generate any visual output.
- **SQL Server's window functions do the heavy analytical lifting** — both the deduplication logic and the point-in-time aggregation/ranking managers actually look at. This keeps the expensive set-based logic where the database engine is best at it, rather than looping through rows in application code.
- **Tableau is the only consumption layer.** It connects to pre-aggregated SQL Server views, so dashboards stay fast and dashboard authors never have to re-implement business logic in calculated fields.

This separation is the difference between a fragile script that "does everything" and a pipeline where each layer has exactly one job and can be debugged, tested, and replaced independently.

---

## The Technique: Window Functions for Deduplication

The standard approach to deduplication — `SELECT DISTINCT` or `GROUP BY` with an arbitrary aggregate — fails here because **"duplicate" records aren't identical; they're competing versions of the truth**, and only the most recently loaded version should win.

The fix is `ROW_NUMBER()` partitioned by the natural key, ordered by load timestamp:

```sql
WITH ranked_versions AS (
    SELECT
        call_ref,
        agent_num,
        duration_sec,
        load_ts,
        source_system,
        ROW_NUMBER() OVER (
            PARTITION BY call_ref
            ORDER BY load_ts DESC
        ) AS version_rank
    FROM callcenter.stg_call_raw
)
SELECT * FROM ranked_versions WHERE version_rank = 1;
```

Every version of a given call gets ranked from newest to oldest within its own partition. Rank 1 is always the correct version to keep — whether that's because three sources independently exported the same call (in which case any of them is fine, since the data agrees) or because a QA correction superseded the original (in which case the corrected value is rank 1 and the original drops out).

This same pattern extends naturally to point-in-time reporting once the data is clean:

```sql
RANK() OVER (
    PARTITION BY call_date, manager_id
    ORDER BY COUNT(*) DESC
) AS rank_within_team_by_volume
```

— which answers "how did this agent rank against their teammates, on this specific day" without needing a separate query per day or per manager. The same window-function vocabulary that solved deduplication also solved the ranking and rolling-average reporting the managers actually used every morning.

---

## Validating the Logic

Before this logic ever touches a database, the Python ETL script (`etl_pipeline.py`) implements the identical "keep the most recent version" rule in plain Python and logs the results:

```
Unioned 58,160 total rows across all call sources before dedup
Deduplication resolved 29,296 overlapping/duplicate records
Final clean record count: 28,864
  source 'enterprise' contributed the winning version for 28,432 calls
  source 'qa_corrections' contributed the winning version for 432 calls
```

The SQL Server window-function logic (`02_dedup_and_aggregation.sql`) was independently validated against the same synthetic dataset and produced **the exact same counts** — confirming the production SQL logic and the Python prototype agree before either one is trusted with real reporting.

A separate validation step also confirmed that **agents missing from the org-chart reference table are never silently dropped.** In the synthetic dataset, 4 of 103 agents had no current manager assignment (simulating a stale HR export after a team transfer). Rather than excluding their call volume from totals — which would quietly understate team performance without anyone noticing — those records are flagged `UNMAPPED_ORG_CHART_GAP` and surfaced as their own data-quality line item. This was a real lesson from the original system: a silent `INNER JOIN` against an incomplete reference table is a bug that doesn't announce itself until someone notices the numbers don't add up.

---

## Modeling Realistic Agent Variation

An earlier version of this dataset drew every call's resolution outcome and handle time from a single population-wide distribution, independent of which agent handled it. That is a reasonable first pass, but it has a quiet flaw: once averaged across roughly 280 calls per agent over the two-week window, the law of large numbers erases almost all of the spread. Every agent's resolution rate landed within about a point and a half of the same 93 percent mean, and every agent's average handle time landed within about eight seconds of the same value. A dashboard built to find a coaching opportunity or an efficiency outlier has nothing real to surface against noise that tight.

The fix: each agent now carries a persistent `resolution_skill` and `speed_skill`, drawn once at roster-generation time from an independent random stream (`random.Random(1042)`, separate from the shared `random.seed(42)` stream used everywhere else in the generator). Individual calls are still random around that agent's own tendency, so no single call is deterministic, but the agent's underlying tendency now persists across their full call volume instead of resetting with every call.

Because the skill values are drawn from a fully separate random stream, they consume zero draws from the shared sequence that produces the source overlaps, the QA correction sample, and the orphaned-agent selection. Every dedup and validation count documented above, 58,160 unioned rows, 29,296 deduplicated, 4 of 103 agents unmapped, is unaffected. Only the resolution and handle-time values changed: resolution rate spread grew from roughly a point and a half to about six points across agents, and handle-time spread grew by roughly a factor of ten, which is what makes the agent-level Tableau views actually worth building.

---

## The Outcome

| | Before | After |
|---|---|---|
| Time to produce daily manager report | ~2.5 hours, manual | Under 10 minutes, scheduled |
| Reconciliation method | Manual visual comparison in Excel | Deterministic SQL window-function logic |
| Agent ID handling | Inconsistent across sources, manually corrected | Normalized at ingestion, single canonical ID |
| Missing org-chart records | Silently dropped from totals | Flagged and surfaced as a data-quality metric |
| Dashboard refresh | Rebuilt from scratch each morning | Tableau auto-refreshes against live SQL Server views |

The original system served daily metrics — calls handled, average handle time, resolution rate — for roughly 100 agents under 4 managers and 1 senior manager, every morning, without manual reconciliation.

---

## Repository Contents

| File | Purpose |
|---|---|
| `scripts/generate_legacy_sources.py` | Generates the 6 synthetic "legacy export" CSVs used as input |
| `scripts/etl_pipeline.py` | Python extraction + standardization + Python-side dedup validation |
| `sql/01_schema.sql` | SQL Server table definitions (staging, dimensions, clean fact table) |
| `sql/02_dedup_and_aggregation.sql` | Window-function deduplication + ranking/aggregation queries |
| `sql/03_views_for_tableau.sql` | Views exposed to the Tableau consumption layer |
| `source_data/` | Synthetic "legacy" CSV exports (generated, not real) |
| `source_data/clean/` | Output of the Python ETL run — clean, deduplicated, enriched data |
