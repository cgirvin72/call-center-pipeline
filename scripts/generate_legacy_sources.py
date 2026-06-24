"""
generate_legacy_sources.py

Generates SYNTHETIC data simulating legacy Access-database exports from a
call center operation. This recreates the *shape* of the real-world problem
this project is based on: ~100 agents under 4 regional managers + 1 senior
manager, with daily call activity scattered across multiple overlapping
database exports that each have their own quirks, gaps, and duplication.

DISCLOSURE: All data below is synthetically generated for portfolio
demonstration purposes. No real call center records, agent names, customer
data, or proprietary system data are used or represented here. Agent names,
IDs, and call metrics are fabricated.

Why the data looks messy on purpose (this is the point of the project):
  - 5 separate "legacy" CSV exports, modeled after 5 of the real ~20+ Access
    databases that fed the original reporting process.
  - Two of the exports OVERLAP in coverage (same calls appear in both,
    because regional databases were never fully separated from the
    enterprise-wide export).
  - One export contains LATE CORRECTIONS: a handful of calls were re-logged
    days later with corrected handle times, creating duplicate natural keys
    with different load timestamps. The most recent load should win.
  - Agent IDs are formatted inconsistently across sources (e.g. "A1042" vs
    "1042" vs "AGT-1042") — a classic legacy-Access symptom of one ID field
    being free text.
  - Some rows have missing manager assignments (agents transferred between
    teams and the org chart export wasn't refreshed).
"""

import csv
import random
from datetime import datetime, timedelta

random.seed(42)  # reproducible synthetic data

OUTPUT_DIR = "/home/claude/project3/source_data"

MANAGERS = [
    ("MGR001", "D. Whitfield", "Senior Manager"),
    ("MGR002", "R. Castellano", "Manager"),
    ("MGR003", "T. Okafor", "Manager"),
    ("MGR004", "S. Lindqvist", "Manager"),
    ("MGR005", "P. Abernathy", "Manager"),
]

FIRST_NAMES = ["James", "Maria", "Wei", "Aisha", "Carlos", "Emily", "Raj", "Sofia",
               "Michael", "Latoya", "Daniel", "Priya", "Andre", "Hannah", "Omar",
               "Grace", "Tyler", "Fatima", "Nathan", "Chloe", "Marcus", "Yuki",
               "Isabella", "Kevin", "Amara"]
LAST_NAMES = ["Reed", "Gonzalez", "Chen", "Patel", "Mendoza", "Walsh", "Kumar",
              "Romano", "Jefferson", "Brooks", "Ferreira", "Singh", "Dubois",
              "Whitaker", "Hassan", "Lindgren", "Park", "Nakamura", "Cole",
              "Okonkwo", "Barros", "Tanaka", "Silva", "Murphy", "Adeyemi"]

NUM_AGENTS = 103  # "~100 agents" -- realistic, not a round number
CALL_REASONS = ["Billing Inquiry", "Account Access", "Plan Change", "Technical Support",
                "Cancellation Request", "Payment Processing", "Complaint Escalation",
                "Service Upgrade", "Fraud Report", "General Inquiry"]

# --- Build the agent roster (this simulates the HR/org-chart side table) ---
agents = []
used_names = set()
for i in range(1, NUM_AGENTS + 1):
    while True:
        name = f"{random.choice(FIRST_NAMES)} {random.choice(LAST_NAMES)}"
        if name not in used_names:
            used_names.add(name)
            break
    manager = random.choice(MANAGERS[1:])  # senior manager doesn't directly manage agents
    agents.append({
        "agent_num": 1000 + i,
        "name": name,
        "manager_id": manager[0],
    })

# A handful of agents have NO manager assignment in the org chart export
# (simulates agents who transferred teams and the export wasn't refreshed)
ORPHANED_AGENT_NUMS = set(random.sample([a["agent_num"] for a in agents], 4))

