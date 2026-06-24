# Call Center Reporting Consolidation

A Python + SQL Server data pipeline rebuilding the architecture I designed at Aventiv Technologies to consolidate 20+ legacy Access databases into a single, reliable reporting backend for a ~100-agent call center operation.

**Read the full story in [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md).**

## Quick Facts

- **Problem:** Daily manager reporting took ~2.5 hours of manual Excel reconciliation across 20+ overlapping, inconsistently-formatted legacy database exports.
- **Solution:** A Python extraction/standardization layer feeding a SQL Server backend, where window functions handle deduplication and point-in-time ranking/aggregation. Tableau connects directly to the clean output as the sole reporting/dashboard layer.
- **Outcome:** Reporting lag cut from 2.5 hours to under 10 minutes.

## Data Disclosure

All data in `source_data/` is synthetically generated for portfolio demonstration. No real call records, agent names, or proprietary system data are used or represented. See `scripts/generate_legacy_sources.py` for full generation logic and `docs/METHODOLOGY.md` for the complete disclosure statement.

## Repository Structure

```
project3/
├── docs/
│   └── METHODOLOGY.md          # Full write-up: problem, architecture, technique, outcome
├── scripts/
│   ├── generate_legacy_sources.py   # Builds 6 synthetic "legacy export" CSVs
│   └── etl_pipeline.py              # Python extraction + standardization layer
├── sql/
│   ├── 01_schema.sql                # SQL Server table definitions
│   ├── 02_dedup_and_aggregation.sql # Window-function dedup + ranking/aggregation
│   └── 03_views_for_tableau.sql     # Views exposed to the Tableau consumption layer
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

# 3. Load output into SQL Server, then run:
#    sql/01_schema.sql  -> sql/02_dedup_and_aggregation.sql -> sql/03_views_for_tableau.sql
```

## Tech Stack

Python (csv, no external dependencies by design — easy to audit) · SQL Server (T-SQL window functions) · Tableau (consumption layer, not built in this repo — see methodology note)
