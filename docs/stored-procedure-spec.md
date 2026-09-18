# Stored Procedure Spec: `callcenter.usp_load_clean_calls`

One-page reference for the daily load procedure in `sql/04_load_clean_calls_proc.sql`.
Written to be read before the code, and to be the outline of how I'd describe the
object in an interview.

---

## Purpose and trigger

Loads one call date from `callcenter.stg_call_raw` into `callcenter.fact_call`,
applying the deduplication rule that decides which version of a call is true.

Called by the nightly scheduler after the Python ETL finishes staging, one call
per date. Also called by hand to reprocess a date after a late QA correction.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `@call_date` | DATE | none, required | The single date to load. Scopes every statement in the procedure. |
| `@debug` | BIT | 0 | 1 returns the row counts and the reject rows instead of running silently. |

---

## Why a procedure and not a view

A view returns a shape. This object does four things a view cannot: it deletes and
reinserts a date range, writes to a reject table, writes to a run log, and wraps
all of it in one transaction so a partial load cannot survive. Multiple statements,
a write, and transaction control are the test. If those three were absent, the dedup
logic would stay a view and the scheduler would insert from it.

The `SELECT` half of the work is genuinely a view. The procedure exists for the
parts around it.

---

## Idempotency

Re-running the same date is safe, and is the normal way a late correction gets
applied.

The procedure deletes `fact_call` and `fact_call_reject` rows for `@call_date`
before inserting, inside the same transaction. A rerun replaces the day rather than
doubling it. Nothing outside `@call_date` is touched, so reprocessing one day never
disturbs another.

The delete-then-insert pattern is chosen over `MERGE` deliberately: the grain is a
whole date, the volume per date is small, and `MERGE` carries enough known edge-case
behavior that it is not worth it for a load this shape.

---

## The two rules the procedure enforces

**Newest version wins.** `ROW_NUMBER() OVER (PARTITION BY call_ref ORDER BY load_ts DESC)`,
keep rank 1. Duplicates in this pipeline are not identical rows, they are competing
versions of the same call: an enterprise export and a regional export covering the
same call, or a QA correction re-exported days later against the same call
identifier. `DISTINCT` or `GROUP BY` with an arbitrary aggregate would pick a
version arbitrarily. This picks the current one.

**Unmapped agents are rejected, never dropped.** Winning rows with no current row in
`dim_agent` are written to `fact_call_reject` with reason `UNMAPPED_ORG_CHART_GAP`
and counted. An `INNER JOIN` alone would remove their call volume from team totals
with no error raised. Nothing fails, the total just comes back low, and the manager
reading it concludes their team is underperforming when the real problem is a stale
org-chart export.

---

## Error handling and logging

Every execution writes a row to `callcenter.etl_run_log` at start and updates it at
the end: status, rows staged, rows deduplicated, rows loaded, rows rejected, and on
failure the error number and message.

`SET XACT_ABORT ON` plus `TRY/CATCH` with an explicit `ROLLBACK`, then `THROW` to
re-raise. The re-raise matters. A procedure that swallows its own error reports
success to the scheduler and leaves a missing day nobody looks for.

---

## Reconciliation gate

Before committing, the procedure checks that winning rows equal loaded rows plus
rejected rows. If they do not, it throws and the transaction rolls back.

This is the difference between a load that ran and a load that is correct. Without
it, a join problem produces a short day that looks exactly like a slow day.

---

## How it is tested

1. **Independent duplication.** The same "keep the newest version" rule is
   implemented in the Python ETL (`scripts/etl_pipeline.py`) and logged there. The
   SQL and the Python are trusted only when they produce identical counts against
   the same dataset.
2. **Rerun test.** Run a date twice, confirm `fact_call` row counts are unchanged.
3. **Correction test.** Stage a QA correction with a later `load_ts`, rerun the
   date, confirm the corrected duration is what survives.
4. **Reject test.** Remove an agent from `dim_agent`, rerun, confirm those calls
   appear in `fact_call_reject` and that loaded plus rejected still reconciles.

---

## Object names

Names follow `sql/01_schema.sql`. `dim_agent` is assumed to carry `agent_key`,
`agent_num`, and `is_current`. If the schema in use differs, change the names in
the procedure rather than in the calling job.
