class KnowledgeDocument {
  const KnowledgeDocument({
    required this.id,
    required this.title,
    required this.fileName,
    required this.sourceType,
    required this.charCount,
    required this.chunkCount,
    required this.importedAtUnixMs,
  });

  final String id;
  final String title;
  final String fileName;
  final String sourceType;
  final int charCount;
  final int chunkCount;
  final int importedAtUnixMs;

  factory KnowledgeDocument.fromMap(Map<String, Object?> map) {
    return KnowledgeDocument(
      id: map['id']! as String,
      title: map['title']! as String,
      fileName: map['file_name']! as String,
      sourceType: map['source_type']! as String,
      charCount: map['char_count']! as int,
      chunkCount: map['chunk_count']! as int,
      importedAtUnixMs: map['imported_at_unix_ms']! as int,
    );
  }
}

class KnowledgeChunk {
  const KnowledgeChunk({
    required this.ordinal,
    required this.content,
    required this.normalizedContent,
    required this.tokenCount,
  });

  final int ordinal;
  final String content;
  final String normalizedContent;
  final int tokenCount;
}

class KnowledgeSearchHit {
  const KnowledgeSearchHit({
    required this.documentId,
    required this.title,
    required this.fileName,
    required this.chunkOrdinal,
    required this.content,
    required this.score,
    required this.referenceNumber,
  });

  final String documentId;
  final String title;
  final String fileName;
  final int chunkOrdinal;
  final String content;
  final double score;
  final int referenceNumber;

  KnowledgeSearchHit withReferenceNumber(int value) {
    return KnowledgeSearchHit(
      documentId: documentId,
      title: title,
      fileName: fileName,
      chunkOrdinal: chunkOrdinal,
      content: content,
      score: score,
      referenceNumber: value,
    );
  }
}
