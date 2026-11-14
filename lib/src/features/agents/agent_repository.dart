import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'agent_record.dart';

abstract interface class AgentStore {
  Future<void> create(AgentRecord agent);
  Future<List<AgentRecord>> list();
  Future<AgentRecord?> getById(String id);
  Future<void> updateStatus(String id, AgentRecordStatus status);
  Future<void> updateModel(String id, String? modelId);
  Future<void> updateSystemPrompt(String id, String systemPrompt);
  Future<void> delete(String id);
}

class AgentRepository implements AgentStore {
  AgentRepository({LocalDatabase? database})
      : _localDatabase = database ?? LocalDatabase.instance;

  final LocalDatabase _localDatabase;

  @override
  Future<void> create(AgentRecord agent) async {
    final systemPrompt = agent.systemPrompt.trim();
    if (systemPrompt.length > 3000) {
      throw ArgumentError.value(
        agent.systemPrompt,
        'systemPrompt',
        'Agent instructions cannot exceed 3000 characters.',
      );
    }
    final db = await _localDatabase.database;
    await db.insert(
      'agents',
      {...agent.toMap(), 'system_prompt': systemPrompt},
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  @override
  Future<List<AgentRecord>> list() async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'agents',
      orderBy: 'created_at_unix_ms DESC',
    );
    return rows.map(AgentRecord.fromMap).toList(growable: false);
  }

  @override
  Future<AgentRecord?> getById(String id) async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'agents',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return AgentRecord.fromMap(rows.single);
  }

  @override
  Future<void> updateStatus(String id, AgentRecordStatus status) async {
    final db = await _localDatabase.database;
    final changed = await db.update(
      'agents',
      {'status': status.name},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) {
      throw StateError('Agent does not exist: $id');
    }
  }

  @override
  Future<void> updateModel(String id, String? modelId) async {
    final db = await _localDatabase.database;
    final changed = await db.update(
      'agents',
      {'model_id': modelId},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) {
      throw StateError('Agent does not exist: $id');
    }
  }

  @override
  Future<void> updateSystemPrompt(String id, String systemPrompt) async {
    final normalized = systemPrompt.trim();
    if (normalized.length > 3000) {
      throw ArgumentError.value(
        systemPrompt,
        'systemPrompt',
        'Agent instructions cannot exceed 3000 characters.',
      );
    }
    final db = await _localDatabase.database;
    final changed = await db.update(
      'agents',
      {'system_prompt': normalized},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) {
      throw StateError('Agent does not exist: $id');
    }
  }

  @override
  Future<void> delete(String id) async {
    final db = await _localDatabase.database;
    await db.delete('agents', where: 'id = ?', whereArgs: [id]);
  }
}
