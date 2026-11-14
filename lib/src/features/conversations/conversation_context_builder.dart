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
    int? maxMessages,
    int? maxBytes,
    String? systemPrompt,
    Iterable<String> additionalSystemPrompts = const [],
    String? userContextSuffix,
  }) {
    if ((maxMessages != null && maxMessages < 1) ||
        (maxBytes != null && maxBytes < 1)) {
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

    final normalizedUserContext = userContextSuffix?.trim();
    if (normalizedUserContext != null && normalizedUserContext.isNotEmpty) {
      final latestUserIndex = messages.lastIndexWhere(
        (message) => message.role == MessageRole.user.name,
      );
      if (latestUserIndex < 0) {
        throw StateError('A user context suffix requires a user turn.');
      }
      final latestUserMessage = messages[latestUserIndex];
      messages[latestUserIndex] = ConversationContextMessage(
        role: latestUserMessage.role,
        content: '${latestUserMessage.content}\n\n$normalizedUserContext',
      );
    }

    final systemPrompts = <String>[
      if (systemPrompt != null) systemPrompt,
      ...additionalSystemPrompts,
    ].map((prompt) => prompt.trim()).where(
      (prompt) => prompt.isNotEmpty,
    );
    final normalizedSystemPrompts = systemPrompts.toList(growable: false);
    if (normalizedSystemPrompts.isNotEmpty) {
      // Keep persona and runtime policy in one system message. Several GGUF
      // chat templates only accept one leading system instruction reliably.
      messages.insert(
        0,
        ConversationContextMessage(
          role: MessageRole.system.name,
          content: normalizedSystemPrompts.join('\n\n'),
        ),
      );
    }

    if (messages.isEmpty ||
        (messages.last.role != MessageRole.user.name &&
            messages.last.role != MessageRole.tool.name)) {
      throw StateError(
        'The current turn must end with a completed user or tool message.',
      );
    }

    var currentTurnStart = messages.lastIndexWhere(
      (message) => message.role == MessageRole.user.name,
    );
    if (currentTurnStart < 0) {
      throw StateError('The context has no current user turn.');
    }

    int byteLength() => messages.fold<int>(
          0,
          (total, message) => total + utf8.encode(message.content).length,
        );

    var dropped = 0;
    while ((maxMessages != null && messages.length > maxMessages) ||
        (maxBytes != null && byteLength() > maxBytes)) {
      final oldestIndex = messages.indexWhere(
        (message) => message.role != MessageRole.system.name,
      );
      if (oldestIndex < 0 || oldestIndex >= currentTurnStart) {
        throw StateError(
          'The current user message alone exceeds the safe context '
          'transport budget.',
        );
      }

      var end = oldestIndex + 1;
      // Drop a complete oldest interaction, including assistant tool-call
      // envelopes and their tool results, rather than leaving orphaned tool
      // messages in the retained prompt.
      while (end < currentTurnStart &&
          messages[end].role != MessageRole.user.name) {
        end++;
      }
      final removedCount = end - oldestIndex;
      dropped += removedCount;
      messages.removeRange(oldestIndex, end);
      currentTurnStart -= removedCount;
    }

    return ConversationContextSelection(
      messages: List.unmodifiable(messages),
      droppedMessages: dropped,
    );
  }
}
