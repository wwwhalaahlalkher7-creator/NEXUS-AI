import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/tools/local_tool_command_parser.dart';

void main() {
  test('ordinary chat text is not treated as a local tool command', () {
    expect(LocalToolCommandParser.parse('اشرح لي المعادلة'), isNull);
  });

  test('parses calculator command with spaces and nested expressions', () {
    final command = LocalToolCommandParser.parse('/calc 12 * (3 + 2)')!;

    expect(command.showHelp, isFalse);
    expect(command.toolName, 'calculator');
    expect(command.arguments['expression'], '12 * (3 + 2)');
  });

  test('parses Arabic aliases and tool help commands', () {
    final calculator = LocalToolCommandParser.parse('/احسب ١ + ٢')!;
    expect(calculator.toolName, 'calculator');
    expect(calculator.arguments['expression'], '١ + ٢');
    expect(LocalToolCommandParser.parse('/وقت')!.toolName, 'local_datetime');
    expect(
      LocalToolCommandParser.parse('/إحصاء مرحبا')!.toolName,
      'text_stats',
    );
    expect(LocalToolCommandParser.parse('/الأدوات')!.showHelp, isTrue);
  });

  test('parses time, text statistics and tool help commands', () {
    expect(
      LocalToolCommandParser.parse('/time')!.toolName,
      'local_datetime',
    );
    expect(
      LocalToolCommandParser.parse('/stats مرحبا بالعالم')!
          .arguments['text'],
      'مرحبا بالعالم',
    );
    expect(LocalToolCommandParser.parse('/tools')!.showHelp, isTrue);
  });

  test('unknown and malformed slash commands fail closed', () {
    expect(
      () => LocalToolCommandParser.parse('/shell rm -rf'),
      throwsFormatException,
    );
    expect(
      () => LocalToolCommandParser.parse('/calc'),
      throwsFormatException,
    );
    expect(
      () => LocalToolCommandParser.parse('/time extra'),
      throwsFormatException,
    );
  });
}
