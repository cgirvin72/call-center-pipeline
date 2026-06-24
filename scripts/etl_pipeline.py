"""
etl_pipeline.py

Python ETL layer for the Call Center Reporting Consolidation project.

SCOPE NOTE: This script handles EXTRACTION and TRANSFORMATION only. It reads
the messy legacy exports, standardizes and deduplicates them, and loads
clean, query-ready data into SQL Server. It does NOT generate reports or
dashboards — that consumption layer was built in Tableau, connecting
directly to the cleaned SQL Server tables this script produces. Python's
job ends the moment trustworthy data lands in the warehouse.

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
  4. DEDUPLICATE - resolve the overlap problem (same call in multiple
     sources) by keeping the most recently loaded version of each call
  5. ENRICH - join against the org-chart side table to attach manager
     assignment, handling agents missing from that export
  6. VALIDATE - run data quality checks and log results
  7. LOAD - write the clean, query-ready tables out (here: to CSV staging
     files that mirror exactly what would be bulk-loaded into SQL Server
     via BULK INSERT / bcp; in production this step targets SQL Server
     directly via pyodbc)

USAGE:
    python etl_pipeline.py
"""

import csv
import logging
import re
from collections import defaultdict
from datetime import datetime

SOURCE_DIR = "/home/claude/project3/source_data"
OUTPUT_DIR = "/home/claude/project3/source_data/clean"

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
    path = f"{SOURCE_DIR}/{filename}"
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
    """Normalize agent IDs and coerce types. Returns a list of dicts with
    a consistent schema regardless of which legacy source they came from."""
    standardized = []
    bad_rows = 0
    for row in rows:
        agent_num = normalize_agent_id(row["AgentID"])
        if agent_num is None:
            bad_rows += 1
            continue
        try:
            standardized.append({
                "call_ref": row["CallRef"],
                "agent_num": agent_num,
                "call_date": row["CallDate"],
                "start_ts": row["StartTime"],
                "duration_sec": int(row["DurationSec"]),
                "reason": row["Reason"].strip() if row["Reason"] else None,
                "resolved": bool(int(row["Resolved"])),
                "load_ts": row["LoadTimestamp"],
                "source": source_name,
            })
        except (ValueError, KeyError) as e:
            bad_rows += 1
            log.warning(f"Skipped malformed row in '{source_name}': {e}")

    if bad_rows:
        log.warning(f"Source '{source_name}': {bad_rows} rows failed standardization and were excluded")
    return standardized


# =========================================================================
# STAGE 3 & 4: CONSOLIDATE + DEDUPLICATE
# =========================================================================

def consolidate_and_deduplicate(standardized_sources):
    """
    All four call-level sources are unioned together, then deduplicated on
    call_ref. Because the same physical call can legitimately appear in
    multiple legacy exports (regional + enterprise overlap) AND can appear
    twice with DIFFERENT values (QA corrections re-export with a later
    load_ts), a naive DISTINCT or first-seen dedup is wrong.

    Rule: for each call_ref, keep the row with the MOST RECENT load_ts.
    This is exactly what the SQL Server window-function layer does too
    (ROW_NUMBER() OVER (PARTITION BY call_ref ORDER BY load_ts DESC)) —
    implementing it here in Python lets us validate the logic and produce
    an audit log of which source won for each call before it ever reaches
    the database.
    """
    all_rows = []
    for source_name, rows in standardized_sources.items():
        all_rows.extend(rows)

    log.info(f"Unioned {len(all_rows)} total rows across all call sources before dedup")

    best_by_call_ref = {}
    for row in all_rows:
        existing = best_by_call_ref.get(row["call_ref"])
        if existing is None or row["load_ts"] > existing["load_ts"]:
            best_by_call_ref[row["call_ref"]] = row

    deduped = list(best_by_call_ref.values())

    # Audit trail: how many calls had competing versions, and which source
    # ultimately won most often
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
# STAGE 5: ENRICH (join against org chart, handle orphaned agents)
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
# STAGE 6: VALIDATE
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
# STAGE 7: LOAD
# =========================================================================

def load_clean_data(enriched_calls, manager_ref):
    """
    Writes the clean, deduplicated, enriched dataset to staging CSVs that
    mirror exactly what gets bulk-loaded into SQL Server in production
    (via BULK INSERT/bcp from a scheduled job). The schema here matches
    sql/01_schema.sql exactly — these files are the direct input to the
    SQL Server load step described in the methodology doc.
    """
    import os
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    fact_path = f"{OUTPUT_DIR}/fact_call_clean.csv"
    fieldnames = [
        "call_ref", "agent_num", "agent_name", "manager_id",
        "manager_assignment_status", "call_date", "start_ts",
        "duration_sec", "reason", "resolved", "load_ts", "source",
    ]
    with open(fact_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for call in enriched_calls:
            writer.writerow({k: call.get(k) for k in fieldnames})

    log.info(f"Loaded {len(enriched_calls)} clean records to {fact_path}")

    manager_path = f"{OUTPUT_DIR}/dim_manager.csv"
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

    standardized_sources = {
        name: standardize_source(rows, name) for name, rows in sources.items()
    }

    deduped = consolidate_and_deduplicate(standardized_sources)
    enriched = enrich_with_manager_assignment(deduped, org_chart)
    validate(enriched)
    load_clean_data(enriched, manager_ref)

    elapsed = (datetime.now() - start_time).total_seconds()
    log.info(f"==== ETL pipeline run complete in {elapsed:.2f} seconds ====")


if __name__ == "__main__":
    run()
