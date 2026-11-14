#!/usr/bin/env python3
"""Execute and validate SQLite v15 benchmark-run table creation."""
from pathlib import Path
import re
import sqlite3
import textwrap

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
version = re.search(r"_databaseVersion\s*=\s*(\d+)", source)
if not version or int(version.group(1)) != 15:
    raise SystemExit("Expected SQLite schema v15")

match = re.search(
    r"Future<void> _createV15BenchmarkRuns\(DatabaseExecutor db\) async \{\s*"
    r"await db\.execute\('''(.*?)'''\);(.*?)\n\}",
    source,
    re.S,
)
if not match:
    raise SystemExit("Could not locate v15 benchmark_runs migration")
create_sql = textwrap.dedent(match.group(1)).strip()
index_sql = match.group(2)
if "if (oldVersion < 15)" not in source or "await _createV15BenchmarkRuns(db)" not in source:
    raise SystemExit("v15 migration is not connected to upgrade path")
if source.count("await _createV15BenchmarkRuns(db)") < 2:
    raise SystemExit("v15 migration must run for both new and upgraded databases")

required_columns = [
    "first_load_ms", "repeat_load_ms", "generation_elapsed_ms", "generated_tokens",
    "tokens_per_second", "peak_resident_bytes", "cancel_latency_ms",
    "starting_thermal_status", "ending_thermal_status", "peak_thermal_status",
    "starting_battery_percent", "ending_battery_percent", "runtime_version", "status",
]
for column in required_columns:
    if column not in create_sql:
        raise SystemExit(f"Missing benchmark column: {column}")
if "FOREIGN KEY" in create_sql.upper() or "REFERENCES MODELS" in create_sql.upper():
    raise SystemExit("Benchmark history must survive model-catalog deletion")

with sqlite3.connect(":memory:") as db:
    db.execute(create_sql)
    if "idx_benchmark_runs_completed" not in index_sql or "idx_benchmark_runs_model_completed" not in index_sql:
        raise SystemExit("Benchmark history indexes are missing")
    db.execute(
        "CREATE INDEX idx_benchmark_runs_completed "
        "ON benchmark_runs(completed_at_unix_ms DESC)"
    )
    db.execute(
        "CREATE INDEX idx_benchmark_runs_model_completed "
        "ON benchmark_runs(model_id, completed_at_unix_ms DESC)"
    )
    db.execute(
        """INSERT INTO benchmark_runs (
          id, model_id, model_name, context_tokens, cpu_threads,
          started_at_unix_ms, completed_at_unix_ms, generated_tokens,
          cancellation_observed, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        ("run-1", "deleted-model-id", "Local model", 2048, 4, 10, 20, 32, 0, "partial"),
    )
    row = db.execute(
        "SELECT model_id, generated_tokens, status FROM benchmark_runs WHERE id='run-1'"
    ).fetchone()
    if row != ("deleted-model-id", 32, "partial"):
        raise SystemExit("Benchmark record did not round-trip")
    for invalid in [
        ("bad-context", "m", "M", 128, 2, 10, 20, 0, 0, "completed"),
        ("bad-threads", "m", "M", 2048, 9, 10, 20, 0, 0, "completed"),
        ("bad-state", "m", "M", 2048, 2, 10, 20, 0, 0, "running"),
    ]:
        try:
            db.execute(
                """INSERT INTO benchmark_runs (
                  id, model_id, model_name, context_tokens, cpu_threads,
                  started_at_unix_ms, completed_at_unix_ms, generated_tokens,
                  cancellation_observed, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                invalid,
            )
        except sqlite3.IntegrityError:
            continue
        raise SystemExit(f"Schema accepted invalid benchmark row: {invalid[0]}")

print("Benchmark SQLite v15 migration PASS: creation, indexes, history, constraints")
