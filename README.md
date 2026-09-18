# Call Center Reporting Consolidation

A Python + SQL Server data pipeline rebuilding the architecture I designed at Aventiv Technologies to consolidate 20+ legacy Access databases into a single, reliable reporting backend for a ~100-agent call center operation.

**Read the full story in [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md).**

## Quick Facts

- **Problem:** Daily manager reporting took ~2.5 hours of manual Excel reconciliation across 20+ overlapping, inconsistently-formatted legacy database exports.
- **Solution:** A Python extraction/standardization layer feeding a SQL Server backend, where window functions handle deduplication and point-in-time ranking/aggregation. Tableau connects directly to the clean output as the sole reporting/dashboard layer.
- **Outcome:** Reporting lag cut from 2.5 hours to under 10 minutes.

## Data Disclosure

All data in `source_data/` is synthetically generated for portfolio demonstration. No real call records, agent names, or proprietary system data are used or represented. See `scripts/generate_legacy_sources.py` for full generation logic and `docs/METHODOLOGY.md` for the complete disclosure statement.

## Synthetic Data Design

Per-agent performance, resolution rate and average handle time, is generated from a persistent, agent-specific tendency rather than a single flat rate applied to everyone. Each agent's tendency is drawn once from an independent random stream, separate from the stream driving the rest of the generator, so it does not disturb any of the pipeline validation counts documented in `docs/METHODOLOGY.md`. Without this, every agent's numbers regress to the same population mean once averaged across the window, and a dashboard built to surface a coaching outlier or an efficiency pattern has nothing real to find. See `docs/METHODOLOGY.md` for the full explanation and `scripts/generate_legacy_sources.py` for the implementation.

## The Scheduled Load

`sql/02_dedup_and_aggregation.sql` shows the deduplication logic as a standalone statement, which is how the technique reads most clearly. `sql/04_load_clean_calls_proc.sql` is how it actually runs: a date-scoped stored procedure that can be re-run safely after a late correction, captures the rows the standalone insert would have discarded without a count, refuses to commit a load that does not reconcile, and logs every run.

**Read [`docs/stored-procedure-spec.md`](docs/stored-procedure-spec.md)** for the design decisions: why a procedure rather than a view, how idempotency works, and the difference between a reject and a data-quality gap.

## Repository Structure

```
project3/
├── docs/
│   ├── METHODOLOGY.md               # Full write-up: problem, architecture, technique, outcome
│   ├── qa-validation.md             # QA validation log: issue, root cause, data impact, resolution
│   ├── stored-procedure-spec.md     # Design reference for the scheduled load procedure
│   └── stakeholder-deck/            # Same findings presented to a non-technical audience
├── scripts/
│   ├── generate_legacy_sources.py   # Builds 6 synthetic "legacy export" CSVs
│   └── etl_pipeline.py              # Python extraction + standardization layer
├── sql/
│   ├── 01_schema.sql                     # SQL Server table definitions
│   ├── 02_dedup_and_aggregation.sql      # Window-function dedup + ranking/aggregation
│   ├── 03_views_for_tableau.sql          # Views exposed to the Tableau consumption layer
│   └── 04_load_clean_calls_proc.sql      # Scheduled load procedure: idempotent, logged, reconciled
└── source_data/
    ├── legacy_export_*.csv          # Synthetic messy source files
    └── clean/
        ├── fact_call_clean.csv      # Python ETL output: clean, deduplicated, enriched
        └── dim_manager.csv
```

## Running It

```bash
# 1. Generate synthetic legacy source data
python scripts/generate_legacy_sources.py

# 2. Run the Python ETL layer (extraction + standardization + dedup validation)
python scripts/etl_pipeline.py
```

Then in SQL Server, load the ETL output into `callcenter.stg_call_raw` and run:

```
sql/01_schema.sql        -- tables (drops and recreates; run first, and only on a rebuild)
sql/04_load_clean_calls_proc.sql   -- creates the load procedure, the reject table, and the run log
sql/03_views_for_tableau.sql       -- Tableau-facing views
```

Then load a date:

```sql
EXEC callcenter.usp_load_clean_calls @call_date = '2026-03-14', @debug = 1;
```

`02_dedup_and_aggregation.sql` is a reference file. Part A shows the dedup logic as a single statement, Part B holds the reporting queries the views are built from. The procedure in `04` is what runs on a schedule.

## Tech Stack

Python (csv, no external dependencies by design — easy to audit) · SQL Server (T-SQL window functions, stored procedures) · Tableau (consumption layer, not built in this repo — see methodology note)
