import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'model_record.dart';

abstract interface class ModelStore {
  Future<void> register(ModelRecord model);
  Future<List<ModelRecord>> list();
  Future<void> updateInstallState(
    String id, {
    required ModelInstallStatus status,
    String? localPath,
    int? sizeBytes,
    String? architecture,
    String? ggufModelName,
    String? tokenizerModel,
    int? contextLength,
    int? blockCount,
    int? embeddingLength,
    int? attentionHeadCount,
    int? attentionHeadCountKv,
    int? attentionKeyLength,
    int? attentionValueLength,
    int? fileType,
    int? parameterCount,
  });
  Future<void> delete(String id);
}

class ModelRepository implements ModelStore {
  ModelRepository({LocalDatabase? database})
      : _localDatabase = database ?? LocalDatabase.instance;

  final LocalDatabase _localDatabase;

  @override
  Future<void> register(ModelRecord model) async {
    final db = await _localDatabase.database;
    await db.insert(
      'models',
      model.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  @override
  Future<List<ModelRecord>> list() async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'models',
      orderBy: 'updated_at_unix_ms DESC',
    );
    return rows.map(ModelRecord.fromMap).toList(growable: false);
  }

  Future<ModelRecord?> getById(String id) async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'models',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ModelRecord.fromMap(rows.single);
  }

  @override
  Future<void> updateInstallState(
    String id, {
    required ModelInstallStatus status,
    String? localPath,
    int? sizeBytes,
    String? architecture,
    String? ggufModelName,
    String? tokenizerModel,
    int? contextLength,
    int? blockCount,
    int? embeddingLength,
    int? attentionHeadCount,
    int? attentionHeadCountKv,
    int? attentionKeyLength,
    int? attentionValueLength,
    int? fileType,
    int? parameterCount,
  }) async {
    final db = await _localDatabase.database;
    final changed = await db.update(
      'models',
      {
        'status': status.name,
        'local_path': localPath,
        'size_bytes': sizeBytes,
        'architecture': architecture,
        'gguf_model_name': ggufModelName,
        'tokenizer_model': tokenizerModel,
        'context_length': contextLength,
        'block_count': blockCount,
        'embedding_length': embeddingLength,
        'attention_head_count': attentionHeadCount,
        'attention_head_count_kv': attentionHeadCountKv,
        'attention_key_length': attentionKeyLength,
        'attention_value_length': attentionValueLength,
        'file_type': fileType,
        'parameter_count': parameterCount,
        'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) {
      throw StateError('Model does not exist: $id');
    }
  }

  @override
  Future<void> delete(String id) async {
    final db = await _localDatabase.database;
    await db.transaction((transaction) async {
      // Agent.model_id is intentionally a soft reference so older databases
      // can be upgraded without rebuilding the agents table. Clear it before
      // deleting the catalog row to avoid dangling assignments.
      await transaction.update(
        'agents',
        {'model_id': null},
        where: 'model_id = ?',
        whereArgs: [id],
      );
      await transaction.delete('models', where: 'id = ?', whereArgs: [id]);
    });
  }
}
