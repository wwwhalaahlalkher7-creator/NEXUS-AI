import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../resources/resource_settings.dart';

/// Permission class for a local tool. No network or shell-execution tool is
/// registered in the initial tool set.
enum LocalToolRisk { readOnly, modifiesLocalData, externalAccess }

enum LocalToolResultStatus { succeeded, rejected, timedOut, cancelled, failed }

enum LocalToolParameterType { string, integer, number, boolean }

@immutable
class LocalToolParameter {
  const LocalToolParameter({
    required this.name,
    required this.type,
    required this.description,
    this.required = true,
    this.maxLength,
  });

  final String name;
  final LocalToolParameterType type;
  final String description;
  final bool required;
  final int? maxLength;
}

class LocalToolCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const LocalToolCancelledException();
  }
}

class LocalToolCancelledException implements Exception {
  const LocalToolCancelledException();
}

@immutable
class LocalToolOutput {
  const LocalToolOutput({required this.text, this.data = const {}});

  final String text;
  final Map<String, Object?> data;
}

@immutable
class LocalToolSpec {
  const LocalToolSpec({
    required this.name,
    required this.version,
    required this.description,
    this.risk = LocalToolRisk.readOnly,
    this.timeout = const Duration(seconds: 3),
    this.parameters = const [],
  });

  final String name;
  final int version;
  final String description;
  final LocalToolRisk risk;
  final Duration timeout;
  final List<LocalToolParameter> parameters;

  bool get requiresConfirmation => risk != LocalToolRisk.readOnly;
}

abstract interface class LocalTool {
  LocalToolSpec get spec;

  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  });
}

@immutable
class LocalToolExecutionResult {
  const LocalToolExecutionResult({
    required this.callId,
    required this.toolName,
    required this.status,
    required this.output,
    required this.durationMs,
    this.data = const {},
  });

  final String callId;
  final String toolName;
  final LocalToolResultStatus status;
  final String output;
  final int durationMs;
  final Map<String, Object?> data;

  bool get succeeded => status == LocalToolResultStatus.succeeded;

  String toAuditContent() => jsonEncode({
        'schema_version': 1,
        'call_id': callId,
        'tool': toolName,
        'status': status.name,
        'output': output,
        'data': data,
        'duration_ms': durationMs,
      });

  static LocalToolExecutionResult? tryParseAuditContent(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic> ||
          decoded['schema_version'] != 1 ||
          decoded['call_id'] is! String ||
          decoded['tool'] is! String ||
          decoded['status'] is! String ||
          decoded['output'] is! String ||
          decoded['data'] is! Map<String, dynamic> ||
          decoded['duration_ms'] is! int) {
        return null;
      }
      return LocalToolExecutionResult(
        callId: decoded['call_id'] as String,
        toolName: decoded['tool'] as String,
        status: LocalToolResultStatus.values.byName(
          decoded['status'] as String,
        ),
        output: decoded['output'] as String,
        data: Map<String, Object?>.unmodifiable(
          decoded['data'] as Map<String, dynamic>,
        ),
        durationMs: decoded['duration_ms'] as int,
      );
    } on Object {
      return null;
    }
  }
}

/// Registry with strict input/output budgets and per-tool execution timeouts.
/// Tools are deliberately allow-listed; arbitrary code, shell and network
/// execution are not supported by this registry.
class LocalToolRegistry {
  LocalToolRegistry({
    required Iterable<LocalTool> tools,
    this.maxArgumentBytes,
    this.maxOutputCharacters,
    this.maxCallsPerTurn,
  }) : _tools = _indexTools(tools) {
    if ((maxArgumentBytes != null && maxArgumentBytes! < 1) ||
        (maxOutputCharacters != null && maxOutputCharacters! < 1) ||
        (maxCallsPerTurn != null && maxCallsPerTurn! < 1)) {
      throw ArgumentError('Tool execution budgets must be positive.');
    }
  }

  factory LocalToolRegistry.standard() => LocalToolRegistry(
        tools: [
          CalculatorTool(),
          LocalDateTimeTool(),
          TextStatsTool(),
        ],
      );

