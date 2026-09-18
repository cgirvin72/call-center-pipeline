"""
etl_pipeline.py

Python ETL layer for the Call Center Reporting Consolidation project.

SCOPE NOTE: This script handles EXTRACTION and TRANSFORMATION only. It reads
the messy legacy exports, standardizes and deduplicates them, and writes
clean, query-ready data for SQL Server. It does NOT generate reports or
dashboards — that consumption layer was built in Tableau, connecting
directly to the cleaned SQL Server tables this script produces. Python's
job ends the moment trustworthy data is ready for the warehouse.

REAL-WORLD CONTEXT: This rebuilds the architecture used to consolidate 20+
legacy Access databases into a single SQL Server backend for a call center
operation (~100 agents, 4 managers, 1 senior manager). The original process
cut reporting lag from 2.5 hours (manual exports + Excel reconciliation) to
under 10 minutes (scheduled ETL run). This version uses synthetic data; see
README.md for the data disclosure statement.

PIPELINE STAGES:
  1. EXTRACT  - read all legacy CSV exports into memory
  2. STANDARDIZE - normalize inconsistent agent ID formats across sources
  3. CONSOLIDATE - union all call records into one working set
  4. STAGE - write the unioned, pre-dedup set for BULK INSERT into
     callcenter.stg_call_raw (see sql/05_bulk_load_staging.sql)
  5. DEDUPLICATE - resolve the overlap problem (same call in multiple
     sources) by keeping the most recently loaded version of each call
  6. ENRICH - join against the org-chart side table to attach manager
     assignment, handling agents missing from that export
  7. VALIDATE - run data quality checks and log results
  8. LOAD - write the clean, query-ready tables out

The staging file in stage 4 is what the SQL Server window-function layer
deduplicates independently. Keeping both implementations against the same
input is what makes the two sets of counts a real check rather than a
restatement.

USAGE:
    python scripts/etl_pipeline.py
"""

import csv
import logging
import os
import re
from collections import defaultdict
from datetime import datetime

# Resolved relative to this file so the pipeline runs from any working
# directory and on any machine.
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(PROJECT_ROOT, "source_data")
OUTPUT_DIR = os.path.join(SOURCE_DIR, "clean")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("etl")


# =========================================================================
# STAGE 1: EXTRACT
# =========================================================================

def read_csv(filename):
    path = os.path.join(SOURCE_DIR, filename)
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def extract_all_sources():
    """Pull every legacy export into memory. Each source is tagged with its
    origin so downstream dedup logic can report which source 'won' for a
    given call — useful for an audit trail."""
    sources = {
        "north_east": read_csv("legacy_export_north_east_calls.csv"),
        "west_south": read_csv("legacy_export_west_south_calls.csv"),
        "enterprise": read_csv("legacy_export_enterprise_calls.csv"),
        "qa_corrections": read_csv("legacy_export_qa_corrections.csv"),
    }
    org_chart = read_csv("legacy_export_org_chart.csv")
    manager_ref = read_csv("legacy_export_manager_reference.csv")

    for name, rows in sources.items():
        log.info(f"Extracted {len(rows):>6} rows from source '{name}'")
    log.info(f"Extracted {len(org_chart):>6} rows from org chart reference")
    log.info(f"Extracted {len(manager_ref):>6} rows from manager reference")

    return sources, org_chart, manager_ref


# =========================================================================
# STAGE 2: STANDARDIZE
# =========================================================================

AGENT_ID_PATTERN = re.compile(r"(\d+)")


def normalize_agent_id(raw_id):
    """
    Legacy sources format agent IDs inconsistently:
      "A1042"     (Source 1)
      "1042"      (Source 2)
      "AGT-1042"  (Source 3)
      "A001042"   (Source 4, zero-padded)
    All of these refer to the same underlying agent number. Strip
    non-numeric characters and leading zeros to get a canonical integer ID.
    """
    match = AGENT_ID_PATTERN.search(raw_id)
    if not match:
        return None
    return int(match.group(1))


def standardize_source(rows, source_name):
    """
    Normalize agent IDs and coerce types. Returns a consistent schema
    regardless of which legacy source a row came from.

    Returns two lists: rows that standardized cleanly, and rows whose agent
    identifier could not be resolved to a canonical number.

    The second list is not an error bucket to be discarded. A row with an
    unresolvable agent ID is still a real call that really happened, and
    dropping it here removes its volume from every downstream total with
    nothing to show that it existed. It goes to staging with a null
    agent_num, where the SQL load procedure captures it as
    AGENT_ID_NOT_NORMALIZED and counts it. The clean path still excludes
    it, because a call that cannot be attributed to an agent cannot be
    attributed to a manager either.
    """
    standardized = []
    unresolved = []
    malformed = 0

    for row in rows:
        try:
            agent_num = normalize_agent_id(row["AgentID"])
            record = {
                "call_ref": row["CallRef"],
                "agent_id_raw": row["AgentID"],
                "agent_num": agent_num,
                "call_date": row["CallDate"],
                "start_ts": row["StartTime"],
                "duration_sec": int(row["DurationSec"]),
                "reason": row["Reason"].strip() if row["Reason"] else None,
                "resolved": bool(int(row["Resolved"])),
                "load_ts": row["LoadTimestamp"],
                "source": source_name,
            }
        except (ValueError, KeyError) as e:
            malformed += 1
            log.warning(f"Skipped malformed row in '{source_name}': {e}")
            continue

        if agent_num is None:
            unresolved.append(record)
        else:
            standardized.append(record)

    if unresolved:
        log.warning(
            f"Source '{source_name}': {len(unresolved)} row(s) had an unresolvable "
            f"agent identifier. Staged with a null agent_num, excluded from the clean path."
        )
    if malformed:
        log.warning(f"Source '{source_name}': {malformed} malformed row(s) excluded")

    return standardized, unresolved


