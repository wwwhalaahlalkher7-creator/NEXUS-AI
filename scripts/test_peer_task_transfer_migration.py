#!/usr/bin/env python3
"""Validate SQLite v10 task transfer tables and v11 local import reference."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", source)
if not version or int(version.group(1)) < 11:
    raise SystemExit("Expected SQLite schema v11 or newer")

migration = re.search(
    r"Future<void> _createV10TaskTransferTables\(DatabaseExecutor db\) async \{(.*?)\n\}",
    source,
    re.DOTALL,
)
if not migration:
    raise SystemExit("Could not locate v10 task-transfer migration")
statements = re.findall(r"await db\.execute\('''(.*?)'''\);", migration.group(1), re.DOTALL)
if len(statements) != 1:
    raise SystemExit(f"Expected one table creation statement, found {len(statements)}")
index_statements = re.findall(
    r"await db\.execute\(\s*'([^']+)'\s*\n\s*'([^']*)',\s*\);",
    migration.group(1),
)

connection = sqlite3.connect(":memory:")
connection.execute("PRAGMA foreign_keys = ON")
connection.execute("CREATE TABLE agent_tasks (id TEXT PRIMARY KEY NOT NULL)")
connection.execute("""CREATE TABLE paired_devices (
    id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL
)""")
connection.execute(statements[0])
for first, second in index_statements:
    connection.execute(first + second)
connection.execute("INSERT INTO paired_devices VALUES ('peer-a', 'NEXUS peer')")
connection.execute("ALTER TABLE remote_task_transfers ADD COLUMN imported_task_id TEXT REFERENCES agent_tasks(id) ON DELETE SET NULL")
connection.execute("CREATE INDEX idx_remote_task_transfers_imported_task ON remote_task_transfers(imported_task_id)")
base = (
    "transfer_0123456789abcdef", "peer-a", "outgoing", "queued", "task-a",
    "A sample task", '{"schema_version":1}', "a" * 64, 1000, 1000, None,
)
connection.execute(
    "INSERT INTO remote_task_transfers (transfer_id, device_id, direction, status, source_task_id, goal, plan_json, payload_sha256, created_at_unix_ms, updated_at_unix_ms, last_error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    base,
)
assert connection.execute(
    "SELECT status, direction FROM remote_task_transfers WHERE transfer_id=?",
    (base[0],),
).fetchone() == ("queued", "outgoing")
for transfer_id, status in (
    ("transfer_1123456789abcdef", "rejected"),
    ("transfer_2123456789abcdef", "declined"),
):
    terminal = list(base)
    terminal[0] = transfer_id
    terminal[3] = status
    connection.execute(
        "INSERT INTO remote_task_transfers (transfer_id, device_id, direction, status, source_task_id, goal, plan_json, payload_sha256, created_at_unix_ms, updated_at_unix_ms, last_error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        terminal,
    )

try:
    invalid = list(base)
    invalid[2] = "unknown"
    connection.execute(
        "INSERT INTO remote_task_transfers (transfer_id, device_id, direction, status, source_task_id, goal, plan_json, payload_sha256, created_at_unix_ms, updated_at_unix_ms, last_error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        invalid,
    )
    raise AssertionError("Direction CHECK constraint did not reject invalid value")
except sqlite3.IntegrityError:
    pass

if "if (oldVersion < 10)" not in source or "await _createV10TaskTransferTables(db);" not in source:
    raise SystemExit("v10 onUpgrade path is missing")
if "await _createV10TaskTransferTables(db);" not in source.split("onCreate:", 1)[1].split("onUpgrade:", 1)[0]:
    raise SystemExit("v10 onCreate path is missing")
if "await _upgradeV11RemoteTaskImport(db);" not in source.split("onCreate:", 1)[1].split("onUpgrade:", 1)[0]:
    raise SystemExit("v11 onCreate path is missing")
v11 = re.search(r"Future<void> _upgradeV11RemoteTaskImport\(DatabaseExecutor db\) async \{(.*?)\n\}", source, re.DOTALL)
if not v11 or "ALTER TABLE remote_task_transfers ADD COLUMN imported_task_id TEXT" not in v11.group(1):
    raise SystemExit("v11 imported-task reference migration is missing")
if "if (oldVersion < 11)" not in source or "await _upgradeV11RemoteTaskImport(db);" not in source:
    raise SystemExit("v11 upgrade path is missing")
incoming = list(base)
incoming[0] = "transfer_3123456789abcdef"
incoming[2] = "incoming"
incoming[3] = "kept"
connection.execute(
    "INSERT INTO remote_task_transfers (transfer_id, device_id, direction, status, source_task_id, goal, plan_json, payload_sha256, created_at_unix_ms, updated_at_unix_ms, last_error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    incoming,
)
connection.execute("INSERT INTO agent_tasks VALUES ('task-local')")
connection.execute("UPDATE remote_task_transfers SET imported_task_id='task-local' WHERE transfer_id=?", (incoming[0],))
assert connection.execute("SELECT imported_task_id FROM remote_task_transfers WHERE transfer_id=?", (incoming[0],)).fetchone()[0] == 'task-local'
connection.execute("DELETE FROM agent_tasks WHERE id='task-local'")
assert connection.execute("SELECT imported_task_id FROM remote_task_transfers WHERE transfer_id=?", (incoming[0],)).fetchone()[0] is None
connection.execute("DELETE FROM paired_devices WHERE id='peer-a'")
assert connection.execute("SELECT COUNT(*) FROM remote_task_transfers").fetchone()[0] == 0
connection.close()
print("Peer task transfer v10/v11 migration PASS: constraints, FK cascades, import reference and upgrade path")
