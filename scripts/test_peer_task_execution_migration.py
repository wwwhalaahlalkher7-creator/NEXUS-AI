#!/usr/bin/env python3
"""Validate the durable SQLite v12 peer-execution request ledger."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", source)
if not version or int(version.group(1)) < 13:
    raise SystemExit("Expected SQLite schema v13 or newer")

migration = re.search(
    r"Future<void> _createV12PeerTaskExecutionTable\(DatabaseExecutor db\) async \{(.*?)\n\}",
    source,
    re.DOTALL,
)
if not migration:
    raise SystemExit("Could not locate v12 peer task execution migration")
statements = re.findall(r"await db\.execute\('''(.*?)'''\);", migration.group(1), re.DOTALL)
index_statements = re.findall(
    r"await db\.execute\(\s*'([^']+)'\s*\n\s*'([^']*)',\s*\);",
    migration.group(1),
)
if len(statements) != 1 or len(index_statements) != 2:
    raise SystemExit("Unexpected v12 table/index statement count")

connection = sqlite3.connect(":memory:")
connection.execute("PRAGMA foreign_keys = ON")
connection.execute("CREATE TABLE paired_devices (id TEXT PRIMARY KEY NOT NULL)")
connection.execute("CREATE TABLE agents (id TEXT PRIMARY KEY NOT NULL)")
connection.execute(statements[0])
for first, second in index_statements:
    connection.execute(first + second)
connection.execute("INSERT INTO paired_devices VALUES ('peer-a')")
connection.execute("INSERT INTO agents VALUES ('agent-a')")

base = (
    "execution_0123456789abcdef", "peer-a", "incoming", "awaiting_approval",
    "task-a", "step-a", "agent-a", '{"kind":"task_execution_request"}',
    "a" * 64, None, None, None, 1000, 1000, 901000,
)
columns = (
    "execution_id, device_id, direction, status, source_task_id, source_step_key, "
    "local_agent_id, request_json, request_sha256, result_json, result_sha256, error, "
    "created_at_unix_ms, updated_at_unix_ms, expires_at_unix_ms"
)
connection.execute(
    f"INSERT INTO peer_task_executions ({columns}) VALUES ({','.join('?' for _ in base)})",
    base,
)
assert connection.execute(
    "SELECT direction, status, local_agent_id FROM peer_task_executions WHERE execution_id=?",
    (base[0],),
).fetchone() == ("incoming", "awaiting_approval", "agent-a")

# One-time result storage and terminal state are represented durably.
connection.execute(
    "UPDATE peer_task_executions SET status='running', updated_at_unix_ms=2 WHERE execution_id=?",
    (base[0],),
)
connection.execute(
    "UPDATE peer_task_executions SET status='succeeded', result_json=?, result_sha256=?, updated_at_unix_ms=3 WHERE execution_id=?",
    ('{"kind":"task_execution_result"}', "b" * 64, base[0]),
)
assert connection.execute(
    "SELECT status, result_sha256 FROM peer_task_executions WHERE execution_id=?",
    (base[0],),
).fetchone() == ("succeeded", "b" * 64)

for index, direction, status in (
    (1, "unknown", "queued"),
    (2, "incoming", "unknown"),
):
    row = list(base)
    row[0] = f"execution_1123456789abcdef{index}"
    row[2] = direction
    row[3] = status
    try:
        connection.execute(
            f"INSERT INTO peer_task_executions ({columns}) VALUES ({','.join('?' for _ in row)})",
            row,
        )
        raise AssertionError("CHECK constraint accepted invalid execution metadata")
    except sqlite3.IntegrityError:
        pass

invalid_expiry = list(base)
invalid_expiry[0] = "execution_2123456789abcdef"
invalid_expiry[14] = 999
try:
    connection.execute(
        f"INSERT INTO peer_task_executions ({columns}) VALUES ({','.join('?' for _ in invalid_expiry)})",
        invalid_expiry,
    )
    raise AssertionError("Expiry CHECK constraint accepted non-positive lifetime")
except sqlite3.IntegrityError:
    pass

on_create = source.split("onCreate:", 1)[1].split("onUpgrade:", 1)[0]
if "await _createV12PeerTaskExecutionTable(db);" not in on_create:
    raise SystemExit("v12 onCreate path is missing")
if "if (oldVersion < 12)" not in source or "await _createV12PeerTaskExecutionTable(db);" not in source:
    raise SystemExit("v12 onUpgrade path is missing")
if "Durable ledger for authenticated peer execution requests" not in source:
    raise SystemExit("Migration comment must describe the active execution ledger")

ack_migration = re.search(
    r"Future<void> _upgradeV13PeerTaskResultAcknowledgement\(\s*DatabaseExecutor db,\s*\) async \{(.*?)\n\}",
    source,
    re.DOTALL,
)
if not ack_migration:
    raise SystemExit("Could not locate v13 result acknowledgement migration")
ack_statements = re.findall(r"await db\.execute\(\s*'([^']+)'\s*'([^']*)',\s*\);", ack_migration.group(1))
if len(ack_statements) != 2:
    raise SystemExit("Unexpected v13 result acknowledgement statement count")
for first, second in ack_statements:
    connection.execute(first + second)
columns_after = {row[1] for row in connection.execute("PRAGMA table_info(peer_task_executions)")}
assert "result_acknowledged_at_unix_ms" in columns_after
connection.execute(
    "UPDATE peer_task_executions SET result_acknowledged_at_unix_ms=4 WHERE execution_id=? AND result_sha256=? AND result_acknowledged_at_unix_ms IS NULL",
    (base[0], "b" * 64),
)
assert connection.execute(
    "SELECT result_acknowledged_at_unix_ms FROM peer_task_executions WHERE execution_id=?",
    (base[0],),
).fetchone()[0] == 4
connection.execute(
    "UPDATE peer_task_executions SET result_acknowledged_at_unix_ms=5 WHERE execution_id=? AND result_sha256=? AND result_acknowledged_at_unix_ms IS NULL",
    (base[0], "b" * 64),
)
assert connection.execute(
    "SELECT result_acknowledged_at_unix_ms FROM peer_task_executions WHERE execution_id=?",
    (base[0],),
).fetchone()[0] == 4
connection.execute("DELETE FROM agents WHERE id='agent-a'")
assert connection.execute(
    "SELECT local_agent_id FROM peer_task_executions WHERE execution_id=?",
    (base[0],),
).fetchone()[0] is None
connection.execute("DELETE FROM paired_devices WHERE id='peer-a'")
assert connection.execute("SELECT COUNT(*) FROM peer_task_executions").fetchone()[0] == 0
connection.close()
if "await _upgradeV13PeerTaskResultAcknowledgement(db);" not in on_create:
    raise SystemExit("v13 onCreate path is missing")
if "if (oldVersion < 13)" not in source or "await _upgradeV13PeerTaskResultAcknowledgement(db);" not in source:
    raise SystemExit("v13 onUpgrade path is missing")
print("Peer task execution SQLite v12/v13 migration PASS: ledger constraints, FK behavior, result-ack column/index and upgrade paths")
