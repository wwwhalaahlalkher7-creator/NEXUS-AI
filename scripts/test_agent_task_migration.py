#!/usr/bin/env python3
"""Validate the v8 multi-agent task schema and its cascade/recovery relations."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", source)
if not version or int(version.group(1)) < 8:
    raise SystemExit("SQLite database version must be at least 8")

migration = re.search(
    r"Future<void> _createV8OrchestrationTables\(DatabaseExecutor db\) async \{(.*?)\n\}",
    source,
    re.DOTALL,
)
if not migration:
    raise SystemExit("Could not locate the v8 orchestration migration")
statements = re.findall(r"await db\.execute\('''(.*?)'''\);", migration.group(1), re.DOTALL)
if len(statements) != 3:
    raise SystemExit(f"Expected 3 v8 tables, found {len(statements)}")

connection = sqlite3.connect(":memory:")
connection.execute("PRAGMA foreign_keys = ON")
connection.execute(
    "CREATE TABLE agents (id TEXT PRIMARY KEY, name TEXT NOT NULL)"
)
for statement in statements:
    connection.execute(statement)
connection.execute("INSERT INTO agents(id, name) VALUES ('a1', 'Researcher')")
connection.execute(
    "INSERT INTO agent_tasks(id, goal, planner_agent_id, status, plan_json, created_at_unix_ms, updated_at_unix_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ("t1", "Build report", "a1", "planned", '{"schema_version":1}', 1, 1),
)
connection.execute(
    "INSERT INTO agent_task_steps(id, task_id, step_key, ordinal, agent_id, objective, expected_output, depends_on_json, status, output_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ("t1-s1", "t1", "s1", 0, "a1", "Research", "Notes", "[]", "pending", ""),
)
connection.execute(
    "INSERT INTO agent_task_events(id, task_id, event_type, message, payload_json, created_at_unix_ms) VALUES (?, ?, ?, ?, ?, ?)",
    ("e1", "t1", "plan_created", "Plan saved", "{}", 1),
)
connection.execute("UPDATE agent_task_steps SET status='running' WHERE id='t1-s1'")
connection.execute("UPDATE agent_task_steps SET status='interrupted' WHERE id='t1-s1' AND status='running'")
assert connection.execute("SELECT status FROM agent_task_steps WHERE id='t1-s1'").fetchone()[0] == "interrupted"
connection.execute("DELETE FROM agents WHERE id='a1'")
assert connection.execute("SELECT agent_id FROM agent_task_steps WHERE id='t1-s1'").fetchone()[0] is None
connection.execute("DELETE FROM agent_tasks WHERE id='t1'")
assert connection.execute("SELECT COUNT(*) FROM agent_task_steps").fetchone()[0] == 0
assert connection.execute("SELECT COUNT(*) FROM agent_task_events").fetchone()[0] == 0
connection.close()

if "if (oldVersion < 8)" not in source or "await _createV8OrchestrationTables(db);" not in source:
    raise SystemExit("v8 onUpgrade path is missing")
print("Agent task v8 migration PASS: task/step/event persistence, interruption status, FK and cascade")
