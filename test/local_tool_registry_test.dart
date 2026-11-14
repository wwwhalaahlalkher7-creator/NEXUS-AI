import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/tools/local_tool.dart';
import 'package:nexus_app/src/features/resources/resource_settings.dart';

class _DelayedTool implements LocalTool {
  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'delayed_tool',
        version: 1,
        description: 'Test timeout boundary.',
        timeout: Duration(milliseconds: 20),
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    cancellationToken.throwIfCancelled();
    return const LocalToolOutput(text: 'late');
  }
}

class _ApprovalTool implements LocalTool {
  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'approval_tool',
        version: 1,
        description: 'Test confirmation gate.',
        risk: LocalToolRisk.modifiesLocalData,
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async =>
      const LocalToolOutput(text: 'approved');
}

class _LargeOutputTool implements LocalTool {
  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'large_output',
        version: 1,
        description: 'Test output bounds.',
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async =>
      LocalToolOutput(text: List.filled(32, 'x').join());
}

class _LargeUnicodeOutputTool implements LocalTool {
  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'large_unicode_output',
        version: 1,
        description: 'Test Unicode-safe output bounds.',
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async =>
      LocalToolOutput(text: List.filled(12, '😀').join());
}

class _CancellableTool implements LocalTool {
  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'cancellable_tool',
        version: 1,
        description: 'Test cooperative cancellation.',
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async {
    while (!cancellationToken.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    cancellationToken.throwIfCancelled();
    return const LocalToolOutput(text: 'unexpected');
  }
}

void main() {
  group('CalculatorTool', () {
    final calculator = CalculatorTool();

    Future<String> calculate(String expression) async =>
        (await calculator.execute(
          {'expression': expression},
          cancellationToken: LocalToolCancellationToken(),
        )).text;

    test('respects arithmetic precedence and parentheses', () async {
      expect(await calculate('12 * (3 + 2)'), '12 * (3 + 2) = 60');
      expect(await calculate('2 + 3 * 4'), '2 + 3 * 4 = 14');
    });

    test('supports division, modulo, powers and unary signs', () async {
      expect(await calculate('10 / 4'), '10 / 4 = 2.5');
      expect(await calculate('10 % 4'), '10 % 4 = 2');
      expect(await calculate('2^3^2'), '2^3^2 = 512');
      expect(await calculate('-2^2'), '-2^2 = -4');
    });

    test('normalizes Arabic and Persian digits and math symbols', () async {
      expect(await calculate('١٢ × (٣ + ٢)'), '١٢ × (٣ + ٢) = 60');
      expect(await calculate('۱۲٫۵ ÷ ۲'), '۱۲٫۵ ÷ ۲ = 6.25');
      expect(await calculate('١٬٢٣٤ + ٦'), '١٬٢٣٤ + ٦ = 1240');
    });

    test('rejects division by zero and excessive exponents', () async {
      await expectLater(calculate('4 / 0'), throwsFormatException);
      await expectLater(calculate('2^13'), throwsFormatException);
    });

    test('rejects code-like, malformed and oversized expressions', () async {
      await expectLater(calculate('1 + system(2)'), throwsFormatException);
      await expectLater(calculate('(1 + 2'), throwsFormatException);
      await expectLater(calculate(List.filled(257, '1').join()), throwsFormatException);
    });

    test('requires exactly one expression input', () async {
      await expectLater(
        calculator.execute(
          {},
          cancellationToken: LocalToolCancellationToken(),
        ),
        throwsFormatException,
      );
      await expectLater(
        calculator.execute(
          {'expression': '1+1', 'extra': true},
          cancellationToken: LocalToolCancellationToken(),
        ),
        throwsFormatException,
      );
    });
  });

  test('registry rejects unknown tool names', () async {
    final result = await LocalToolRegistry.standard().createSession().execute(
          toolName: 'shell',
          arguments: const {},
        );

    expect(result.status, LocalToolResultStatus.rejected);
    expect(result.output, contains('غير مسجلة'));
  });

  test('registry enforces confirmation for modifying tools', () async {
    final registry = LocalToolRegistry(tools: [_ApprovalTool()]);
    final session = registry.createSession();

    final rejected = await session.execute(
      toolName: 'approval_tool',
      arguments: const {},
    );
    expect(rejected.status, LocalToolResultStatus.rejected);

    final approved = await session.execute(
      toolName: 'approval_tool',
      arguments: const {},
      userApproved: true,
    );
    expect(approved.status, LocalToolResultStatus.succeeded);
    expect(approved.output, 'approved');
  });

  test('registry bounds argument bytes before execution', () async {
    final registry = LocalToolRegistry(
      tools: [CalculatorTool()],
      maxArgumentBytes: 8,
    );
    final result = await registry.createSession().execute(
          toolName: 'calculator',
          arguments: {'expression': '123456789'},
        );

    expect(result.status, LocalToolResultStatus.rejected);
    expect(result.output, contains('حجم مدخلات'));
  });

  test(
    'registry validates declared argument type and rejects unknown keys',
    () async {
      final registry = LocalToolRegistry(tools: [CalculatorTool()]);
      final session = registry.createSession();

      final wrongType = await session.execute(
        toolName: 'calculator',
        arguments: const {'expression': 12},
      );
      expect(wrongType.status, LocalToolResultStatus.rejected);
      expect(wrongType.output, contains('نوع المعامل'));

      final extraKey = await LocalToolRegistry.standard()
          .createSession()
          .execute(
            toolName: 'calculator',
            arguments: const {'expression': '1+1', 'extra': true},
          );
      expect(extraKey.status, LocalToolResultStatus.rejected);
      expect(extraKey.output, contains('غير معرّف'));
    },
  );

  test('registry bounds returned output', () async {
    final registry = LocalToolRegistry(
      tools: [_LargeOutputTool()],
      maxOutputCharacters: 8,
    );
    final result = await registry.createSession().execute(
          toolName: 'large_output',
          arguments: const {},
        );

    expect(result.status, LocalToolResultStatus.succeeded);
    expect(result.output, 'xxxxxxxx… [تم اقتطاع الناتج]');
  });

  test('registry enforces tool timeout', () async {
    final result = await LocalToolRegistry(tools: [_DelayedTool()])
        .createSession()
        .execute(toolName: 'delayed_tool', arguments: const {});

    expect(result.status, LocalToolResultStatus.timedOut);
  });

  test('session stays locked until a timed-out source future exits', () async {
    final session = LocalToolRegistry(tools: [_DelayedTool()]).createSession();
    final result = await session.execute(
      toolName: 'delayed_tool',
      arguments: const {},
    );
    expect(result.status, LocalToolResultStatus.timedOut);
    expect(session.isRunning, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(session.isRunning, isFalse);
  });

  test('session supports cooperative cancellation', () async {
    final session = LocalToolRegistry(
      tools: [_CancellableTool()],
    ).createSession();
    final pending = session.execute(
      toolName: 'cancellable_tool',
      arguments: const {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 3));
    expect(session.isRunning, isTrue);
    session.cancelCurrent();
    final result = await pending;
    expect(result.status, LocalToolResultStatus.cancelled);
    expect(result.output, 'أُلغي تنفيذ الأداة.');
    expect(session.isRunning, isFalse);
  });

  test('session rejects a second tool while the first is running', () async {
    final session = LocalToolRegistry(
      tools: [_CancellableTool()],
    ).createSession();
    final pending = session.execute(
      toolName: 'cancellable_tool',
      arguments: const {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));

    final overlapping = await session.execute(
      toolName: 'cancellable_tool',
      arguments: const {},
    );
    expect(overlapping.status, LocalToolResultStatus.rejected);
    expect(overlapping.output, contains('قيد التنفيذ'));

    session.cancelCurrent();
    final first = await pending;
    expect(first.status, LocalToolResultStatus.cancelled);
  });

  test('output truncation preserves complete Unicode code points', () async {
    final registry = LocalToolRegistry(
      tools: [_LargeUnicodeOutputTool()],
      maxOutputCharacters: 7,
    );
    final result = await registry.createSession().execute(
          toolName: 'large_unicode_output',
          arguments: const {},
        );

    expect(result.status, LocalToolResultStatus.succeeded);
    expect(result.output, '😀😀😀😀😀😀😀… [تم اقتطاع الناتج]');
  });

  test('per-turn session enforces call count', () async {
    final session = LocalToolRegistry(
      tools: [CalculatorTool()],
      maxCallsPerTurn: 2,
    ).createSession();

    for (var i = 0; i < 2; i++) {
      final result = await session.execute(
        toolName: 'calculator',
        arguments: const {'expression': '1+1'},
      );
      expect(result.status, LocalToolResultStatus.succeeded);
    }
    final blocked = await session.execute(
      toolName: 'calculator',
      arguments: const {'expression': '1+1'},
    );
    expect(blocked.status, LocalToolResultStatus.rejected);
    expect(session.attempts, 2);
  });

  test('audit content can be restored without exposing invalid payloads', () {
    const result = LocalToolExecutionResult(
      callId: 'tool-1',
      toolName: 'calculator',
      status: LocalToolResultStatus.succeeded,
      output: '1+1 = 2',
      data: {'value': 2},
      durationMs: 1,
    );

    final restored = LocalToolExecutionResult.tryParseAuditContent(
      result.toAuditContent(),
    );
    expect(restored?.callId, result.callId);
    expect(restored?.toolName, result.toolName);
    expect(restored?.output, result.output);
    expect(restored?.data['value'], 2);
    expect(
      LocalToolExecutionResult.tryParseAuditContent('not-json'),
      isNull,
    );
  });

  test('standard date time tool uses injected local clock', () async {
    final localNow = DateTime(2026, 11, 14, 12, 30);
    final tool = LocalDateTimeTool(clock: () => localNow);
    final result = await tool.execute(
      const {},
      cancellationToken: LocalToolCancellationToken(),
    );
    expect(result.text, 'الوقت المحلي: 2026-11-14T12:30:00.000');
    expect(result.data['iso8601'], '2026-11-14T12:30:00.000');
    expect(
      result.data['utc_offset_minutes'],
      localNow.timeZoneOffset.inMinutes,
    );
    expect(result.data['time_zone_name'], localNow.timeZoneName);
  });

  test('text statistics count Unicode code points, words and lines', () async {
    final output = await TextStatsTool().execute(
      const {'text': 'مرحبا بالعالم\nNEXUS'},
      cancellationToken: LocalToolCancellationToken(),
    );
    expect(output.text, contains('الكلمات: 3'));
    expect(output.text, contains('الأسطر: 2'));
    expect(output.data['words'], 3);
  });

  test('unrestricted session does not exhaust an artificial call budget', () {
    final session = LocalToolRegistry.standard().createSession(
      settings: const ResourceSettings(mode: ResourceMode.unrestricted),
    );
    expect(session.budgetExhausted, isFalse);
  });

  test('unrestricted text statistics accepts input beyond the old 4000-char cap', () async {
    final session = LocalToolRegistry.standard().createSession(
      settings: const ResourceSettings(mode: ResourceMode.unrestricted),
    );
    final largeText = List.filled(5001, 'م').join();
    final result = await session.execute(
      toolName: 'text_stats',
      arguments: {'text': largeText},
    );

    expect(result.status, LocalToolResultStatus.succeeded);
    expect(result.data['characters'], 5001);
  });

}
