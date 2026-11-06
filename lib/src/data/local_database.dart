import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  static const _databaseName = 'nexus_local.db';
  static const _databaseVersion = 1;

  Database? _database;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;

    final databasesPath = await getDatabasesPath();
    final path = p.join(databasesPath, _databaseName);
    final opened = await openDatabase(
      path,
      version: _databaseVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE agents (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL CHECK(status IN ('draft', 'ready', 'paused')),
            model_id TEXT,
            created_at_unix_ms INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_agents_created_at ON agents(created_at_unix_ms DESC)',
        );
      },
    );
    _database = opened;
    return opened;
  }

  Future<void> close() async {
    final current = _database;
    _database = null;
    await current?.close();
  }
}
