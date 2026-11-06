import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'agent_record.dart';

class AgentRepository {
  AgentRepository({LocalDatabase? database})
      : _localDatabase = database ?? LocalDatabase.instance;

  final LocalDatabase _localDatabase;

  Future<void> create(AgentRecord agent) async {
    final db = await _localDatabase.database;
    await db.insert(
      'agents',
      agent.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<List<AgentRecord>> list() async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'agents',
      orderBy: 'created_at_unix_ms DESC',
    );
    return rows.map(AgentRecord.fromMap).toList(growable: false);
  }

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

  Future<void> delete(String id) async {
    final db = await _localDatabase.database;
    await db.delete('agents', where: 'id = ?', whereArgs: [id]);
  }
}
