#!/usr/bin/env python3
"""Verify v7 local settings migration preserves existing local app data."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", source)
if not version or int(version.group(1)) < 7:
    raise SystemExit("SQLite database version must be at least 7")

migration = re.search(
    r"Future<void> _createV7SettingsTable\(DatabaseExecutor db\) async \{(.*?)\n\}",
    source,
    re.DOTALL,
)
if not migration:
    raise SystemExit("Could not locate the v7 settings migration")
statement = re.search(r"await db\.execute\('''(.*?)'''\);", migration.group(1), re.DOTALL)
if not statement:
    raise SystemExit("Could not parse the v7 settings SQL")
sql = statement.group(1)

connection = sqlite3.connect(":memory:")
connection.executescript(
    """
    CREATE TABLE conversations (id TEXT PRIMARY KEY, title TEXT NOT NULL);
    CREATE TABLE knowledge_documents (id TEXT PRIMARY KEY, title TEXT NOT NULL);
    INSERT INTO conversations VALUES ('c1', 'legacy chat');
    INSERT INTO knowledge_documents VALUES ('d1', 'existing source');
    """
)
connection.execute(sql)
connection.execute(
    "INSERT INTO app_settings(key, value, updated_at_unix_ms) VALUES (?, ?, ?)",
    ("resource_mode", "unrestricted", 1),
)
assert connection.execute("SELECT title FROM conversations WHERE id='c1'").fetchone()[0] == "legacy chat"
assert connection.execute("SELECT title FROM knowledge_documents WHERE id='d1'").fetchone()[0] == "existing source"
assert connection.execute("SELECT value FROM app_settings WHERE key='resource_mode'").fetchone()[0] == "unrestricted"
connection.execute(
    "INSERT OR REPLACE INTO app_settings(key, value, updated_at_unix_ms) VALUES (?, ?, ?)",
    ("resource_mode", "performance", 2),
)
assert connection.execute("SELECT value FROM app_settings WHERE key='resource_mode'").fetchone()[0] == "performance"
connection.close()
print("Resource settings v7 migration PASS: legacy data preserved and mode preference persisted")
