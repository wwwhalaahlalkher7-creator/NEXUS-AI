import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/conversations/conversation_context_builder.dart';
import 'package:nexus_app/src/features/conversations/conversation_record.dart';

void main() {
  MessageRecord message(
    String id,
    MessageRole role,
    String content, {
    MessageStatus status = MessageStatus.complete,
    int timestamp = 1,
  }) {
    return MessageRecord(
      id: id,
      conversationId: 'conversation-1',
      role: role,
      content: content,
      status: status,
      createdAtUnixMs: timestamp,
    );
  }

  test('sends only completed role-aware messages in chronological order', () {
    final result = ConversationContextBuilder.build([
      message('1', MessageRole.system, 'Be concise.'),
      message('2', MessageRole.user, 'First question'),
      message('3', MessageRole.assistant, 'First answer'),
      message(
        '4',
        MessageRole.assistant,
        'partial',
        status: MessageStatus.streaming,
      ),
      message('5', MessageRole.user, 'Second question'),
    ]);

    expect(result.droppedMessages, 0);
    expect(
      result.messages.map((item) => '${item.role}:${item.content}').toList(),
      [
        'system:Be concise.',
        'user:First question',
        'assistant:First answer',
        'user:Second question',
      ],
    );
  });

  test(
    'drops oldest complete user-assistant turns and preserves system/latest',
    () {
      final result = ConversationContextBuilder.build(
        [
          message('1', MessageRole.system, 'System instruction'),
          message('2', MessageRole.user, 'old question'),
          message('3', MessageRole.assistant, 'old answer'),
          message('4', MessageRole.user, 'recent question'),
          message('5', MessageRole.assistant, 'recent answer'),
          message('6', MessageRole.user, 'current question'),
        ],
        maxMessages: 4,
      );

      expect(result.droppedMessages, 2);
      expect(
        result.messages.map((item) => item.content).toList(),
        [
          'System instruction',
          'recent question',
          'recent answer',
          'current question',
        ],
      );
    },
  );

  test('uses UTF-8 byte budget and retains the current user message', () {
    final result = ConversationContextBuilder.build(
      [
        message('1', MessageRole.system, 'S'),
        message('2', MessageRole.user, 'éé'),
        message('3', MessageRole.assistant, 'ok'),
        message('4', MessageRole.user, 'next'),
      ],
      maxBytes: 6,
    );

    expect(result.droppedMessages, 2);
    expect(
      result.messages.map((item) => item.content).toList(),
      ['S', 'next'],
    );
  });

  test('rejects context with no completed current user turn', () {
    expect(
      () => ConversationContextBuilder.build([
        message('1', MessageRole.user, 'question'),
        message('2', MessageRole.assistant, 'answer'),
      ]),
      throwsStateError,
    );
  });

  test('rejects a current message that alone exceeds transport budget', () {
    expect(
      () => ConversationContextBuilder.build(
        [message('1', MessageRole.user, 'x' * 32)],
        maxBytes: 16,
      ),
      throwsStateError,
    );
  });
}
