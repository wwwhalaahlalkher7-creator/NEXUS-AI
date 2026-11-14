#!/usr/bin/env python3
"""Validate SQLite v9 paired-device metadata and deletion semantics."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", source)
if not version or int(version.group(1)) < 9:
    raise SystemExit("SQLite database version must be at least 9")

migration = re.search(
    r"Future<void> _createV9PairedDeviceTables\(DatabaseExecutor db\) async \{(.*?)\n\}",
    source,
    re.DOTALL,
)
if not migration:
    raise SystemExit("Could not locate the v9 paired-device migration")
statements = re.findall(r"await db\.execute\('''(.*?)'''\);", migration.group(1), re.DOTALL)
if len(statements) != 2:
    raise SystemExit(f"Expected 2 v9 tables, found {len(statements)}")

connection = sqlite3.connect(":memory:")
connection.execute("PRAGMA foreign_keys = ON")
for statement in statements:
    connection.execute(statement)
connection.execute(
    "INSERT INTO paired_devices VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ("peer-1", "NEXUS peer", "android", "192.168.1.12", 47831,
     "ABCD 1234", '{"model_session_concurrency":1}', "paired", 1, 1, 1),
)
connection.execute(
    "INSERT INTO device_events VALUES (?, ?, ?, ?, ?)",
    ("event-1", "peer-1", "paired", "Paired", 1),
)
assert connection.execute(
    "SELECT trust_status, last_port FROM paired_devices WHERE id='peer-1'"
).fetchone() == ("paired", 47831)
connection.execute("UPDATE paired_devices SET trust_status='blocked' WHERE id='peer-1'")
assert connection.execute(
    "SELECT trust_status FROM paired_devices WHERE id='peer-1'"
).fetchone()[0] == "blocked"
connection.execute("DELETE FROM paired_devices WHERE id='peer-1'")
assert connection.execute("SELECT COUNT(*) FROM device_events").fetchone()[0] == 0
connection.close()

if "if (oldVersion < 9)" not in source or "await _createV9PairedDeviceTables(db);" not in source:
    raise SystemExit("v9 onUpgrade path is missing")
if "Pairing secrets are never stored in" not in source:
    raise SystemExit("Database must document that pairing secrets are not stored in SQLite")
print("Paired devices v9 migration PASS: metadata, trust status, FK and event cascade")
