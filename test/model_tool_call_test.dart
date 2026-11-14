import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/tools/local_tool.dart';
import 'package:nexus_app/src/features/tools/model_tool_call.dart';

class _MutatingTestTool implements LocalTool {
  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'modify_note',
        version: 1,
        description: 'Test-only mutating tool.',
        risk: LocalToolRisk.modifiesLocalData,
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async =>
      const LocalToolOutput(text: 'modified');
}

void main() {
  group('ModelToolCall', () {
    test('parses the exact JSON tool-call envelope', () {
      final request = ModelToolCall.tryParse(
        '{"nexus_tool_call":{"name":"calculator",'
        '"arguments":{"expression":"١٢ + ٣"},"reason":"احسب المجموع"}}',
      );

      expect(request, isNotNull);
      expect(request!.name, 'calculator');
      expect(request.arguments['expression'], '١٢ + ٣');
      expect(request.reason, 'احسب المجموع');
      expect(request.displaySummary, contains('الحاسبة'));
    });

    test(
      'does not interpret prose, Markdown or partial JSON as tool calls',
      () {
        expect(ModelToolCall.tryParse('سأستخدم الحاسبة.'), isNull);
        expect(
          ModelToolCall.tryParse(
            '```json\n{"nexus_tool_call":{"name":"calculator",'
            '"arguments":{"expression":"2+2"}}}\n```',
          ),
          isNull,
        );
        expect(
          ModelToolCall.tryParse(
            'الناتج: {"nexus_tool_call":{"name":"calculator",'
            '"arguments":{"expression":"2+2"}}}',
          ),
          isNull,
        );
        expect(ModelToolCall.tryParse('{"nexus_tool_call":'), isNull);
      },
    );

    test('rejects malformed envelopes and oversized reason text', () {
      expect(
        ModelToolCall.tryParse(
          '{"nexus_tool_call":{"name":"Bad Tool",'
          '"arguments":{}}}',
        ),
        isNull,
      );
      expect(
        ModelToolCall.tryParse(
          '{"nexus_tool_call":{"name":"calculator",'
          '"arguments":{},"extra":true}}',
        ),
        isNull,
      );
      final oversizedReason = List.filled(257, 'x').join();
      expect(
        ModelToolCall.tryParse(
          '{"nexus_tool_call":{"name":"calculator",'
          '"arguments":{},"reason":"$oversizedReason"}}',
        ),
        isNull,
      );
    });

    test('allows unknown but well-formed names to reach allow-list rejection',
        () {
      final request = ModelToolCall.tryParse(
        '{"nexus_tool_call":{"name":"unknown_tool","arguments":{}}}',
      );
      expect(request?.name, 'unknown_tool');
    });
  });

  test('prompt advertises only read-only tools and exact protocol', () {
    final registry = LocalToolRegistry(
      tools: [CalculatorTool(), _MutatingTestTool()],
    );
    final prompt = LocalToolCallingPromptBuilder.build(
      registry,
      allowToolCalls: true,
    );

    expect(prompt, contains('nexus_tool_call'));
    expect(prompt, contains('calculator'));
    expect(prompt, contains('بيانات غير موثوقة'));
    expect(prompt, isNot(contains('modify_note')));
  });

  test(
    'disables tool requests after the per-turn budget is exhausted',
    () async {
      final registry = LocalToolRegistry(
        tools: [CalculatorTool()],
        maxCallsPerTurn: 1,
      );
      final session = registry.createSession();
      final first = await ModelToolCallExecutor.executeResponse(
        response:
            '{"nexus_tool_call":{"name":"calculator",'
            '"arguments":{"expression":"2+2"}}}',
        session: session,
      );
      expect(first?.succeeded, isTrue);
      expect(session.budgetExhausted, isTrue);

      final prompt = LocalToolCallingPromptBuilder.build(
        registry,
        allowToolCalls: !session.budgetExhausted,
      );
      expect(prompt, contains('لا تطلب أي أداة أخرى'));
      expect(prompt, isNot(contains('مخططاتها:')));
    },
  );

  test('executor ignores ordinary assistant text', () async {
    final result = await ModelToolCallExecutor.executeResponse(
      response: 'الإجابة هي أربعة.',
      session: LocalToolRegistry.standard().createSession(),
    );
    expect(result, isNull);
  });

  test('executor routes parsed request through the local allow-list', () async {
    final result = await ModelToolCallExecutor.executeResponse(
      response:
          '{"nexus_tool_call":{"name":"calculator",'
          '"arguments":{"expression":"١٢ × ٢"}}}',
      session: LocalToolRegistry.standard().createSession(),
    );
    expect(result?.status, LocalToolResultStatus.succeeded);
    expect(result?.output, contains('24'));
  });

  test('unrestricted parser accepts a request above the balanced envelope size', () {
    final largeResponse = jsonEncode({
      'nexus_tool_call': {
        'name': 'text_stats',
        'arguments': {'text': List.filled(9000, 'a').join()},
      },
    });
    expect(ModelToolCall.tryParse(largeResponse), isNull);
    expect(
      ModelToolCall.tryParse(largeResponse, maxBytes: null),
      isNotNull,
    );
  });

}