  final Map<String, LocalTool> _tools;
  final int? maxArgumentBytes;
  final int? maxOutputCharacters;
  final int? maxCallsPerTurn;

  List<LocalToolSpec> get tools =>
      _tools.values.map((tool) => tool.spec).toList(growable: false);

  LocalTool? operator [](String name) => _tools[name];

  LocalToolExecutionSession createSession({
    ResourceSettings settings = const ResourceSettings(),
  }) =>
      LocalToolExecutionSession._(this, settings);

  static Map<String, LocalTool> _indexTools(Iterable<LocalTool> tools) {
    final indexed = <String, LocalTool>{};
    for (final tool in tools) {
      final name = tool.spec.name;
      if (!RegExp(r'^[a-z][a-z0-9_]{1,31}$').hasMatch(name)) {
        throw ArgumentError.value(name, 'tool.name', 'Invalid tool name.');
      }
      if (tool.spec.version < 1 || tool.spec.timeout.inMilliseconds < 1) {
        throw ArgumentError('Tool version and timeout must be positive.');
      }
      final parameterNames = <String>{};
      for (final parameter in tool.spec.parameters) {
        if (!RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(parameter.name) ||
            !parameterNames.add(parameter.name) ||
            (parameter.maxLength != null && parameter.maxLength! < 1)) {
          throw ArgumentError(
            'Tool argument schema is invalid: ${parameter.name}',
          );
        }
      }
      if (indexed.containsKey(name)) {
        throw ArgumentError.value(name, 'tool.name', 'Duplicate tool name.');
      }
      indexed[name] = tool;
    }
    return Map.unmodifiable(indexed);
  }
}

/// Optional per-turn attempt budget. When configured, attempts count even
/// when rejected or failed, preventing repeated malformed tool requests.
class LocalToolExecutionSession {
  LocalToolExecutionSession._(this._registry, this._settings);

  final LocalToolRegistry _registry;
  final ResourceSettings _settings;

  int? get _effectiveMaxCalls =>
      _registry.maxCallsPerTurn ?? _settings.maxToolCallsPerTurn;
  int? get _effectiveMaxArgumentBytes =>
      _registry.maxArgumentBytes ?? _settings.maxToolArgumentBytes;
  int? get _effectiveMaxOutputCharacters =>
      _registry.maxOutputCharacters ?? _settings.maxToolOutputCharacters;
  int? get maxToolCallEnvelopeBytes => _settings.maxToolEnvelopeBytes;
  int _attempts = 0;
  bool _running = false;
  LocalToolCancellationToken? _activeCancellationToken;

  int get attempts => _attempts;
  bool get budgetExhausted {
    final limit = _effectiveMaxCalls;
    return limit != null && _attempts >= limit;
  }
  bool get isRunning => _running;

  /// Requests cooperative cancellation from the active tool.
  void cancelCurrent() => _activeCancellationToken?.cancel();

