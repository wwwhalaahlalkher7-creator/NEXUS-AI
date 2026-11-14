enum MessageRole { user, assistant, system, tool }

enum MessageStatus { complete, streaming, cancelled, failed }

class ConversationRecord {
  const ConversationRecord({
    required this.id,
    required this.title,
    required this.createdAtUnixMs,
    required this.updatedAtUnixMs,
    this.lastMessagePreview = '',
    this.agentId,
  });

  final String id;
  final String title;
  final int createdAtUnixMs;
  final int updatedAtUnixMs;
  final String lastMessagePreview;
  final String? agentId;

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'created_at_unix_ms': createdAtUnixMs,
        'updated_at_unix_ms': updatedAtUnixMs,
        'last_message_preview': lastMessagePreview,
        'agent_id': agentId,
      };

  factory ConversationRecord.fromMap(Map<String, Object?> map) {
    return ConversationRecord(
      id: map['id']! as String,
      title: map['title']! as String,
      createdAtUnixMs: map['created_at_unix_ms']! as int,
      updatedAtUnixMs: map['updated_at_unix_ms']! as int,
      lastMessagePreview: map['last_message_preview']! as String,
      agentId: map['agent_id'] as String?,
    );
  }
}

class MessageRecord {
  const MessageRecord({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAtUnixMs,
  });

  final String id;
  final String conversationId;
  final MessageRole role;
  final String content;
  final MessageStatus status;
  final int createdAtUnixMs;

  Map<String, Object?> toMap() => {
        'id': id,
        'conversation_id': conversationId,
        'role': role.name,
        'content': content,
        'status': status.name,
        'created_at_unix_ms': createdAtUnixMs,
      };

  factory MessageRecord.fromMap(Map<String, Object?> map) {
    return MessageRecord(
      id: map['id']! as String,
      conversationId: map['conversation_id']! as String,
      role: MessageRole.values.byName(map['role']! as String),
      content: map['content']! as String,
      status: MessageStatus.values.byName(map['status']! as String),
      createdAtUnixMs: map['created_at_unix_ms']! as int,
    );
  }
}
