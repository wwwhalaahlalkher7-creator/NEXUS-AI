#!/usr/bin/env python3
"""Validate SQLite v10 durable peer task-transfer inbox/outbox schema."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", source)
if not version or int(version.group(1)) != 10:
    raise SystemExit("Expected SQLite schema v10")

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
connection.execute("""CREATE TABLE paired_devices (
    id TEXT PRIMARY KEY NOT NULL,
    display_name TEXT NOT NULL
)""")
connection.execute(statements[0])
for first, second in index_statements:
    connection.execute(first + second)
connection.execute("INSERT INTO paired_devices VALUES ('peer-a', 'NEXUS peer')")
base = (
    "transfer_0123456789abcdef", "peer-a", "outgoing", "queued", "task-a",
    "A sample task", '{"schema_version":1}', "a" * 64, 1000, 1000, None,
)
connection.execute(
    "INSERT INTO remote_task_transfers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
        "INSERT INTO remote_task_transfers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        terminal,
    )

try:
    invalid = list(base)
    invalid[2] = "unknown"
    connection.execute(
        "INSERT INTO remote_task_transfers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        invalid,
    )
    raise AssertionError("Direction CHECK constraint did not reject invalid value")
except sqlite3.IntegrityError:
    pass

connection.execute("DELETE FROM paired_devices WHERE id='peer-a'")
assert connection.execute("SELECT COUNT(*) FROM remote_task_transfers").fetchone()[0] == 0
connection.close()

if "if (oldVersion < 10)" not in source or "await _createV10TaskTransferTables(db);" not in source:
    raise SystemExit("v10 onUpgrade path is missing")
if "await _createV10TaskTransferTables(db);" not in source.split("onCreate:", 1)[1].split("onUpgrade:", 1)[0]:
    raise SystemExit("v10 onCreate path is missing")
print("Peer task transfer v10 migration PASS: inbox/outbox constraints, indexes, FK cascade and upgrade path")