# =========================================================================
# STAGE 3: CONSOLIDATE
# =========================================================================

def consolidate(standardized_sources):
    """Union every call-level source into one working set, in source order."""
    all_rows = []
    for source_name, rows in standardized_sources.items():
        all_rows.extend(rows)

    log.info(f"Unioned {len(all_rows)} total rows across all call sources before dedup")
    return all_rows


# =========================================================================
# STAGE 4: STAGE (the input SQL Server deduplicates independently)
# =========================================================================

STAGING_COLUMNS = [
    "call_ref",
    "agent_id_raw",
    "agent_num",
    "call_date",
    "start_ts",
    "duration_sec",
    "reason",
    "resolved_flag",
    "load_ts",
    "source_system",
]


def write_staging_csv(all_rows, unresolved_rows):
    """
    Write the unioned, standardized, NOT-yet-deduplicated set to
    source_data/clean/stg_call_raw.csv, which sql/05_bulk_load_staging.sql
    bulk loads into callcenter.stg_call_raw.

    This file is deliberately different from fact_call_clean.csv. That one
    is the ETL's final output, already deduplicated. Loading it into
    staging would leave the SQL window-function layer nothing to resolve,
    and the two implementations could no longer be compared. This one is
    the honest input: every version of every call, duplicates intact.

    Row order matters. It becomes the identity order of stg_call_raw, and
    the SQL dedup breaks load_ts ties on stg_call_raw_id DESC. The Python
    dedup below breaks the same tie on last-row-wins, so both resolve the
    same way.
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    path = os.path.join(OUTPUT_DIR, "stg_call_raw.csv")

    rows_out = list(all_rows) + list(unresolved_rows)

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=STAGING_COLUMNS, quoting=csv.QUOTE_MINIMAL)
        writer.writeheader()
        for row in rows_out:
            writer.writerow({
                "call_ref": row["call_ref"],
                "agent_id_raw": row["agent_id_raw"],
                "agent_num": "" if row["agent_num"] is None else row["agent_num"],
                "call_date": row["call_date"],
                "start_ts": row["start_ts"],
                "duration_sec": row["duration_sec"],
                "reason": row["reason"] or "",
                "resolved_flag": 1 if row["resolved"] else 0,
                "load_ts": row["load_ts"],
                "source_system": row["source"],
            })

    log.info(f"Staged {len(rows_out)} rows to {path}")
    log.info(f"  resolvable agent identifier : {len(all_rows)}")
    log.info(f"  null agent_num for SQL reject capture: {len(unresolved_rows)}")
    log.info("  duplicates intact by design: dedup runs again in SQL Server")

    return path


# =========================================================================
# STAGE 5: DEDUPLICATE
# =========================================================================

def deduplicate(all_rows):
    """
    Deduplicate on call_ref. Because the same physical call can legitimately
    appear in multiple legacy exports (regional + enterprise overlap) AND can
    appear twice with DIFFERENT values (QA corrections re-export with a later
    load_ts), a naive DISTINCT or first-seen dedup is wrong.

    Rule: for each call_ref, keep the row with the MOST RECENT load_ts, and
    on an exact tie keep the one that appears last in the union.

    That tie-break is not cosmetic. The SQL Server layer runs
    ROW_NUMBER() OVER (PARTITION BY call_ref ORDER BY load_ts DESC,
    stg_call_raw_id DESC), which keeps the last-inserted row on a tie. Since
    staging is loaded in this same union order, last-row-wins here produces
    the identical winner. Strictly-greater comparison would keep the first
    row instead, and the two implementations would disagree on any tied
    timestamp without either one raising an error.
    """
    best_by_call_ref = {}
    for row in all_rows:
        existing = best_by_call_ref.get(row["call_ref"])
        if existing is None or row["load_ts"] >= existing["load_ts"]:
            best_by_call_ref[row["call_ref"]] = row

    deduped = list(best_by_call_ref.values())

    overlap_count = len(all_rows) - len(deduped)
    win_counts = defaultdict(int)
    for row in deduped:
        win_counts[row["source"]] += 1

    log.info(f"Deduplication resolved {overlap_count} overlapping/duplicate records")
    log.info(f"Final clean record count: {len(deduped)}")
    for source, count in sorted(win_counts.items(), key=lambda x: -x[1]):
        log.info(f"  source '{source}' contributed the winning version for {count} calls")

    return deduped


# =========================================================================
# STAGE 6: ENRICH (join against org chart, handle orphaned agents)
# =========================================================================

def enrich_with_manager_assignment(deduped_calls, org_chart):
    """
    Join each call record to its agent's manager assignment via the org
    chart reference table. Some agents are missing from that table
    (stale export). Rather than silently dropping their calls — which
    would quietly corrupt every manager's rollup numbers — flag those
    calls explicitly so they can be routed to a data-quality review queue
    instead of vanishing.
    """
    org_lookup = {int(row["AgentNum"]): row for row in org_chart}

    enriched = []
    unmapped_agents = set()
    for call in deduped_calls:
        org_row = org_lookup.get(call["agent_num"])
        if org_row:
            call["manager_id"] = org_row["ManagerID"]
            call["agent_name"] = org_row["AgentName"]
            call["manager_assignment_status"] = "MAPPED"
        else:
            call["manager_id"] = None
            call["agent_name"] = None
            call["manager_assignment_status"] = "UNMAPPED_ORG_CHART_GAP"
            unmapped_agents.add(call["agent_num"])
        enriched.append(call)

    if unmapped_agents:
        log.warning(
            f"{len(unmapped_agents)} agent(s) had no org-chart match and were "
            f"flagged UNMAPPED_ORG_CHART_GAP rather than dropped: "
            f"{sorted(unmapped_agents)}"
        )

    return enriched


# =========================================================================
# STAGE 7: VALIDATE
# =========================================================================

def validate(enriched_calls):
    """Run basic data quality checks and log a summary. This is the kind of
    automated check that replaced manual spot-checking in the original
    2.5-hour process."""
    total = len(enriched_calls)
    missing_reason = sum(1 for c in enriched_calls if not c["reason"])
    unmapped = sum(1 for c in enriched_calls if c["manager_assignment_status"] != "MAPPED")
    negative_or_zero_duration = sum(1 for c in enriched_calls if c["duration_sec"] <= 0)
    distinct_agents = len({c["agent_num"] for c in enriched_calls})
    distinct_dates = len({c["call_date"] for c in enriched_calls})

    log.info("---- Validation Summary ----")
    log.info(f"Total clean call records : {total}")
    log.info(f"Distinct agents covered   : {distinct_agents}")
    log.info(f"Distinct call dates       : {distinct_dates}")
    log.info(f"Rows missing call reason  : {missing_reason} ({missing_reason/total:.1%})")
    log.info(f"Rows unmapped to manager  : {unmapped} ({unmapped/total:.1%})")
    log.info(f"Rows with invalid duration: {negative_or_zero_duration}")

    if negative_or_zero_duration > 0:
        log.error("Invalid duration values detected — halting load for review")
        raise ValueError(f"{negative_or_zero_duration} records have non-positive duration_sec")

    log.info("Validation passed. Proceeding to load.")


# =========================================================================
# STAGE 8: LOAD
# =========================================================================

def load_clean_data(enriched_calls, manager_ref):
    """
    Writes the clean, deduplicated, enriched dataset to staging CSVs that
    mirror exactly what gets bulk-loaded into SQL Server in production
    (via BULK INSERT/bcp from a scheduled job). The schema here matches
    sql/01_schema.sql exactly — these files are the direct input to the
    SQL Server load step described in the methodology doc.
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    fact_path = os.path.join(OUTPUT_DIR, "fact_call_clean.csv")
    fieldnames = [
        "call_ref", "agent_num", "agent_name", "manager_id",
        "manager_assignment_status", "call_date", "start_ts",
        "duration_sec", "reason", "resolved", "load_ts", "source",
    ]
    with open(fact_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for call in enriched_calls:
            writer.writerow({k: call.get(k) for k in fieldnames})

    log.info(f"Loaded {len(enriched_calls)} clean records to {fact_path}")

    manager_path = os.path.join(OUTPUT_DIR, "dim_manager.csv")
    with open(manager_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["ManagerID", "ManagerName", "Title"])
        writer.writeheader()
        writer.writerows(manager_ref)
    log.info(f"Loaded {len(manager_ref)} manager reference rows to {manager_path}")


# =========================================================================
# MAIN PIPELINE
# =========================================================================

def run():
    start_time = datetime.now()
    log.info("==== ETL pipeline run starting ====")

    sources, org_chart, manager_ref = extract_all_sources()

    standardized_sources = {}
    unresolved_rows = []
    for name, rows in sources.items():
        standardized, unresolved = standardize_source(rows, name)
        standardized_sources[name] = standardized
        unresolved_rows.extend(unresolved)

    all_rows = consolidate(standardized_sources)
    write_staging_csv(all_rows, unresolved_rows)

    deduped = deduplicate(all_rows)
    enriched = enrich_with_manager_assignment(deduped, org_chart)
    validate(enriched)
    load_clean_data(enriched, manager_ref)

    elapsed = (datetime.now() - start_time).total_seconds()
    log.info(f"==== ETL pipeline run complete in {elapsed:.2f} seconds ====")


if __name__ == "__main__":
    run()
