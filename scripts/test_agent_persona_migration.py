#!/usr/bin/env python3
"""Exercise the v5 agent-persona and conversation-binding migration in SQLite."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", SOURCE)
if not version or int(version.group(1)) < 5:
    raise SystemExit("SQLite database version must retain the v5 migration")

migration = re.search(
    r"Future<void> _upgradeV5AgentPersona\(DatabaseExecutor db\) async \{(.*?)\n\}",
    SOURCE,
    re.DOTALL,
)
if not migration:
    raise SystemExit("Could not locate _upgradeV5AgentPersona")
statements = re.findall(r"await db\.execute\((.*?)\);", migration.group(1), re.DOTALL)
if len(statements) != 3:
    raise SystemExit(f"Expected 3 v5 SQL statements, found {len(statements)}")

sql = []
for statement in statements:
    literals = re.findall(r"\"([^\"]*)\"|'([^']*)'", statement, re.DOTALL)
    if not literals:
        raise SystemExit(f"Could not parse migration SQL literal: {statement}")
    sql.append("".join(double or single for double, single in literals))

connection = sqlite3.connect(":memory:")
connection.execute("PRAGMA foreign_keys = ON")
connection.executescript(
    """
    CREATE TABLE agents (
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL CHECK(status IN ('draft', 'ready', 'paused')),
      model_id TEXT,
      created_at_unix_ms INTEGER NOT NULL
    );
    CREATE TABLE conversations (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      created_at_unix_ms INTEGER NOT NULL,
      updated_at_unix_ms INTEGER NOT NULL,
      last_message_preview TEXT NOT NULL DEFAULT ''
    );
    INSERT INTO agents VALUES ('a1', 'Agent', '', 'ready', NULL, 1);
    INSERT INTO conversations VALUES ('c1', 'Old chat', 1, 1, 'legacy');
    """
)
for statement in sql:
    connection.execute(statement)

agent_prompt = connection.execute(
    "SELECT system_prompt FROM agents WHERE id = 'a1'"
).fetchone()[0]
assert agent_prompt == "", f"Legacy agent prompt should default to empty: {agent_prompt!r}"
legacy_chat = connection.execute(
    "SELECT agent_id, last_message_preview FROM conversations WHERE id = 'c1'"
).fetchone()
assert legacy_chat == (None, "legacy"), legacy_chat

connection.execute(
    "UPDATE conversations SET agent_id = 'a1' WHERE id = 'c1'"
)
assert connection.execute(
    "SELECT agent_id FROM conversations WHERE id = 'c1'"
).fetchone()[0] == "a1"
connection.execute("DELETE FROM agents WHERE id = 'a1'")
assert connection.execute(
    "SELECT agent_id FROM conversations WHERE id = 'c1'"
).fetchone()[0] is None
connection.close()
print(
    "Agent persona SQLite migration PASS: legacy rows preserved, empty prompt "
    "defaulted, conversation binding persisted, delete safely unbound chats"
)
