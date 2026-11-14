import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'local_data_export_bundle.dart';

class LocalDataPrivacyService {
  LocalDataPrivacyService({LocalDatabase? database})
      : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  static const Map<String, List<String>> _exportTables = {
    'agents': const [],
    'models': [
      'id',
      'display_name',
      'runtime',
      'status',
      'size_bytes',
      'architecture',
      'gguf_model_name',
      'tokenizer_model',
      'context_length',
      'block_count',
      'embedding_length',
      'attention_head_count',
      'attention_head_count_kv',
      'attention_key_length',
      'attention_value_length',
      'file_type',
      'parameter_count',
      'created_at_unix_ms',
      'updated_at_unix_ms',
    ],
    'conversations': const [],
    'messages': const [],
    'knowledge_documents': const [],
    'knowledge_chunks': const [],
    'agent_tasks': const [],
    'agent_task_steps': const [],
    'agent_task_events': const [],
    'benchmark_runs': const [],
    'app_settings': const [],
  };

  Future<Uri?> exportToUserSelectedFile() async {
    final bundle = await buildExportBundle();
    final json = LocalDataExportBundle.encode(bundle);
    final bytes = Uint8List.fromList(utf8.encode(json));
    final stamp = DateTime.now().toUtc().toIso8601String()
        .replaceAll(RegExp(r'[-:]'), '')
        .replaceAll('.', '-')
        .replaceAll('Z', 'Z');
    return FilePicker.saveFile(
      dialogTitle: 'حفظ نسخة بيانات NEXUS المحلية',
      fileName: 'nexus-local-export-$stamp.json',
      bytes: bytes,
      mimeType: 'application/json',
    );
  }

  Future<Map<String, Object?>> buildExportBundle() async {
    final db = await _database.database;
    final tables = <String, List<Map<String, Object?>>>{};
    for (final entry in _exportTables.entries) {
      if (entry.key == 'app_settings') {
        // Never even load the device identity/name settings into the export
        // pipeline. The serializer applies the same allow-list a second time.
        tables[entry.key] = await db.query(
          entry.key,
          where: 'key = ?',
          whereArgs: ['resource_mode'],
          columns: ['key', 'value', 'updated_at_unix_ms'],
        );
      } else {
        tables[entry.key] = await db.query(
          entry.key,
          columns: entry.value.isEmpty ? null : entry.value,
        );
      }
    }
    return LocalDataExportBundle.build(
      exportedAt: DateTime.now().toUtc(),
      tables: tables,
    );
  }

  Future<int> clearConversationHistory() async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final active = await txn.query(
        'messages',
        columns: ['id'],
        where: 'status = ?',
        whereArgs: ['streaming'],
        limit: 1,
      );
      if (active.isNotEmpty) {
        throw StateError('أوقف التوليد الجاري قبل حذف سجل المحادثات.');
      }
      return txn.delete('conversations');
    });
  }

  Future<int> clearKnowledgeLibrary() async {
    final db = await _database.database;
    return db.transaction((txn) async {
      return txn.delete('knowledge_documents');
    });
  }

  Future<int> clearTaskHistory() async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final localRunning = await txn.query(
        'agent_tasks',
        columns: ['id'],
        where: 'status = ?',
        whereArgs: ['running'],
        limit: 1,
      );
      final peerRunning = await txn.query(
        'peer_task_executions',
        columns: ['execution_id'],
        where: 'status IN (?, ?, ?, ?)',
        whereArgs: ['queued', 'awaiting_approval', 'approved', 'running'],
        limit: 1,
      );
      final transfersInFlight = await txn.query(
        'remote_task_transfers',
        columns: ['transfer_id'],
        where: 'status IN (?, ?, ?)',
        whereArgs: ['queued', 'sent', 'pending_review'],
        limit: 1,
      );
      if (localRunning.isNotEmpty ||
          peerRunning.isNotEmpty ||
          transfersInFlight.isNotEmpty) {
        throw StateError(
          'أوقف المهام والتنقلات أو انتظر اكتمال الموافقات قبل حذف السجل.',
        );
      }

      var removed = 0;
      removed += await txn.delete('peer_task_executions');
      removed += await txn.delete('remote_task_transfers');
      removed += await txn.delete('agent_tasks');
      return removed;
    });
  }

  Future<int> clearBenchmarkHistory() async {
    final db = await _database.database;
    return db.delete('benchmark_runs');
  }
}
