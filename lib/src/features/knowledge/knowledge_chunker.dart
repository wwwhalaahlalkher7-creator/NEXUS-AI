import 'knowledge_document.dart';

/// Bounded, overlap-aware text chunking for the offline knowledge index.
class KnowledgeChunker {
  const KnowledgeChunker._();

  static const chunkSize = 1200;
  static const overlapSize = 160;

  static String normalizeText(String value, {int? maxCharacters}) {
    final cleaned = value
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{4,}'), '\n\n\n')
        .trim();
    final characterCount = cleaned.runes.length;
    if (characterCount == 0) {
      throw ArgumentError('The selected document contains no readable text.');
    }
    if (maxCharacters != null && characterCount > maxCharacters) {
      throw ArgumentError('The document exceeds the current memory budget.');
    }
    return cleaned;
  }

  static String normalizeForSearch(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if ((rune >= 0x064B && rune <= 0x065F) ||
          rune == 0x0670 ||
          rune == 0x0640) {
        continue;
      }
      var normalized = rune;
      if (rune == 0x0622 || rune == 0x0623 || rune == 0x0625) {
        normalized = 0x0627;
      } else if (rune == 0x0649) {
        normalized = 0x064A;
      } else if (rune >= 0x0660 && rune <= 0x0669) {
        normalized = 0x30 + rune - 0x0660;
      } else if (rune >= 0x06F0 && rune <= 0x06F9) {
        normalized = 0x30 + rune - 0x06F0;
      }
      buffer.writeCharCode(normalized);
    }
    final lowered = buffer.toString().toLowerCase();
    return _tokenPattern
        .allMatches(lowered)
        .map((match) => match.group(0)!)
        .join(' ');
  }

  static final RegExp _tokenPattern = RegExp(
    r'[a-z0-9\u0621-\u063A\u0641-\u064A\u066E-\u06D3\u06FA-\u06FC\u06FF\u0750-\u077F\u08A0-\u08C9]+',
  );

  static List<KnowledgeChunk> chunk(
    String rawText, {
    int? maxCharacters,
  }) {
    final text = normalizeText(rawText, maxCharacters: maxCharacters);
    final runes = text.runes.toList(growable: false);
    final chunks = <KnowledgeChunk>[];
    var start = 0;

    while (start < runes.length) {
      var end = (start + chunkSize).clamp(0, runes.length).toInt();
      if (end < runes.length) {
        final boundary = _findBoundary(
          runes,
          start + (chunkSize * 0.65).round(),
          end,
        );
        if (boundary > start) {
          end = boundary + 1;
        }
      }
      final content = String.fromCharCodes(runes.sublist(start, end)).trim();
      if (content.isNotEmpty) {
        final normalized = normalizeForSearch(content);
        final tokenCount = normalized.isEmpty
            ? 0
            : normalized.split(' ').length;
        if (tokenCount > 0) {
          chunks.add(KnowledgeChunk(
            ordinal: chunks.length,
            content: content,
            normalizedContent: ' $normalized ',
            tokenCount: tokenCount,
          ));
        }
      }
      if (end >= runes.length) {
        break;
      }
      final nextStart = end - overlapSize;
      start = nextStart > start ? nextStart : end;
    }

    if (chunks.isEmpty) {
      throw ArgumentError('The document contains no searchable text.');
    }
    return List<KnowledgeChunk>.unmodifiable(chunks);
  }

  static int _findBoundary(List<int> runes, int lower, int upper) {
    final safeLower = lower.clamp(0, upper).toInt();
    for (var index = upper - 1; index >= safeLower; index--) {
      final rune = runes[index];
      if (rune == 0x0A ||
          rune == 0x2E ||
          rune == 0x21 ||
          rune == 0x3F ||
          rune == 0x061F ||
          rune == 0x061B ||
          rune == 0x3002) {
        return index;
      }
    }
    return upper - 1;
  }
}
