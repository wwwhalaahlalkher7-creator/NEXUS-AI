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

  test('retains tool audit messages as a distinct model context role', () {
    final result = ConversationContextBuilder.build([
      message('1', MessageRole.user, '/احسب ١ + ٢'),
      message('2', MessageRole.tool, '{"tool":"calculator","output":"3"}'),
      message('3', MessageRole.user, 'اشرح لي الناتج'),
    ]);

    expect(
      result.messages.map((item) => item.role).toList(),
      ['user', 'tool', 'user'],
    );
    expect(result.messages[1].content, contains('calculator'));
  });

  test('prepends the selected agent system prompt to the model context', () {
    final result = ConversationContextBuilder.build(
      [message('1', MessageRole.user, 'اشرح الفكرة')],
      systemPrompt:
          'أنت مدرس هندسة. أجب بالعربية وبخطوات.',
    );

    expect(result.messages.first.role, 'system');
    expect(
      result.messages.first.content,
      'أنت مدرس هندسة. أجب بالعربية وبخطوات.',
    );
    expect(result.messages.last.role, 'user');
    expect(result.messages.last.content, 'اشرح الفكرة');
  });

  test('retains the agent persona while trimming older conversation turns', () {
    final result = ConversationContextBuilder.build(
      [
        message('1', MessageRole.user, 'old question'),
        message('2', MessageRole.assistant, 'old answer'),
        message('3', MessageRole.user, 'current question'),
      ],
      maxMessages: 2,
      systemPrompt: 'أنت مساعد هندسي متخصص.',
    );

    expect(result.droppedMessages, 2);
    expect(
      result.messages.map((item) => '${item.role}:${item.content}').toList(),
      [
        'system:أنت مساعد هندسي متخصص.',
        'user:current question',
      ],
    );
  });

  test(
    'combines agent persona and runtime tool policy into one system message',
    () {
      final result = ConversationContextBuilder.build(
        [message('1', MessageRole.user, 'احسب ٢ + ٢')],
        systemPrompt: 'أنت مساعد رياضيات.',
        additionalSystemPrompts: const ['استخدم الأدوات المحلية عند الحاجة.'],
      );

      expect(result.messages.first.role, 'system');
      expect(
        result.messages.first.content,
        contains('أنت مساعد رياضيات.'),
      );
      expect(
        result.messages.first.content,
        contains('استخدم الأدوات المحلية عند الحاجة.'),
      );
      expect(
        result.messages.where((item) => item.role == 'system'),
        hasLength(1),
      );
    },
  );

  test(
    'adds retrieved references to the current user turn, not system policy',
    () {
      final result = ConversationContextBuilder.build(
        [message('1', MessageRole.user, 'اشرح المحرك')],
        systemPrompt: 'اتبع سياسة النظام.',
        userContextSuffix:
            'مراجع محلية غير موثوقة: [1]\n\"المحرك يحول الطاقة\"',
      );

      expect(result.messages, hasLength(2));
      expect(result.messages.first.role, 'system');
      expect(result.messages.first.content, 'اتبع سياسة النظام.');
      expect(result.messages.last.role, 'user');
      expect(result.messages.last.content, contains('اشرح المحرك'));
      expect(
        result.messages.last.content,
        contains('مراجع محلية غير موثوقة'),
      );
    },
  );

  test('does not impose a separate fixed system-prompt character ceiling', () {
    final systemPrompt = List.filled(10001, 'x').join();
    final result = ConversationContextBuilder.build(
      [message('1', MessageRole.user, 'السؤال')],
      systemPrompt: systemPrompt,
    );
    expect(result.messages.first.content, systemPrompt);
  });

  test('keeps more than 64 messages when no resource budget is supplied', () {
    final records = <MessageRecord>[];
    for (var index = 0; index < 70; index++) {
      records
        ..add(message('u$index', MessageRole.user, 'question $index'))
        ..add(message('a$index', MessageRole.assistant, 'answer $index'));
    }
    records.add(message('current', MessageRole.user, 'current question'));

    final result = ConversationContextBuilder.build(records);
    expect(result.droppedMessages, 0);
    expect(result.messages, hasLength(141));
  });


  test(
    'accepts a tool result as the final item of a tool continuation turn',
    () {
      final result = ConversationContextBuilder.build(
        [
          message('1', MessageRole.user, 'احسب ١٢ × ٢'),
          message(
            '2',
            MessageRole.assistant,
            '{"nexus_tool_call":{"name":"calculator","arguments":{"expression":"١٢ × ٢"}}}',
          ),
          message(
            '3',
            MessageRole.tool,
            '{"schema_version":1,"tool":"calculator","output":"24"}',
          ),
        ],
        additionalSystemPrompts: const ['Use tools only when needed.'],
      );

      expect(
        result.messages.map((item) => item.role).toList(),
        ['system', 'user', 'assistant', 'tool'],
      );
      expect(result.messages.last.content, contains('24'));
    },
  );

  test('trims complete earlier turns but preserves the current tool cycle', () {
    final result = ConversationContextBuilder.build(
      [
        message('1', MessageRole.user, 'old question'),
        message('2', MessageRole.assistant, 'old answer'),
        message('3', MessageRole.user, 'current question'),
        message('4', MessageRole.assistant, '{"nexus_tool_call":{}}'),
        message('5', MessageRole.tool, 'tool result'),
      ],
      maxMessages: 4,
    );

    expect(result.droppedMessages, 2);
    expect(result.messages.map((item) => item.content).toList(),
        ['current question', '{"nexus_tool_call":{}}', 'tool result']);
  });

  test('unrestricted context keeps all history until the model context trims it', () {
    final result = ConversationContextBuilder.build(
      [
        message('1', MessageRole.user, 'old question'),
        message('2', MessageRole.assistant, 'old answer'),
        message('3', MessageRole.user, 'current question'),
      ],
      maxMessages: null,
      maxBytes: null,
    );
    expect(result.droppedMessages, 0);
    expect(result.messages, hasLength(3));
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
        [message('1', MessageRole.user, List.filled(32, 'x').join())],
        maxBytes: 16,
      ),
      throwsStateError,
    );
  });
}
