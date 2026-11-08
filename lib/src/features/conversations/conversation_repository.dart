import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'conversation_record.dart';

class ConversationRepository {
  ConversationRepository({LocalDatabase? database})
      : _localDatabase = database ?? LocalDatabase.instance;

  final LocalDatabase _localDatabase;

  Future<ConversationRecord> create({String title = 'محادثة جديدة'}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'conversation-${DateTime.now().microsecondsSinceEpoch}';
    final record = ConversationRecord(
      id: id,
      title: title.trim().isEmpty ? 'محادثة جديدة' : title.trim(),
      createdAtUnixMs: now,
      updatedAtUnixMs: now,
    );
    final db = await _localDatabase.database;
    await db.insert(
      'conversations',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return record;
  }

  Future<List<ConversationRecord>> list() async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'conversations',
      orderBy: 'updated_at_unix_ms DESC',
    );
    return rows.map(ConversationRecord.fromMap).toList(growable: false);
  }

  Future<List<MessageRecord>> messages(String conversationId) async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at_unix_ms ASC, id ASC',
    );
    return rows.map(MessageRecord.fromMap).toList(growable: false);
  }

  Future<MessageRecord> appendMessage({
    required String conversationId,
    required MessageRole role,
    required String content,
    MessageStatus status = MessageStatus.complete,
  }) async {
    final normalized = content.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(content, 'content', 'Message cannot be empty');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final record = MessageRecord(
      id: 'message-${DateTime.now().microsecondsSinceEpoch}',
      conversationId: conversationId,
      role: role,
      content: normalized,
      status: status,
      createdAtUnixMs: now,
    );
    final db = await _localDatabase.database;

    await db.transaction((txn) async {
      final conversations = await txn.query(
        'conversations',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [conversationId],
        limit: 1,
      );
      if (conversations.isEmpty) {
        throw StateError('Conversation does not exist: $conversationId');
      }

      await txn.insert(
        'messages',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      final preview = normalized.replaceAll(RegExp(r'\s+'), ' ');
      await txn.update(
        'conversations',
        {
          'updated_at_unix_ms': now,
          'last_message_preview':
              preview.length > 160 ? '${preview.substring(0, 157)}...' : preview,
        },
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    });
    return record;
  }

  Future<void> delete(String conversationId) async {
    final db = await _localDatabase.database;
    await db.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }
}