  Future<LocalToolExecutionResult> execute({
    required String toolName,
    required Map<String, Object?> arguments,
    bool userApproved = false,
  }) async {
    final startedAt = DateTime.now();
    final callId = 'tool-${startedAt.microsecondsSinceEpoch}';
    if (_running) {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.rejected,
        'توجد أداة أخرى قيد التنفيذ في هذه المهمة.',
        startedAt,
      );
    }
    if (budgetExhausted) {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.rejected,
        'تم بلوغ الحد الأقصى لاستدعاءات الأدوات في هذه المهمة.',
        startedAt,
      );
    }
    _attempts++;

    final tool = _registry[toolName];
    if (tool == null) {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.rejected,
        'الأداة غير مسجلة أو غير مسموح بها.',
        startedAt,
      );
    }

    if (tool.spec.requiresConfirmation && !userApproved) {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.rejected,
        'تتطلب هذه الأداة موافقة صريحة من المستخدم.',
        startedAt,
      );
    }

    final schemaError = _validateArguments(tool.spec, arguments);
    if (schemaError != null) {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.rejected,
        schemaError,
        startedAt,
      );
    }
    late final String encodedArguments;
    try {
      encodedArguments = jsonEncode(arguments);
    } on Object {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.rejected,
        'مدخلات الأداة لا تحتوي قيماً قابلة للتحويل إلى JSON.',
        startedAt,
      );
    }
    final maxArgumentBytes = _effectiveMaxArgumentBytes;
    if (maxArgumentBytes != null &&
        utf8.encode(encodedArguments).length > maxArgumentBytes) {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.rejected,
        'حجم مدخلات الأداة يتجاوز الحد المسموح.',
        startedAt,
      );
    }

    final cancellationToken = LocalToolCancellationToken();
    _running = true;
    _activeCancellationToken = cancellationToken;
    var releaseWhenExecutionCompletes = false;
    late final Future<LocalToolOutput> execution;
    try {
      execution = tool.execute(
        Map<String, Object?>.unmodifiable(arguments),
        cancellationToken: cancellationToken,
      );
      final output = await execution.timeout(tool.spec.timeout);
      cancellationToken.throwIfCancelled();
      final encodedData = jsonEncode(output.data);
      final outputLimit = _effectiveMaxOutputCharacters;
      final outputRunes = output.text.runes;
      final boundedOutput = outputLimit == null || outputRunes.length <= outputLimit
          ? output.text
          : '${String.fromCharCodes(outputRunes.take(outputLimit))}… [تم اقتطاع الناتج]';
      final boundedData = outputLimit == null ||
              utf8.encode(encodedData).length <= outputLimit * 4
          ? output.data
          : const <String, Object?>{};
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.succeeded,
        boundedOutput,
        startedAt,
        data: boundedData,
      );
    } on TimeoutException {
      cancellationToken.cancel();
      // Future.timeout does not terminate its source future. Keep the session
      // locked until the tool cooperatively observes cancellation and exits.
      releaseWhenExecutionCompletes = true;
      unawaited(execution.then<void>(
        (_) => _clearRunningState(cancellationToken),
        onError: (Object _) => _clearRunningState(cancellationToken),
      ));
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.timedOut,
        'انتهت مهلة تنفيذ الأداة؛ أُرسل طلب إلغاء إلى الأداة.',
        startedAt,
      );
    } on LocalToolCancelledException {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.cancelled,
        'أُلغي تنفيذ الأداة.',
        startedAt,
      );
    } on Object catch (error) {
      return _result(
        callId,
        toolName,
        LocalToolResultStatus.failed,
        'تعذر تنفيذ الأداة: $error',
        startedAt,
      );
    } finally {
      if (!releaseWhenExecutionCompletes) {
        _clearRunningState(cancellationToken);
      }
    }
  }

  void _clearRunningState(LocalToolCancellationToken token) {
    if (!identical(_activeCancellationToken, token)) return;
    _running = false;
    _activeCancellationToken = null;
  }

  String? _validateArguments(
    LocalToolSpec spec,
    Map<String, Object?> arguments,
  ) {
    final definitions = {
      for (final parameter in spec.parameters) parameter.name: parameter,
    };
    for (final key in arguments.keys) {
      if (!definitions.containsKey(key)) {
        return 'المعامل "$key" غير معرّف في مخطط الأداة.';
      }
    }
    for (final parameter in spec.parameters) {
      if (!arguments.containsKey(parameter.name)) {
        if (parameter.required) {
          return 'المعامل المطلوب "${parameter.name}" مفقود.';
        }
        continue;
      }
      final value = arguments[parameter.name];
      final validType = switch (parameter.type) {
        LocalToolParameterType.string => value is String,
        LocalToolParameterType.integer => value is int,
        LocalToolParameterType.number => value is num && value.isFinite,
        LocalToolParameterType.boolean => value is bool,
      };
      if (!validType) {
        return 'نوع المعامل "${parameter.name}" غير صحيح.';
      }
      if (parameter.maxLength != null &&
          value is String &&
          value.runes.length > parameter.maxLength!) {
        return 'المعامل "${parameter.name}" يتجاوز الحد المسموح.';
      }
    }
    return null;
  }

  LocalToolExecutionResult _result(
    String callId,
    String toolName,
    LocalToolResultStatus status,
    String output,
    DateTime startedAt, {
    Map<String, Object?> data = const {},
  }) =>
      LocalToolExecutionResult(
        callId: callId,
        toolName: toolName,
        status: status,
        output: output,
        data: Map<String, Object?>.unmodifiable(data),
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      );
}

