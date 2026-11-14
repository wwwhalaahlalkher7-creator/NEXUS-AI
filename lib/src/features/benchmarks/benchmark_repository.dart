import '../../data/local_database.dart';
import 'benchmark_run_record.dart';

class BenchmarkRunRepository {
  BenchmarkRunRepository({LocalDatabase? localDatabase})
      : _localDatabase = localDatabase ?? LocalDatabase.instance;

  final LocalDatabase _localDatabase;

  Future<void> insert(BenchmarkRunRecord run) async {
    final db = await _localDatabase.database;
    await db.insert('benchmark_runs', run.toMap());
  }

  Future<List<BenchmarkRunRecord>> list({String? modelId, int limit = 100}) async {
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit', 'يجب أن يكون بين 1 و500.');
    }
    final db = await _localDatabase.database;
    final rows = await db.query(
      'benchmark_runs',
      where: modelId == null ? null : 'model_id = ?',
      whereArgs: modelId == null ? null : [modelId],
      orderBy: 'completed_at_unix_ms DESC',
      limit: limit,
    );
    return rows.map(BenchmarkRunRecord.fromMap).toList(growable: false);
  }

  Future<void> delete(String id) async {
    final db = await _localDatabase.database;
    await db.delete('benchmark_runs', where: 'id = ?', whereArgs: [id]);
  }
}