def format_agent_id(agent_num, style):
    """Simulate inconsistent agent ID formatting across legacy sources."""
    if style == "bare":
        return str(agent_num)
    elif style == "prefixed_a":
        return f"A{agent_num}"
    elif style == "prefixed_agt":
        return f"AGT-{agent_num}"
    elif style == "padded":
        return f"A{agent_num:06d}"
    return str(agent_num)


# --- Generate call records across a 14-day window ---
START_DATE = datetime(2026, 5, 4)
NUM_DAYS = 14

all_calls = []
call_seq = 1

for day_offset in range(NUM_DAYS):
    call_date = START_DATE + timedelta(days=day_offset)
    # Skip weekends to mimic a weekday-only support floor (more realistic)
    if call_date.weekday() >= 5:
        continue

    for agent in agents:
        # Not every agent worked every day (PTO, schedule variation)
        if random.random() < 0.08:
            continue

        daily_call_count = random.randint(18, 42)
        for _ in range(daily_call_count):
            hour = random.randint(7, 18)
            minute = random.randint(0, 59)
            second = random.randint(0, 59)
            call_start = call_date.replace(hour=hour, minute=minute, second=second)
            handle_seconds = max(45, int(random.gauss(310, 140)))  # AHT ~5min, noisy

            all_calls.append({
                "call_id": f"CL{call_seq:07d}",
                "agent_num": agent["agent_num"],
                "manager_id": agent["manager_id"],
                "call_date": call_date.date().isoformat(),
                "call_start_ts": call_start.isoformat(sep=" "),
                "handle_time_sec": handle_seconds,
                "call_reason": random.choice(CALL_REASONS),
                "resolved_flag": 1 if random.random() > 0.07 else 0,
            })
            call_seq += 1

print(f"Generated {len(all_calls)} synthetic call events across {NUM_DAYS} weekdays.")
print(f"Roster size: {len(agents)} agents across {len(MANAGERS)-1} manager teams + 1 senior manager.")

# =========================================================================
# Now split / duplicate / corrupt these clean records into 5 "legacy"
# exports, each modeling a real failure pattern from the original system.
# =========================================================================

agent_lookup = {a["agent_num"]: a for a in agents}

# ---- Source 1: Regional DB - North & East teams (MGR002, MGR003) ----
# Agent IDs formatted as "A1042". One load timestamp per file (simulates a
# nightly Access export job).
src1_load_ts = "2026-05-18 22:14:07"
src1_rows = []
for call in all_calls:
    mgr = call["manager_id"]
    if mgr in ("MGR002", "MGR003"):
        src1_rows.append({
            "CallRef": call["call_id"],
            "AgentID": format_agent_id(call["agent_num"], "prefixed_a"),
            "CallDate": call["call_date"],
            "StartTime": call["call_start_ts"],
            "DurationSec": call["handle_time_sec"],
            "Reason": call["call_reason"],
            "Resolved": call["resolved_flag"],
            "LoadTimestamp": src1_load_ts,
        })

# ---- Source 2: Regional DB - West & South teams (MGR004, MGR005) ----
# Agent IDs formatted bare ("1042"). Some missing call_reason values
# (legacy free-text field, occasionally left blank by agents).
src2_load_ts = "2026-05-18 22:31:55"
src2_rows = []
for call in all_calls:
    mgr = call["manager_id"]
    if mgr in ("MGR004", "MGR005"):
        reason = call["call_reason"] if random.random() > 0.05 else ""
        src2_rows.append({
            "CallRef": call["call_id"],
            "AgentID": format_agent_id(call["agent_num"], "bare"),
            "CallDate": call["call_date"],
            "StartTime": call["call_start_ts"],
            "DurationSec": call["handle_time_sec"],
            "Reason": reason,
            "Resolved": call["resolved_flag"],
            "LoadTimestamp": src2_load_ts,
        })