class CalculatorTool implements LocalTool {
  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'calculator',
        version: 1,
        description: 'حساب تعبيرات رياضية محلياً دون تنفيذ شيفرات.',
        parameters: [
          LocalToolParameter(
            name: 'expression',
            type: LocalToolParameterType.string,
            description: 'تعبير رياضي محدود.',
            maxLength: 256,
          ),
        ],
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async {
    cancellationToken.throwIfCancelled();
    final expression = arguments['expression'];
    if (arguments.length != 1 || expression is! String) {
      throw const FormatException('المطلوب حقل نصي واحد باسم expression.');
    }
    if (expression.trim().isEmpty || expression.runes.length > 256) {
      throw const FormatException('التعبير فارغ أو أطول من 256 محرفاً.');
    }
    final normalizedExpression = _normalizeExpression(expression);
    final value = _ArithmeticParser(normalizedExpression).parse();
    return LocalToolOutput(
      text: '${expression.trim()} = ${_formatNumber(value)}',
      data: {
        'expression': expression.trim(),
        'normalized_expression': normalizedExpression,
        'value': value,
      },
    );
  }

  String _normalizeExpression(String expression) {
    final buffer = StringBuffer();
    for (final rune in expression.runes) {
      if (rune >= 0x0660 && rune <= 0x0669) {
        buffer.write(rune - 0x0660);
      } else if (rune >= 0x06F0 && rune <= 0x06F9) {
        buffer.write(rune - 0x06F0);
      } else {
        switch (rune) {
          case 0x066B: // Arabic decimal separator.
            buffer.write('.');
          case 0x066C: // Arabic thousands separator.
            break;
          case 0x00D7: // Multiplication sign.
            buffer.write('*');
          case 0x00F7: // Division sign.
            buffer.write('/');
          case 0x2212: // Mathematical minus sign.
          case 0x2013: // En dash used as a minus sign.
            buffer.write('-');
          default:
            buffer.writeCharCode(rune);
        }
      }
    }
    return buffer.toString();
  }

  String _formatNumber(double value) {
    if (!value.isFinite) {
      throw const FormatException('الناتج خارج النطاق العددي المدعوم.');
    }
    if (value == value.roundToDouble() && value.abs() < 9e15) {
      return value.toStringAsFixed(0);
    }
    final formatted = value.toStringAsPrecision(12);
    if (formatted.contains('e') || formatted.contains('E')) {
      return formatted;
    }
    return formatted.replaceFirst(RegExp(r'0+$'), '').replaceFirst(
          RegExp(r'\.$'),
          '',
        );
  }
}

class _ArithmeticParser {
  _ArithmeticParser(this.source);

  final String source;
  int _index = 0;

  double parse() {
    final value = _parseAdditive();
    _skipSpaces();
    if (_index != source.length) {
      throw const FormatException('التعبير يحتوي رمزاً غير صالح.');
    }
    if (!value.isFinite) {
      throw const FormatException('الناتج خارج النطاق العددي المدعوم.');
    }
    return value;
  }

  double _parseAdditive() {
    var value = _parseMultiplicative();
    while (true) {
      if (_consume('+')) {
        value += _parseMultiplicative();
      } else if (_consume('-')) {
        value -= _parseMultiplicative();
      } else {
        return value;
      }
      _ensureFinite(value);
    }
  }

  double _parseMultiplicative() {
    var value = _parseUnary();
    while (true) {
      if (_consume('*')) {
        value *= _parseUnary();
      } else if (_consume('/')) {
        final divisor = _parseUnary();
        if (divisor == 0) {
          throw const FormatException('لا يمكن القسمة على صفر.');
        }
        value /= divisor;
      } else if (_consume('%')) {
        final divisor = _parseUnary();
        if (divisor == 0) {
          throw const FormatException('لا يمكن حساب باقي القسمة على صفر.');
        }
        value %= divisor;
      } else {
        return value;
      }
      _ensureFinite(value);
    }
  }

  double _parseUnary() {
    if (_consume('+')) return _parseUnary();
    if (_consume('-')) return -_parseUnary();
    return _parsePower();
  }

