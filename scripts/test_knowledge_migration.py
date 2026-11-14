#!/usr/bin/env python3
"""Exercise the v6 local knowledge schema and migration contract in SQLite."""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"static const _databaseVersion = (\d+);", SOURCE)
if not version or int(version.group(1)) < 6:
    raise SystemExit("SQLite database version must be at least 6")

migration = re.search(
    r"Future<void> _createV6KnowledgeTables\(DatabaseExecutor db\) async \{(.*?)\n\}",
    SOURCE,
    re.DOTALL,
)
if not migration:
    raise SystemExit("Could not locate _createV6KnowledgeTables")
body = migration.group(1)
statements = re.findall(r"await db\.execute\('''(.*?)'''\);", body, re.DOTALL)
if len(statements) != 2:
    raise SystemExit(f"Expected 2 v6 table statements, found {len(statements)}")
for required in (
    "CREATE TABLE knowledge_documents",
    "CREATE TABLE knowledge_chunks",
    "content_hash TEXT NOT NULL UNIQUE",
    "FOREIGN KEY(document_id) REFERENCES knowledge_documents(id) ON DELETE CASCADE",
    "UNIQUE(document_id, ordinal)",
    "idx_knowledge_documents_imported",
    "idx_knowledge_chunks_document_ordinal",
    "if (oldVersion < 6)",
    "await _createV6KnowledgeTables(db)",
):
    if required not in SOURCE:
        raise SystemExit(f"Missing knowledge migration contract: {required}")

connection = sqlite3.connect(":memory:")
connection.execute("PRAGMA foreign_keys = ON")
# Simulate a populated v5 database: adding v6 must not rebuild or discard
# the existing app tables and records.
connection.executescript(
    """
    CREATE TABLE agents (id TEXT PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE models (id TEXT PRIMARY KEY, display_name TEXT NOT NULL);
    CREATE TABLE conversations (id TEXT PRIMARY KEY, title TEXT NOT NULL);
    CREATE TABLE messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL);
    INSERT INTO agents VALUES ('a1', 'legacy-agent');
    INSERT INTO models VALUES ('m1', 'legacy-model');
    INSERT INTO conversations VALUES ('c1', 'legacy-chat');
    INSERT INTO messages VALUES ('msg1', 'c1');
    """
)
for statement in statements:
    connection.execute(statement)
assert connection.execute("SELECT name FROM agents WHERE id='a1'").fetchone()[0] == "legacy-agent"
assert connection.execute("SELECT display_name FROM models WHERE id='m1'").fetchone()[0] == "legacy-model"
assert connection.execute("SELECT title FROM conversations WHERE id='c1'").fetchone()[0] == "legacy-chat"
assert connection.execute("SELECT conversation_id FROM messages WHERE id='msg1'").fetchone()[0] == "c1"
connection.executescript(
    """
    CREATE INDEX idx_knowledge_documents_imported
      ON knowledge_documents(imported_at_unix_ms DESC);
    CREATE INDEX idx_knowledge_chunks_document_ordinal
      ON knowledge_chunks(document_id, ordinal ASC);
    INSERT INTO knowledge_documents VALUES
      ('d1', 'مرجع أقدم', 'source.md', 'md', '1234abcd', 10, 1, 10);
    INSERT INTO knowledge_chunks VALUES
      ('c1', 'd1', 0, 'alpha beta', ' alpha beta ', 2, 10);
    INSERT INTO knowledge_documents VALUES
      ('d2', 'مرجع أحدث', 'recent.md', 'md', '5678efgh', 5, 1, 20);
    INSERT INTO knowledge_chunks VALUES
      ('c2', 'd2', 0, 'alpha only', ' alpha only ', 2, 10);
    """
)
try:
    connection.execute(
        "INSERT INTO knowledge_documents VALUES "
        "('d3', 'مكرر', 'copy.md', 'md', '1234abcd', 5, 1, 11)"
    )
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError("Duplicate content hash was accepted")
try:
    connection.execute(
        "INSERT INTO knowledge_chunks VALUES "
        "('c3', 'missing', 0, 'x', ' x ', 1, 1)"
    )
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError("Orphan knowledge chunk was accepted")
# Mirror the repository's ranked pre-ranking query: matching more distinct
# query terms wins over a newer but weaker candidate. The live repository
# computes its LIMIT from the active device memory snapshot.
terms = ["alpha", "beta"]
where_clause = " OR ".join(["c.normalized_content LIKE ?"] * len(terms))
ranking_clause = " + ".join(
    ["CASE WHEN c.normalized_content LIKE ? THEN 1 ELSE 0 END"] * len(terms)
)
arguments = [f"% {term} %" for term in terms]
ranked = connection.execute(
    f"""
    SELECT c.id
    FROM knowledge_chunks AS c
    INNER JOIN knowledge_documents AS d ON d.id = c.document_id
    WHERE {where_clause}
    ORDER BY ({ranking_clause}) DESC, d.imported_at_unix_ms DESC
    """,
    [*arguments, *arguments],
).fetchall()
assert [row[0] for row in ranked] == ["c1", "c2"], ranked

connection.execute("DELETE FROM knowledge_documents WHERE id = 'd1'")
remaining = connection.execute("SELECT COUNT(*) FROM knowledge_chunks").fetchone()[0]
assert remaining == 1, f"Document cascade left {remaining} chunks instead of 1"
assert connection.execute(
    "SELECT COUNT(*) FROM knowledge_chunks WHERE id='c1'"
).fetchone()[0] == 0
connection.execute("DELETE FROM knowledge_documents WHERE id = 'd2'")
assert connection.execute("SELECT COUNT(*) FROM knowledge_chunks").fetchone()[0] == 0
connection.close()
print(
    "Knowledge SQLite v6 migration PASS: legacy v5 rows preserved, tables "
    "created, term ranking verified, duplicate content rejected, FK/cascade verified"
)
