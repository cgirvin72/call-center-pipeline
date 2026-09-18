# Call Center Reporting Consolidation

A Python + SQL Server data pipeline rebuilding the architecture I designed at Aventiv Technologies to consolidate 20+ legacy Access databases into a single, reliable reporting backend for a ~100-agent call center operation.

**Read the full story in [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md).**

## Quick Facts

- **Problem:** Daily manager reporting took ~2.5 hours of manual Excel reconciliation across 20+ overlapping, inconsistently-formatted legacy database exports.
- **Solution:** A Python extraction/standardization layer feeding a SQL Server backend, where window functions handle deduplication and point-in-time ranking/aggregation. Tableau and Power BI connect to the clean output as the reporting layer.
- **Outcome:** Reporting lag cut from 2.5 hours to under 10 minutes.

## Data Disclosure

All data in `source_data/` is synthetically generated for portfolio demonstration. No real call records, agent names, or proprietary system data are used or represented. See `scripts/generate_legacy_sources.py` for full generation logic and `docs/METHODOLOGY.md` for the complete disclosure statement.

## Synthetic Data Design

Per-agent performance, resolution rate and average handle time, is generated from a persistent, agent-specific tendency rather than a single flat rate applied to everyone. Each agent's tendency is drawn once from an independent random stream, separate from the stream driving the rest of the generator, so it does not disturb any of the pipeline validation counts documented in `docs/METHODOLOGY.md`. Without this, every agent's numbers regress to the same population mean once averaged across the window, and a dashboard built to surface a coaching outlier or an efficiency pattern has nothing real to find. See `docs/METHODOLOGY.md` for the full explanation and `scripts/generate_legacy_sources.py` for the implementation.

## The Scheduled Load

`sql/02_dedup_and_aggregation.sql` shows the deduplication logic as a standalone statement, which is how the technique reads most clearly. `sql/07_load_clean_calls_proc.sql` is how it actually runs: a date-scoped stored procedure that can be re-run safely after a late correction, captures the rows the standalone insert would have discarded without a count, refuses to commit a load that does not reconcile, and logs every run.

**Read [`docs/stored-procedure-spec.md`](docs/stored-procedure-spec.md)** for the design decisions: why a procedure rather than a view, how idempotency works, and the difference between a reject and a data-quality gap.

## Proving the Numbers Agree

`sql/05_reconciliation.sql` returns the SQL-side value for every metric that also exists as a DAX measure in `powerbi/measures.dax`. Run both at the same grain with the same filters and compare. Findings are recorded in [`docs/reconciliation-findings.md`](docs/reconciliation-findings.md).

The two checks in this repo cover different failure modes. The procedure's reconciliation gate runs before commit, per date, and blocks a bad load from landing. The reconciliation harness runs after the fact, across the whole table, and proves the consumption layers agree with the warehouse.

## Repository Structure

```
project3/
├── docs/
│   ├── METHODOLOGY.md                # Full write-up: problem, architecture, technique, outcome
│   ├── qa-validation.md              # QA validation log: issue, root cause, data impact, resolution
│   ├── reconciliation-findings.md    # SQL vs DAX comparison results and findings
│   ├── stored-procedure-spec.md      # Design reference for the scheduled load procedure
│   └── stakeholder-deck/             # Same findings presented to a non-technical audience
├── powerbi/
│   └── measures.dax                  # DAX measures reconciled against sql/05_reconciliation.sql
├── scripts/
│   ├── generate_legacy_sources.py    # Builds 6 synthetic "legacy export" CSVs
│   └── etl_pipeline.py               # Python extraction + standardization + staging export
├── sql/
│   ├── 01_schema.sql                 # SQL Server table definitions
│   ├── 02_dedup_and_aggregation.sql  # Reference: the dedup technique and reporting queries
│   ├── 03_views_for_tableau.sql      # Views exposed to the Tableau consumption layer
│   ├── 04_dim_date.sql               # Date dimension for the Power BI semantic layer
│   ├── 05_reconciliation.sql         # Proof harness: SQL values against the DAX measures
│   ├── 06_bulk_load_staging.sql      # BULK INSERT the staged CSV into stg_call_raw
│   └── 07_load_clean_calls_proc.sql  # Scheduled load procedure: idempotent, logged, reconciled
└── source_data/
    ├── legacy_export_*.csv           # Synthetic messy source files
    └── clean/
        ├── stg_call_raw.csv          # Unioned, standardized, pre-dedup. Input to the SQL load
        ├── fact_call_clean.csv       # Python ETL output: clean, deduplicated, enriched
        └── dim_manager.csv
```

## Running It

```bash
# 1. Generate synthetic legacy source data
python scripts/generate_legacy_sources.py

# 2. Run the Python ETL: standardize, stage, deduplicate, enrich, validate
python scripts/etl_pipeline.py
```

Step 2 writes `source_data/clean/stg_call_raw.csv`, the unioned pre-deduplication set that the SQL layer deduplicates independently. Keeping both implementations against the same input is what makes the two sets of counts a real check rather than a restatement.

Then in SQL Server, run the files in this order. **File numbers are historical and do not match run order.**

```
sql/01_schema.sql                 -- tables. Drops and recreates, so rebuild only
sql/06_bulk_load_staging.sql      -- BULK INSERT stg_call_raw.csv into callcenter.stg_call_raw
sql/07_load_clean_calls_proc.sql  -- creates the load procedure, the reject table, and the run log
sql/03_views_for_tableau.sql      -- Tableau-facing views
sql/04_dim_date.sql               -- date dimension. Reads fact_call_clean, so it runs after the load
sql/05_reconciliation.sql         -- proof harness. Run last
```

`06_bulk_load_staging.sql` reads the CSV from the SQL Server's own filesystem. Against a container, copy it in first:

```
docker cp source_data/clean/stg_call_raw.csv <container>:/tmp/stg_call_raw.csv
```

Load the fact table one date at a time:

```sql
DECLARE @d DATE = (SELECT MIN(call_date) FROM callcenter.stg_call_raw);
WHILE @d <= (SELECT MAX(call_date) FROM callcenter.stg_call_raw)
BEGIN
    EXEC callcenter.usp_load_clean_calls @call_date = @d;
    SET @d = DATEADD(DAY, 1, @d);
END;

SELECT * FROM callcenter.etl_run_log ORDER BY run_id;
```

`02_dedup_and_aggregation.sql` is a reference file rather than a run step. Part A shows the dedup logic as a single statement, Part B holds the reporting queries the views are built from. The procedure in `07` is what runs on a schedule.

## Tech Stack

Python (csv, no external dependencies by design — easy to audit) · SQL Server (T-SQL window functions, stored procedures) · Tableau and Power BI (consumption layers, not built in this repo — see methodology note)
