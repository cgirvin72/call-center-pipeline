# QA & Data Validation Log

## Purpose

Before this pipeline's output fed the reporting layer, each data source was validated against the source system's expected structure and business logic. This log documents what was found during that validation pass: the root cause behind the issue, the downstream impact if it had gone unresolved, and how it was addressed.

The intent is not to catalog every anomaly found. It is to show the reasoning behind why one issue mattered before it reached a stakeholder-facing dashboard.

## Log Format

| ID | Issue | Pipeline Stage | Root Cause | Data Impact if Unresolved | Resolution | Status |
|----|-------|-----------------|------------|----------------------------|------------|--------|

**Column definitions:**
- **ID** — Sequential identifier for traceability back to commits and notes.
- **Issue** — One-line description of what was observed.
- **Pipeline Stage** — Where in the flow it surfaced: Extract, Transform, Load, or Reporting Layer.
- **Root Cause** — The mechanism behind the issue, not just the symptom.
- **Data Impact if Unresolved** — Stated in business terms: what metric would have been wrong, and in what direction.
- **Resolution** — What was changed to fix it.
- **Status** — Resolved, Open, or Monitoring.

## Entries

| ID | Issue | Pipeline Stage | Root Cause | Data Impact if Unresolved | Resolution | Status |
|----|-------|-----------------|------------|----------------------------|------------|--------|
| QA-001 | Four agent IDs returned zero on the Agents Affected calculated field while total Calls Handled counted them correctly | Reporting Layer | The org-chart reference table used to assign agents to managers was not updated after a round of team transfers, leaving those agent IDs without a current manager assignment | Roughly 1,100 calls, 90 to 134 per day, present in every business day of the review window, would have been silently excluded from manager-level rollups. This understates team volume every day, not as a one-time anomaly | Flagged the affected records as `UNMAPPED_ORG_CHART_GAP` instead of dropping them through the join, and surfaced the flag as its own line item in the reporting layer so the gap stays visible | Resolved |

This finding is the reason the synthetic dataset in this repository is built with 4 of 103 agents missing a current manager assignment. See [`docs/METHODOLOGY.md`](METHODOLOGY.md), section "Validating the Logic," for how the pipeline surfaces this gap instead of dropping the records silently.
