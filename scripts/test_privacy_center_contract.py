#!/usr/bin/env python3
"""Source contracts for local privacy export and selective deletion."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
service = (ROOT / "lib/src/features/privacy/local_data_privacy_service.dart").read_text(encoding="utf-8")
bundle = (ROOT / "lib/src/features/privacy/local_data_export_bundle.dart").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/privacy/privacy_center_page.dart").read_text(encoding="utf-8")
app = (ROOT / "lib/src/app.dart").read_text(encoding="utf-8")
test = (ROOT / "test/local_data_export_bundle_test.dart").read_text(encoding="utf-8")
database = (ROOT / "lib/src/data/local_database.dart").read_text(encoding="utf-8")
pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")

checks = {
    "privacy center is reachable from the app shell": "PrivacyCenterPage()" in app and "الخصوصية والبيانات المحلية" in app,
    "export includes user-created local data sections": all(
        table in service for table in (
            "agents", "models", "conversations", "messages", "knowledge_documents",
            "knowledge_chunks", "agent_tasks", "agent_task_steps", "agent_task_events",
            "benchmark_runs", "app_settings",
        )
    ),
    "export excludes model filesystem paths at query and serializer layers": "'local_path'" not in service and "sanitized.remove('local_path')" in bundle,
    "export queries and serializes only resource mode settings": "where: 'key = ?'" in service and "whereArgs: ['resource_mode']" in service and "row['key'] == 'resource_mode'" in bundle,
    "export excludes peer network identity and secure-storage ledgers": all(
        omitted in bundle for omitted in (
            "paired_device_addresses_and_fingerprints_included",
            "peer_transfer_and_execution_ledgers_included",
            "secure_storage_secrets_included",
            "device_identity_settings_included",
        )
    ) and "paired_devices" not in service and "peer_task_executions" not in service.split("Future<int> clearTaskHistory")[0],
    "export uses native user-selected JSON save dialog": all(
        item in service for item in ("FilePicker.saveFile", "mimeType: 'application/json'", "bytes: bytes")
    ),
    "cancelled export is not reported as success": "if (saved == null)" in page and "تم إلغاء التصدير" in page,
    "conversation deletion refuses active streaming messages": all(
        item in service for item in ("status = ?", "whereArgs: ['streaming']", "أوقف التوليد الجاري")
    ),
    "task history deletion refuses active executions and in-flight proposals": all(
        item in service for item in ("status = ?", "'running'", "'awaiting_approval'", "'approved'", "'queued'", "'sent'", "'pending_review'", "أوقف المهام والتنقلات")
    ),
    "task history deletion is transactional and clears dependent ledgers": all(
        item in service for item in ("db.transaction", "txn.delete('peer_task_executions')", "txn.delete('remote_task_transfers')", "txn.delete('agent_tasks')")
    ),
    "knowledge deletion relies on document cascade and leaves source files untouched": "txn.delete('knowledge_documents')" in service and "لا يحذف ملفاتك الأصلية" in page,
    "benchmark deletion removes only benchmark records": "db.delete('benchmark_runs')" in service,
    "all destructive actions require explicit confirmation": "showDialog<bool>" in page and "هذا الإجراء لا يمكن التراجع عنه" in page,
    "privacy UI explains preserved models agents pairings and settings": all(
        item in page for item in ("لا يمسح ملفات النماذج GGUF", "إعدادات الوكلاء", "مفاتيح الأجهزة المقترنة")
    ),
    "export bundle records its format and plaintext privacy manifest": all(
        item in bundle for item in ("nexus-local-data-export", "formatVersion", "record_counts", "local_model_paths_included", "encrypted\': false")
    ) and "ملف JSON غير مشفر" in page,
    "tests cover path stripping and private identity omission": all(
        item in test for item in ("local_path", "local_device_id", "paired_devices", "secure_storage_secrets_included")
    ),
    "privacy center adds no schema migration": "_databaseVersion = 15" in database and "_createV15BenchmarkRuns(db)" in database,
    "package version increments without changing native Rust ABI": "version: 2.8.0+59" in pubspec and 'version = "2.6.2"' in (ROOT / "Cargo.toml").read_text(encoding="utf-8"),
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Privacy center contract failures: " + ", ".join(failed))
print(f"Privacy center contract PASS: {len(checks)} checks")
