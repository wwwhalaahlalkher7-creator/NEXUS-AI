import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/knowledge/knowledge_chunker.dart';

void main() {
  group('KnowledgeChunker', () {
    test('normalizes Arabic diacritics and numeral variants', () {
      final normalized = KnowledgeChunker.normalizeForSearch(
        'إِنَّ النَّموذج ١٢٣ يعمل بالذّكاء الاصطناعي',
      );

      expect(normalized, 'ان النموذج 123 يعمل بالذكاء الاصطناعي');
    });

    test('splits long text into bounded overlapping chunks', () {
      final source = List.filled(2200, 'معلومة هندسية مهمة').join(' ');
      final chunks = KnowledgeChunker.chunk(source);

      expect(chunks.length, greaterThan(1));
      expect(chunks.first.ordinal, 0);
      expect(chunks.last.ordinal, chunks.length - 1);
      expect(chunks.every((chunk) => chunk.content.isNotEmpty), isTrue);
      expect(
        chunks.every((chunk) => chunk.normalizedContent.startsWith(' ') &&
            chunk.normalizedContent.endsWith(' ')),
        isTrue,
      );
      expect(chunks.first.content.length, lessThanOrEqualTo(1200));
    });

    test('rejects empty text but does not impose a fixed document ceiling', () {
      expect(() => KnowledgeChunker.chunk('  \n  '), throwsArgumentError);
      final largeDocument = List.filled(400000, 'x').join();
      final chunks = KnowledgeChunker.chunk(largeDocument);
      expect(chunks.length, greaterThan(256));
      expect(chunks.first.ordinal, 0);
      expect(chunks.last.ordinal, chunks.length - 1);
    });

    test('preserves multi-byte characters at chunk boundaries', () {
      final source = List.filled(1400, 'معلومة 🧠').join(' ');
      final chunks = KnowledgeChunker.chunk(source);

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.content.runes.isNotEmpty), isTrue);
      expect(
        chunks.map((chunk) => chunk.content).join().contains('�'),
        isFalse,
      );
    });
  });
}
