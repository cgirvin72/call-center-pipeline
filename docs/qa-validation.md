# QA & Data Validation Log

## Purpose

Before this pipeline's output was used to build the reporting layer, each data
source was validated against the source system's expected structure and
business logic. This log documents the issues found during that validation
pass, their root cause, the downstream impact if they'd gone unresolved, and
how each was addressed.

The intent isn't just to catch broken data — it's to show the reasoning behind
*why* an issue mattered before it reached a stakeholder-facing dashboard.

## Log Format

| ID | Issue | Pipeline Stage | Root Cause | Data Impact if Unresolved | Resolution | Status |
|----|-------|-----------------|------------|----------------------------|------------|--------|
| QA-001 | | | | | | |

**Column definitions:**
- **ID** — Sequential identifier (QA-001, QA-002...) for traceability back to commits/notes.
- **Issue** — One-line description of what was observed (a count that didn't reconcile, a null spike, a duplicate key).
- **Pipeline Stage** — Where in the flow it surfaced: Extract / Transform / Load / Reporting Layer.
- **Root Cause** — The actual mechanism, not just the symptom (e.g., "join on a non-unique key" rather than "duplicates appeared").
- **Data Impact if Unresolved** — Stated in business terms: what metric would have been wrong, and by roughly how much or in what direction.
- **Resolution** — What was changed (dedup logic, null-handling rule, join key fix, etc.).
- **Status** — Resolved / Open / Monitoring.

## Example Entries

| ID | Issue | Pipeline Stage | Root Cause | Data Impact if Unresolved | Resolution | Status |
|----|-------|-----------------|------------|----------------------------|------------|--------|
| QA-001 | Duplicate call records for a subset of interactions | Extract | Source system logs a new record on both call transfer and call resolution, not just resolution | Call volume metrics would be overcounted, inflating agent workload and call-per-hour figures | Deduplicated on interaction ID + timestamp window before load; kept the resolution-stage record as source of truth | Resolved |
| QA-002 | Null values in agent ID field for ~3% of records | Transform | Records created during a system handoff window weren't tagged with an agent ID at time of capture | Agent-level performance dashboards would silently exclude these interactions rather than flag them, understating true volume per agent | Added an "Unassigned/System Handoff" category instead of dropping nulls, and flagged the % in the methodology doc so it's visible rather than hidden | Resolved |
| QA-003 | Call duration field stored in two different units depending on source subsystem | Extract | Legacy subsystem logged duration in seconds; newer subsystem logged in minutes, no unit flag in the raw export | Average handle time would be wildly skewed for records from the legacy subsystem — some calls would appear to be 60x longer than actual | Added a unit-detection rule based on source subsystem tag, normalized all durations to seconds before load | Resolved |
| QA-004 | Reporting-layer date filter used calendar date instead of business date, causing a shift-boundary mismatch | Reporting Layer | Calls placed after midnight but before shift end were attributed to the wrong day, splitting a single shift's volume across two reporting days | Daily volume trends would show an artificial dip/spike pattern at shift boundaries, undermining trend analysis | Introduced a "business date" field driven by shift start/end logic rather than calendar midnight | Resolved |

## Notes for Adapting This Log

- Keep entries in business-impact terms, not just technical terms — a hiring manager skimming this should immediately understand *why* each issue mattered, not just that it existed.
- Order roughly by pipeline stage (Extract → Transform → Load → Reporting) so the log reads as a narrative of the build, not a random bug list.
- If you want to make this a living document rather than a fixed snapshot, add a "Date Found" column and keep the most recent entries at the top.