  double _parsePower() {
    final base = _parsePrimary();
    if (!_consume('^')) return base;
    final exponent = _parseUnary();
    if (exponent.abs() > 12) {
      throw const FormatException('قيمة الأس تتجاوز الحد الآمن (12).');
    }
    final value = math.pow(base, exponent).toDouble();
    _ensureFinite(value);
    return value;
  }

  double _parsePrimary() {
    _skipSpaces();
    if (_consume('(')) {
      final value = _parseAdditive();
      if (!_consume(')')) {
        throw const FormatException('قوس إغلاق مفقود.');
      }
      return value;
    }

    final start = _index;
    var hasDigit = false;
    if (_index < source.length && source[_index] == '.') {
      _index++;
      while (_index < source.length && _isDigit(source.codeUnitAt(_index))) {
        hasDigit = true;
        _index++;
      }
    } else {
      while (_index < source.length && _isDigit(source.codeUnitAt(_index))) {
        hasDigit = true;
        _index++;
      }
      if (_index < source.length && source[_index] == '.') {
        _index++;
        while (_index < source.length && _isDigit(source.codeUnitAt(_index))) {
          hasDigit = true;
          _index++;
        }
      }
    }
    if (!hasDigit) {
      throw const FormatException('كان متوقعاً رقم أو قوس مفتوح.');
    }
    final value = double.tryParse(source.substring(start, _index));
    if (value == null || !value.isFinite) {
      throw const FormatException('الرقم غير صالح.');
    }
    return value;
  }

  bool _consume(String token) {
    _skipSpaces();
    if (_index >= source.length || source[_index] != token) return false;
    _index++;
    return true;
  }

  void _skipSpaces() {
    while (_index < source.length &&
        (source.codeUnitAt(_index) == 32 ||
            source.codeUnitAt(_index) == 9 ||
            source.codeUnitAt(_index) == 10)) {
      _index++;
    }
  }

  bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

  void _ensureFinite(double value) {
    if (!value.isFinite) {
      throw const FormatException('الناتج خارج النطاق العددي المدعوم.');
    }
  }
}

class LocalDateTimeTool implements LocalTool {
  LocalDateTimeTool({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'local_datetime',
        version: 1,
        description: 'قراءة التاريخ والوقت المحليين على الجهاز.',
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async {
    cancellationToken.throwIfCancelled();
    if (arguments.isNotEmpty) {
      throw const FormatException('لا تقبل أداة الوقت مدخلات.');
    }
    final now = _clock();
    final iso8601 = now.toIso8601String();
    return LocalToolOutput(
      text: 'الوقت المحلي: $iso8601',
      data: {
        'iso8601': iso8601,
        'utc_offset_minutes': now.timeZoneOffset.inMinutes,
        'time_zone_name': now.timeZoneName,
      },
    );
  }
}

class TextStatsTool implements LocalTool {
  @override
  LocalToolSpec get spec => const LocalToolSpec(
        name: 'text_stats',
        version: 1,
        description: 'حساب إحصاءات أساسية للنص دون تخزينه خارج المحادثة.',
        parameters: [
          LocalToolParameter(
            name: 'text',
            type: LocalToolParameterType.string,
            description: 'النص المطلوب تحليله محلياً؛ حجمه يخضع لوضع الموارد النشط.',
          ),
        ],
      );

  @override
  Future<LocalToolOutput> execute(
    Map<String, Object?> arguments, {
    required LocalToolCancellationToken cancellationToken,
  }) async {
    cancellationToken.throwIfCancelled();
    final text = arguments['text'];
    if (arguments.length != 1 || text is! String) {
      throw const FormatException('المطلوب حقل نصي واحد باسم text.');
    }
    final trimmed = text.trim();
    final words = trimmed.isEmpty
        ? 0
        : trimmed.split(RegExp(r'\s+')).length;
    final lines = text.isEmpty ? 0 : text.split('\n').length;
    final characters = text.runes.length;
    return LocalToolOutput(
      text: 'الأحرف: $characters\nالكلمات: $words\nالأسطر: $lines',
      data: {
        'characters': characters,
        'words': words,
        'lines': lines,
      },
    );
  }
}
