#!/usr/bin/env python3
"""Execute the SQL embedded in the Dart v4 message migration against SQLite."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
if not re.search(r"static const _databaseVersion = 4;", SOURCE):
    raise SystemExit("SQLite database version must be 4")

old_message_match = re.search(
    r"await db\.execute\('''\s*(CREATE TABLE messages \(.*?\))\s*'''\);",
    SOURCE,
    re.DOTALL,
)
if not old_message_match:
    raise SystemExit("Could not locate the pre-v4 messages schema")

migration_match = re.search(
    r"Future<void> _upgradeV4MessageStatus\(DatabaseExecutor db\) async \{(.*?)\n\}",
    SOURCE,
    re.DOTALL,
)
if not migration_match:
    raise SystemExit("Could not locate _upgradeV4MessageStatus")

migration_body = migration_match.group(1)
statements = re.findall(r"await db\.execute\('''(.*?)'''\);", migration_body, re.DOTALL)
if len(statements) != 2:
    raise SystemExit(f"Expected 2 embedded SQL statements, found {len(statements)}")

connection = sqlite3.connect(":memory:")
connection.execute("PRAGMA foreign_keys = ON")
connection.execute(
    """CREATE TABLE conversations (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      created_at_unix_ms INTEGER NOT NULL,
      updated_at_unix_ms INTEGER NOT NULL,
      last_message_preview TEXT NOT NULL DEFAULT ''
    )"""
)
connection.execute(old_message_match.group(1))
connection.execute(
    "INSERT INTO conversations (id, title, created_at_unix_ms, updated_at_unix_ms) "
    "VALUES ('c1', 'Existing', 1, 1)"
)
connection.executemany(
    "INSERT INTO messages VALUES (?, 'c1', 'assistant', ?, ?, ?)",
    [
        ('m1', 'old complete', 'complete', 2),
        ('m-streaming', 'partial output', 'streaming', 3),
        ('m-failed', 'old failure', 'failed', 4),
    ],
)
connection.commit()

for statement in statements:
    connection.execute(statement)
connection.execute("DROP TABLE messages")
connection.execute("ALTER TABLE messages_v4 RENAME TO messages")
connection.execute(
    "CREATE INDEX idx_messages_conversation_created "
    "ON messages(conversation_id, created_at_unix_ms ASC)"
)

rows = connection.execute(
    "SELECT id, conversation_id, role, content, status "
    "FROM messages ORDER BY created_at_unix_ms"
).fetchall()
assert rows == [
    ("m1", "c1", "assistant", "old complete", "complete"),
    ("m-streaming", "c1", "assistant", "partial output", "streaming"),
    ("m-failed", "c1", "assistant", "old failure", "failed"),
], rows
connection.execute(
    "INSERT INTO messages VALUES ('m2', 'c1', 'assistant', 'partial', 'cancelled', 3)"
)
try:
    connection.execute(
        "INSERT INTO messages VALUES ('m3', 'c1', 'assistant', 'bad', 'unknown', 4)"
    )
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError("The v4 status CHECK constraint accepted an unknown status")
connection.execute("DELETE FROM conversations WHERE id = 'c1'")
remaining = connection.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
assert remaining == 0, f"Conversation cascade left {remaining} messages"
connection.close()
print(
    "Conversation SQLite migration PASS: legacy states preserved, cancelled "
    "accepted, invalid status rejected, cascade intact"
)