# ---- Source 3: Enterprise-wide nightly export (ALL teams) ----
# THIS IS THE OVERLAP PROBLEM: this export covers every manager team,
# meaning every call in Source 1 and Source 2 ALSO appears here, with
# AgentID formatted yet another way ("AGT-1042"). This models the real
# scenario where the enterprise export was never properly scoped away
# from the regional ones.
src3_load_ts = "2026-05-18 23:02:41"
src3_rows = []
for call in all_calls:
    src3_rows.append({
        "CallRef": call["call_id"],
        "AgentID": format_agent_id(call["agent_num"], "prefixed_agt"),
        "CallDate": call["call_date"],
        "StartTime": call["call_start_ts"],
        "DurationSec": call["handle_time_sec"],
        "Reason": call["call_reason"],
        "Resolved": call["resolved_flag"],
        "LoadTimestamp": src3_load_ts,
    })

# ---- Source 4: Late-correction feed ----
# A subset of calls got their handle time corrected days after the fact
# (QA review adjustments) and were re-exported. Same CallRef, later
# LoadTimestamp, corrected DurationSec. The ETL must keep the LATEST
# version per CallRef, not just dedupe blindly.
correction_sample = random.sample(all_calls, k=int(len(all_calls) * 0.015))
src4_load_ts = "2026-05-22 09:47:13"
src4_rows = []
for call in correction_sample:
    corrected_duration = max(30, call["handle_time_sec"] + random.randint(-90, 180))
    src4_rows.append({
        "CallRef": call["call_id"],
        "AgentID": format_agent_id(call["agent_num"], "padded"),
        "CallDate": call["call_date"],
        "StartTime": call["call_start_ts"],
        "DurationSec": corrected_duration,
        "Reason": call["call_reason"],
        "Resolved": call["resolved_flag"],
        "LoadTimestamp": src4_load_ts,
    })

# ---- Source 5: HR / Org chart export (agent -> manager mapping) ----
# This is the side table the original system joined against to know which
# manager an agent rolled up to. A few agents are missing here (orphaned),
# which the SQL layer needs to handle gracefully rather than silently
# dropping their call records.
src5_rows = []
for agent in agents:
    if agent["agent_num"] in ORPHANED_AGENT_NUMS:
        continue  # simulates a stale org-chart export missing this agent
    src5_rows.append({
        "AgentNum": agent["agent_num"],
        "AgentName": agent["name"],
        "ManagerID": agent["manager_id"],
    })

# ---- Manager reference table (small, clean — the one source that ISN'T messy) ----
manager_rows = [{"ManagerID": m[0], "ManagerName": m[1], "Title": m[2]} for m in MANAGERS]


def write_csv(filename, rows, fieldnames):
    path = f"{OUTPUT_DIR}/{filename}"
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"  wrote {filename}: {len(rows)} rows")


print("\nWriting legacy source exports to:", OUTPUT_DIR)
write_csv("legacy_export_north_east_calls.csv", src1_rows,
          ["CallRef", "AgentID", "CallDate", "StartTime", "DurationSec", "Reason", "Resolved", "LoadTimestamp"])
write_csv("legacy_export_west_south_calls.csv", src2_rows,
          ["CallRef", "AgentID", "CallDate", "StartTime", "DurationSec", "Reason", "Resolved", "LoadTimestamp"])
write_csv("legacy_export_enterprise_calls.csv", src3_rows,
          ["CallRef", "AgentID", "CallDate", "StartTime", "DurationSec", "Reason", "Resolved", "LoadTimestamp"])
write_csv("legacy_export_qa_corrections.csv", src4_rows,
          ["CallRef", "AgentID", "CallDate", "StartTime", "DurationSec", "Reason", "Resolved", "LoadTimestamp"])
write_csv("legacy_export_org_chart.csv", src5_rows,
          ["AgentNum", "AgentName", "ManagerID"])
write_csv("legacy_export_manager_reference.csv", manager_rows,
          ["ManagerID", "ManagerName", "Title"])

print(f"\nOrphaned agents (missing from org chart export): {sorted(ORPHANED_AGENT_NUMS)}")
print(f"QA-corrected call records: {len(src4_rows)}")
print("\nDone. These 6 files simulate a slice of the 20+ legacy Access")
print("databases the real ETL process consolidated.")
