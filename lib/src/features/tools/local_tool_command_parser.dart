class ParsedLocalToolCommand {
  const ParsedLocalToolCommand.help()
      : showHelp = true,
        toolName = null,
        arguments = const {};

  const ParsedLocalToolCommand.tool({
    required this.toolName,
    required this.arguments,
  }) : showHelp = false;

  final bool showHelp;
  final String? toolName;
  final Map<String, Object?> arguments;
}

class LocalToolCommandParser {
  const LocalToolCommandParser._();

  static const helpText = 'الأدوات المحلية المتاحة:\n'
      '/احسب ١٢ × (٣ + ٢) أو /calc 12 * (3 + 2) — الحاسبة\n'
      '/وقت أو /time — التاريخ والوقت المحليان\n'
      '/إحصاء النص أو /stats text — إحصاءات النص\n'
      '/الأدوات أو /tools — عرض هذه القائمة';

  /// Returns null for ordinary chat text. A leading slash is reserved for
  /// explicit local commands and unknown commands fail closed.
  static ParsedLocalToolCommand? parse(String input) {
    final normalized = input.trim();
    if (!normalized.startsWith('/')) return null;
    final match = RegExp(r'^/([a-zA-Z\u0600-\u06FF]+)(?:\s+([\s\S]*))?$')
        .firstMatch(normalized);
    if (match == null) {
      throw const FormatException('صيغة الأمر المحلي غير صحيحة.');
    }
    final command = match.group(1)!.toLowerCase();
    final argument = (match.group(2) ?? '').trim();
    switch (command) {
      case 'tools':
      case 'ادوات':
      case 'أدوات':
      case 'الأدوات':
        if (argument.isNotEmpty) {
          throw const FormatException('استخدم /الأدوات دون مدخلات.');
        }
        return const ParsedLocalToolCommand.help();
      case 'calc':
      case 'احسب':
      case 'حساب':
        if (argument.isEmpty) {
          throw const FormatException('اكتب التعبير بعد /احسب.');
        }
        return ParsedLocalToolCommand.tool(
          toolName: 'calculator',
          arguments: {'expression': argument},
        );
      case 'time':
      case 'وقت':
      case 'الوقت':
        if (argument.isNotEmpty) {
          throw const FormatException('استخدم /وقت دون مدخلات.');
        }
        return const ParsedLocalToolCommand.tool(
          toolName: 'local_datetime',
          arguments: {},
        );
      case 'stats':
      case 'احصاء':
      case 'إحصاء':
      case 'احصائيات':
      case 'إحصائيات':
        if (argument.isEmpty) {
          throw const FormatException('اكتب النص بعد /إحصاء.');
        }
        return ParsedLocalToolCommand.tool(
          toolName: 'text_stats',
          arguments: {'text': argument},
        );
      default:
        throw FormatException('الأمر /$command غير معروف. استخدم /الأدوات.');
    }
  }
}
