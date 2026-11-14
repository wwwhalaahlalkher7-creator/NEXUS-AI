import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  static const _databaseName = 'nexus_local.db';
  static const _databaseVersion = 10;

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
        await _upgradeV5AgentPersona(db);
        await _createV6KnowledgeTables(db);
        await _createV7SettingsTable(db);
        await _createV8OrchestrationTables(db);
        await _createV9PairedDeviceTables(db);
        await _createV10TaskTransferTables(db);
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
        if (oldVersion < 5) {
          await _upgradeV5AgentPersona(db);
        }
        if (oldVersion < 6) {
          await _createV6KnowledgeTables(db);
        }
        if (oldVersion < 7) {
          await _createV7SettingsTable(db);
        }
        if (oldVersion < 8) {
          await _createV8OrchestrationTables(db);
        }
        if (oldVersion < 9) {
          await _createV9PairedDeviceTables(db);
        }
        if (oldVersion < 10) {
          await _createV10TaskTransferTables(db);
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

/// Adds durable agent instructions and binds each conversation to its agent.
/// Existing agents and conversations are retained; old chats remain general.
Future<void> _upgradeV5AgentPersona(DatabaseExecutor db) async {
  await db.execute(
    "ALTER TABLE agents ADD COLUMN system_prompt TEXT NOT NULL DEFAULT ''",
  );
  await db.execute(
    'ALTER TABLE conversations ADD COLUMN agent_id TEXT '
    'REFERENCES agents(id) ON DELETE SET NULL',
  );
  await db.execute(
    'CREATE INDEX idx_conversations_agent_id ON conversations(agent_id)',
  );
}


/// Adds the local knowledge library. Only bounded text chunks and normalized
/// search tokens are stored; original files are never copied into app storage.
Future<void> _createV6KnowledgeTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE knowledge_documents (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      file_name TEXT NOT NULL,
      source_type TEXT NOT NULL CHECK(source_type IN ('txt', 'md')),
      content_hash TEXT NOT NULL UNIQUE,
      char_count INTEGER NOT NULL CHECK(char_count > 0),
      chunk_count INTEGER NOT NULL CHECK(chunk_count > 0),
      imported_at_unix_ms INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_knowledge_documents_imported '
    'ON knowledge_documents(imported_at_unix_ms DESC)',
  );
  await db.execute('''
    CREATE TABLE knowledge_chunks (
      id TEXT PRIMARY KEY NOT NULL,
      document_id TEXT NOT NULL,
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      content TEXT NOT NULL,
      normalized_content TEXT NOT NULL,
      token_count INTEGER NOT NULL CHECK(token_count > 0),
      char_count INTEGER NOT NULL CHECK(char_count > 0),
      FOREIGN KEY(document_id) REFERENCES knowledge_documents(id) ON DELETE CASCADE,
      UNIQUE(document_id, ordinal)
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_knowledge_chunks_document_ordinal '
    'ON knowledge_chunks(document_id, ordinal ASC)',
  );
}


/// Stores local preferences without adding a remote account or service.
Future<void> _createV7SettingsTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE app_settings (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL,
      updated_at_unix_ms INTEGER NOT NULL
    )
  ''');
}


