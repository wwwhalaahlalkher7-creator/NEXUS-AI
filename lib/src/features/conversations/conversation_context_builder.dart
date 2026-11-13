import 'dart:convert';

import 'conversation_record.dart';

/// Result of selecting the recent, durable messages to send to the model.
class ConversationContextSelection {
  const ConversationContextSelection({
    required this.messages,
    required this.droppedMessages,
  });

  final List<ConversationContextMessage> messages;
  final int droppedMessages;
}

/// A role-aware message independent from the generated Rust bridge DTO.
class ConversationContextMessage {
  const ConversationContextMessage({
    required this.role,
    required this.content,
  });

  final String role;
  final String content;
}

/// Selects completed messages and applies a hard transport budget.
/// The native engine performs the final tokenizer-accurate context-window trim.
class ConversationContextBuilder {
  const ConversationContextBuilder._();

  static ConversationContextSelection build(
    Iterable<MessageRecord> records, {
    int maxMessages = 64,
    int maxBytes = 48 * 1024,
  }) {
    if (maxMessages < 1 || maxBytes < 1) {
      throw ArgumentError('Context limits must be positive.');
    }

    final messages = records
        .where((record) =>
            record.status == MessageStatus.complete &&
            record.content.trim().isNotEmpty &&
            (record.role == MessageRole.system ||
                record.role == MessageRole.user ||
                record.role == MessageRole.assistant ||
                record.role == MessageRole.tool))
        .map((record) => ConversationContextMessage(
              role: record.role.name,
              content: record.content,
            ))
        .toList();

    if (messages.isEmpty || messages.last.role != MessageRole.user.name) {
      throw StateError(
        'The current turn must end with a completed user message.',
      );
    }

    int byteLength() => messages.fold<int>(
          0,
          (total, message) => total + utf8.encode(message.content).length,
        );

    var dropped = 0;
    while (messages.length > maxMessages || byteLength() > maxBytes) {
      final oldestIndex = messages.indexWhere(
        (message) => message.role != MessageRole.system.name,
      );
      if (oldestIndex < 0 || oldestIndex == messages.length - 1) {
        throw StateError(
          'The current user message alone exceeds the safe context '
          'transport budget.',
        );
      }

      var end = oldestIndex + 1;
      if (messages[oldestIndex].role == MessageRole.user.name &&
          end < messages.length - 1 &&
          messages[end].role == MessageRole.assistant.name) {
        end++;
      }
      dropped += end - oldestIndex;
      messages.removeRange(oldestIndex, end);
    }

    return ConversationContextSelection(
      messages: List.unmodifiable(messages),
      droppedMessages: dropped,
    );
  }
}
