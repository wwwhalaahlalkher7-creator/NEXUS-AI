#!/usr/bin/env python3
"""Verify SQLite v14 adds GGUF attention metadata without losing models."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", source)
if not version or int(version.group(1)) != 15:
    raise SystemExit("Expected current SQLite schema v15")

migration = re.search(
    r"Future<void> _upgradeV14ModelAttentionMetadata\(DatabaseExecutor db\) async \{(.*?)\n\}",
    source,
    re.DOTALL,
)
if not migration:
    raise SystemExit("Could not locate v14 model attention metadata migration")
statements = re.findall(r"await db\.execute\('([^']+)'\);", migration.group(1))
expected_columns = (
    "attention_head_count",
    "attention_head_count_kv",
    "attention_key_length",
    "attention_value_length",
)
if len(statements) != 4 or not all(
    any(f"ADD COLUMN {column} INTEGER" in statement for statement in statements)
    for column in expected_columns
):
    raise SystemExit("v14 migration must add all four nullable attention dimensions")
if "if (oldVersion < 14)" not in source or "await _upgradeV14ModelAttentionMetadata(db)" not in source:
    raise SystemExit("v14 migration is not wired to upgrade and create paths")

connection = sqlite3.connect(":memory:")
connection.execute(
    """CREATE TABLE models (
      id TEXT PRIMARY KEY NOT NULL,
      display_name TEXT NOT NULL,
      architecture TEXT,
      block_count INTEGER,
      embedding_length INTEGER
    )"""
)
connection.execute(
    "INSERT INTO models VALUES ('legacy-model', 'Legacy GGUF', 'llama', 32, 4096)"
)
for statement in statements:
    connection.execute(statement)
legacy = connection.execute(
    "SELECT display_name, architecture, block_count, embedding_length, "
    "attention_head_count, attention_head_count_kv, attention_key_length, attention_value_length "
    "FROM models WHERE id='legacy-model'"
).fetchone()
assert legacy == ("Legacy GGUF", "llama", 32, 4096, None, None, None, None), legacy
connection.execute(
    "UPDATE models SET attention_head_count=?, attention_head_count_kv=?, "
    "attention_key_length=?, attention_value_length=? WHERE id=?",
    (32, 8, 128, 128, "legacy-model"),
)
assert connection.execute(
    "SELECT attention_head_count, attention_head_count_kv, attention_key_length, attention_value_length "
    "FROM models WHERE id='legacy-model'"
).fetchone() == (32, 8, 128, 128)
connection.close()
print("Model-fit SQLite migration PASS: v14 GGUF attention migration retained under schema v15; legacy model rows preserved")