/// Persists multi-agent plans, ordered work steps and an append-only trace.
/// Step outputs remain local and are cascaded when a task is deleted.
Future<void> _createV8OrchestrationTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE agent_tasks (
      id TEXT PRIMARY KEY NOT NULL,
      goal TEXT NOT NULL,
      planner_agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
      status TEXT NOT NULL CHECK(status IN ('planned', 'running', 'completed', 'failed', 'cancelled', 'interrupted')),
      plan_json TEXT NOT NULL,
      error TEXT,
      created_at_unix_ms INTEGER NOT NULL,
      updated_at_unix_ms INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_agent_tasks_updated '
    'ON agent_tasks(updated_at_unix_ms DESC)',
  );
  await db.execute('''
    CREATE TABLE agent_task_steps (
      id TEXT PRIMARY KEY NOT NULL,
      task_id TEXT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE,
      step_key TEXT NOT NULL,
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
      objective TEXT NOT NULL,
      expected_output TEXT NOT NULL DEFAULT '',
      depends_on_json TEXT NOT NULL DEFAULT '[]',
      status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'succeeded', 'failed', 'blocked', 'cancelled', 'interrupted')),
      output_text TEXT NOT NULL DEFAULT '',
      error TEXT,
      started_at_unix_ms INTEGER,
      finished_at_unix_ms INTEGER,
      UNIQUE(task_id, step_key),
      UNIQUE(task_id, ordinal)
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_agent_task_steps_task_order '
    'ON agent_task_steps(task_id, ordinal ASC)',
  );
  await db.execute('''
    CREATE TABLE agent_task_events (
      id TEXT PRIMARY KEY NOT NULL,
      task_id TEXT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE,
      step_key TEXT,
      event_type TEXT NOT NULL,
      message TEXT NOT NULL,
      payload_json TEXT NOT NULL DEFAULT '{}',
      created_at_unix_ms INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_agent_task_events_task_time '
    'ON agent_task_events(task_id, created_at_unix_ms ASC)',
  );
}


/// Stores explicitly paired local peers. Pairing secrets are never stored in
/// SQLite; they live in platform secure storage and are removed on unpair.
Future<void> _createV9PairedDeviceTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE paired_devices (
      id TEXT PRIMARY KEY NOT NULL,
      display_name TEXT NOT NULL,
      platform TEXT NOT NULL,
      last_address TEXT NOT NULL,
      last_port INTEGER NOT NULL,
      fingerprint TEXT NOT NULL,
      capabilities_json TEXT NOT NULL DEFAULT '{}',
      trust_status TEXT NOT NULL CHECK(trust_status IN ('paired', 'blocked')),
      paired_at_unix_ms INTEGER NOT NULL,
      last_seen_unix_ms INTEGER NOT NULL,
      created_at_unix_ms INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_paired_devices_last_seen '
    'ON paired_devices(last_seen_unix_ms DESC)',
  );
  await db.execute('''
    CREATE TABLE device_events (
      id TEXT PRIMARY KEY NOT NULL,
      device_id TEXT NOT NULL REFERENCES paired_devices(id) ON DELETE CASCADE,
      event_type TEXT NOT NULL,
      message TEXT NOT NULL,
      created_at_unix_ms INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_device_events_device_time '
    'ON device_events(device_id, created_at_unix_ms DESC)',
  );
}


/// Persists encrypted task-proposal envelopes exchanged with explicitly paired
/// devices. Incoming proposals are stored only after per-transfer user consent
/// and never become executable tasks automatically.
Future<void> _createV10TaskTransferTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE remote_task_transfers (
      transfer_id TEXT PRIMARY KEY NOT NULL,
      device_id TEXT NOT NULL REFERENCES paired_devices(id) ON DELETE CASCADE,
      direction TEXT NOT NULL CHECK(direction IN ('outgoing', 'incoming')),
      status TEXT NOT NULL CHECK(status IN ('queued', 'sent', 'pending_review', 'kept', 'declined', 'rejected')),
      source_task_id TEXT NOT NULL,
      goal TEXT NOT NULL,
      plan_json TEXT NOT NULL,
      payload_sha256 TEXT NOT NULL,
      created_at_unix_ms INTEGER NOT NULL,
      updated_at_unix_ms INTEGER NOT NULL,
      last_error TEXT
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_remote_task_transfers_device_time '
    'ON remote_task_transfers(device_id, created_at_unix_ms DESC)',
  );
  await db.execute(
    'CREATE INDEX idx_remote_task_transfers_direction_status '
    'ON remote_task_transfers(direction, status, updated_at_unix_ms DESC)',
  );
}
