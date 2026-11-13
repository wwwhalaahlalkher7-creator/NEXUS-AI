import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  static const _databaseName = 'nexus_local.db';
  static const _databaseVersion = 4;

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
        await _createAgentsTable(db);
        await _createV2Tables(db);
        await _upgradeV3Models(db);
        await _upgradeV4MessageStatus(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createV2Tables(db);
        }
        if (oldVersion < 3) {
          await _upgradeV3Models(db);
        }
        if (oldVersion < 4) {
          await _upgradeV4MessageStatus(db);
        }
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

Future<void> _createAgentsTable(DatabaseExecutor db) async {
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
}

Future<void> _createV2Tables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE models (
      id TEXT PRIMARY KEY NOT NULL,
      display_name TEXT NOT NULL,
      runtime TEXT NOT NULL CHECK(runtime IN ('llamaCpp', 'external')),
      local_path TEXT,
      status TEXT NOT NULL CHECK(status IN ('registered', 'installed', 'unavailable')),
      size_bytes INTEGER,
      created_at_unix_ms INTEGER NOT NULL,
      updated_at_unix_ms INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_models_updated_at ON models(updated_at_unix_ms DESC)',
  );

  await db.execute('''
    CREATE TABLE conversations (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      created_at_unix_ms INTEGER NOT NULL,
      updated_at_unix_ms INTEGER NOT NULL,
      last_message_preview TEXT NOT NULL DEFAULT ''
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_conversations_updated_at '
    'ON conversations(updated_at_unix_ms DESC)',
  );

  await db.execute('''
    CREATE TABLE messages (
      id TEXT PRIMARY KEY NOT NULL,
      conversation_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'system', 'tool')),
      content TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('complete', 'streaming', 'failed')),
      created_at_unix_ms INTEGER NOT NULL,
      FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_messages_conversation_created '
    'ON messages(conversation_id, created_at_unix_ms ASC)',
  );
}


Future<void> _upgradeV3Models(DatabaseExecutor db) async {
  await db.execute('ALTER TABLE models ADD COLUMN architecture TEXT');
  await db.execute('ALTER TABLE models ADD COLUMN gguf_model_name TEXT');
  await db.execute('ALTER TABLE models ADD COLUMN tokenizer_model TEXT');
  await db.execute('ALTER TABLE models ADD COLUMN context_length INTEGER');
  await db.execute('ALTER TABLE models ADD COLUMN block_count INTEGER');
  await db.execute('ALTER TABLE models ADD COLUMN embedding_length INTEGER');
  await db.execute('ALTER TABLE models ADD COLUMN file_type INTEGER');
  await db.execute('ALTER TABLE models ADD COLUMN parameter_count INTEGER');
}

/// Rebuilds the messages table to add an explicit cancelled terminal state.
/// Existing messages and their conversation foreign-key relation are preserved.
Future<void> _upgradeV4MessageStatus(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE messages_v4 (
      id TEXT PRIMARY KEY NOT NULL,
      conversation_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'system', 'tool')),
      content TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('complete', 'streaming', 'cancelled', 'failed')),
      created_at_unix_ms INTEGER NOT NULL,
      FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    INSERT INTO messages_v4 (
      id, conversation_id, role, content, status, created_at_unix_ms
    )
    SELECT id, conversation_id, role, content, status, created_at_unix_ms
    FROM messages
  ''');
  await db.execute('DROP TABLE messages');
  await db.execute('ALTER TABLE messages_v4 RENAME TO messages');
  await db.execute(
    'CREATE INDEX idx_messages_conversation_created '
    'ON messages(conversation_id, created_at_unix_ms ASC)',
  );
}
