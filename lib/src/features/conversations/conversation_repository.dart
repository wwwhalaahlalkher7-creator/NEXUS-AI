import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'conversation_record.dart';

class ConversationRepository {
  ConversationRepository({LocalDatabase? database})
      : _localDatabase = database ?? LocalDatabase.instance;

  final LocalDatabase _localDatabase;

  Future<ConversationRecord> create({
    String title = 'محادثة جديدة',
    String? agentId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'conversation-${DateTime.now().microsecondsSinceEpoch}';
    final normalizedTitle = _normalizeTitle(title);
    final record = ConversationRecord(
      id: id,
      title: normalizedTitle,
      createdAtUnixMs: now,
      updatedAtUnixMs: now,
      agentId: agentId,
    );
    final db = await _localDatabase.database;
    await db.insert(
      'conversations',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return record;
  }

  Future<ConversationRecord?> get(String conversationId) async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    return rows.isEmpty ? null : ConversationRecord.fromMap(rows.first);
  }

  Future<void> updateAgent(String conversationId, String? agentId) async {
    final db = await _localDatabase.database;
    await db.transaction((txn) async {
      if (agentId != null) {
        final agents = await txn.query(
          'agents',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [agentId],
          limit: 1,
        );
        if (agents.isEmpty) {
          throw StateError('Agent does not exist: $agentId');
        }
      }
      final changed = await txn.update(
        'conversations',
        {'agent_id': agentId},
        where: 'id = ?',
        whereArgs: [conversationId],
      );
      if (changed != 1) {
        throw StateError('Conversation does not exist: $conversationId');
      }
    });
  }

  Future<List<ConversationRecord>> list() async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'conversations',
      orderBy: 'updated_at_unix_ms DESC, id DESC',
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
    if (status == MessageStatus.streaming) {
      throw ArgumentError.value(
        status,
        'status',
        'Use createAssistantDraft for streaming messages',
      );
    }

    final record = _newMessage(
      conversationId: conversationId,
      role: role,
      content: normalized,
      status: status,
    );
    await _insertMessageAndUpdateConversation(record);
    return record;
  }

  Future<MessageRecord> createAssistantDraft(String conversationId) async {
    final record = _newMessage(
      conversationId: conversationId,
      role: MessageRole.assistant,
      content: '',
      status: MessageStatus.streaming,
    );
    final db = await _localDatabase.database;
    await db.transaction((txn) async {
      await _requireConversation(txn, conversationId);
      await txn.insert(
        'messages',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      await txn.update(
        'conversations',
        {'updated_at_unix_ms': record.createdAtUnixMs},
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    });
    return record;
  }

  /// Persists a streaming checkpoint or final message state.
  /// Empty content is allowed only while a message is still streaming.
  Future<void> updateMessage({
    required String messageId,
    required String conversationId,
    required String content,
    required MessageStatus status,
  }) async {
    if (status != MessageStatus.streaming && content.trim().isEmpty) {
      throw ArgumentError.value(
        content,
        'content',
        'Final message cannot be empty',
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final normalized = content.trim();
    final db = await _localDatabase.database;
    await db.transaction((txn) async {
      final updated = await txn.update(
        'messages',
        {'content': content, 'status': status.name},
        where: 'id = ? AND conversation_id = ?',
        whereArgs: [messageId, conversationId],
      );
      if (updated != 1) {
        throw StateError('Message does not exist: $messageId');
      }
      final values = <String, Object?>{'updated_at_unix_ms': now};
      if (normalized.isNotEmpty) {
        values['last_message_preview'] = _preview(normalized);
      }
      await txn.update(
        'conversations',
        values,
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    });
  }

  /// Converts unfinished messages from a previous process into recoverable
  /// failures.
  Future<int> recoverInterruptedMessages() async {
    final db = await _localDatabase.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['id', 'conversation_id', 'content'],
        where: 'status = ?',
        whereArgs: [MessageStatus.streaming.name],
      );
      for (final row in rows) {
        final conversationId = row['conversation_id']! as String;
        final content = (row['content'] as String?)?.trim() ?? '';
        final recoveredContent = content.isEmpty
            ? 'توقف التوليد قبل اكتماله ولم تُسجّل نتيجته.'
            : content;
        await txn.update(
          'messages',
          {
            'content': recoveredContent,
            'status': MessageStatus.failed.name,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        await txn.update(
          'conversations',
          {
            'updated_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
            'last_message_preview': _preview(recoveredContent),
          },
          where: 'id = ?',
          whereArgs: [conversationId],
        );
      }
      return rows.length;
    });
  }

  Future<void> delete(String conversationId) async {
    final db = await _localDatabase.database;
    await db.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> _insertMessageAndUpdateConversation(MessageRecord record) async {
    final db = await _localDatabase.database;
    await db.transaction((txn) async {
      await _requireConversation(txn, record.conversationId);
      await txn.insert(
        'messages',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      await txn.update(
        'conversations',
        {
          'updated_at_unix_ms': record.createdAtUnixMs,
          'last_message_preview': _preview(record.content),
        },
        where: 'id = ?',
        whereArgs: [record.conversationId],
      );
    });
  }

  Future<void> _requireConversation(
    Transaction txn,
    String conversationId,
  ) async {
    final rows = await txn.query(
      'conversations',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Conversation does not exist: $conversationId');
    }
  }

  MessageRecord _newMessage({
    required String conversationId,
    required MessageRole role,
    required String content,
    required MessageStatus status,
  }) {
    return MessageRecord(
      id: 'message-${DateTime.now().microsecondsSinceEpoch}',
      conversationId: conversationId,
      role: role,
      content: content,
      status: status,
      createdAtUnixMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  String _normalizeTitle(String title) {
    final normalized = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return 'محادثة جديدة';
    return normalized.length > 48
        ? '${normalized.substring(0, 45)}…'
        : normalized;
  }

  String _preview(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length > 160
        ? '${normalized.substring(0, 157)}...'
        : normalized;
  }
}
