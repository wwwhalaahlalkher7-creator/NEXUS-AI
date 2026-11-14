import 'package:sqflite/sqflite.dart';

import '../../data/local_database.dart';
import 'knowledge_chunker.dart';
import 'knowledge_document.dart';
import 'knowledge_retriever.dart';
import '../resources/resource_settings.dart';

class KnowledgeRepository {
  KnowledgeRepository({
    LocalDatabase? database,
    ResourceSettingsRepository? settingsRepository,
    DeviceResourceMonitor? resourceMonitor,
  })  : _localDatabase = database ?? LocalDatabase.instance,
        _settingsRepository = settingsRepository ?? ResourceSettingsRepository(),
        _resourceMonitor = resourceMonitor ?? const DeviceResourceMonitor();

  final LocalDatabase _localDatabase;
  final ResourceSettingsRepository _settingsRepository;
  final DeviceResourceMonitor _resourceMonitor;

  Future<KnowledgeDocument> importText({
    required String fileName,
    required String title,
    required String text,
  }) async {
    final extension = fileName.split('.').last.toLowerCase();
    if (extension != 'txt' && extension != 'md' && extension != 'markdown') {
      throw ArgumentError('Only TXT and Markdown documents are supported.');
    }
    final sourceType = extension == 'txt' ? 'txt' : 'md';
    final normalizedText = KnowledgeChunker.normalizeText(text);
    final chunks = KnowledgeChunker.chunk(normalizedText);
    final contentHash = _fingerprint(normalizedText);
    final normalizedTitle = _normalizeTitle(title, fileName);
    final normalizedFileName = fileName
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalizedFileName.isEmpty || normalizedFileName.length > 255) {
      throw ArgumentError('The selected file name is invalid.');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final id =
        'knowledge-${DateTime.now().microsecondsSinceEpoch}-$contentHash';
    final document = KnowledgeDocument(
      id: id,
      title: normalizedTitle,
      fileName: normalizedFileName,
      sourceType: sourceType,
      charCount: normalizedText.runes.length,
      chunkCount: chunks.length,
      importedAtUnixMs: now,
    );

    final db = await _localDatabase.database;
    await db.transaction((txn) async {
      final duplicate = await txn.query(
        'knowledge_documents',
        columns: ['id'],
        where: 'content_hash = ?',
        whereArgs: [contentHash],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        throw StateError('هذه الوثيقة موجودة بالفعل في المكتبة.');
      }
      await txn.insert(
        'knowledge_documents',
        {
          'id': document.id,
          'title': document.title,
          'file_name': document.fileName,
          'source_type': document.sourceType,
          'content_hash': contentHash,
          'char_count': document.charCount,
          'chunk_count': document.chunkCount,
          'imported_at_unix_ms': document.importedAtUnixMs,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      for (final chunk in chunks) {
        await txn.insert(
          'knowledge_chunks',
          {
            'id': '$id-chunk-${chunk.ordinal}',
            'document_id': id,
            'ordinal': chunk.ordinal,
            'content': chunk.content,
            'normalized_content': chunk.normalizedContent,
            'token_count': chunk.tokenCount,
            'char_count': chunk.content.runes.length,
          },
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
    });
    return document;
  }

  Future<List<KnowledgeDocument>> listDocuments() async {
    final db = await _localDatabase.database;
    final rows = await db.query(
      'knowledge_documents',
      orderBy: 'imported_at_unix_ms DESC, id DESC',
    );
    return rows.map(KnowledgeDocument.fromMap).toList(growable: false);
  }

  Future<void> deleteDocument(String documentId) async {
    final db = await _localDatabase.database;
    final removed = await db.delete(
      'knowledge_documents',
      where: 'id = ?',
      whereArgs: [documentId],
    );
    if (removed != 1) {
      throw StateError('The knowledge document no longer exists.');
    }
  }

  Future<List<KnowledgeSearchHit>> search(
    String query, {
    ResourceSettings? settings,
    ResourceSnapshot? resourceSnapshot,
  }) async {
    final activeSettings = settings ?? await _settingsRepository.load();
    final snapshot = resourceSnapshot ??
        (activeSettings.mode == ResourceMode.unrestricted
            ? null
            : await _resourceMonitor.readSnapshot());
    final resultLimit = activeSettings.retrievalResultLimit;
    final candidateLimit = activeSettings.searchCandidateBudget(snapshot);
    final maxPerDocument = activeSettings.maxResultsPerDocument;
    final terms = KnowledgeChunker.normalizeForSearch(query)
        .split(' ')
        .where((term) => term.length >= 2)
        .toSet()
        // Each term appears twice in this query. Keep below SQLite's
        // traditional 999 bind-variable limit for portable builds.
        .take(128)
        .toList(growable: false);
    if (terms.isEmpty) {
      return const [];
    }

    final whereClause = List.filled(
      terms.length,
      'c.normalized_content LIKE ?',
    ).join(' OR ');
    final rankingClause = List.filled(
      terms.length,
      'CASE WHEN c.normalized_content LIKE ? THEN 1 ELSE 0 END',
    ).join(' + ');
    final searchArgs = terms.map((term) => '% $term %').toList();
    final db = await _localDatabase.database;
    final limitClause = candidateLimit == null ? '' : 'LIMIT $candidateLimit';
    final rows = await db.rawQuery('''
      SELECT
        c.document_id,
        c.ordinal,
        c.content,
        c.normalized_content,
        c.token_count,
        d.title,
        d.file_name
      FROM knowledge_chunks AS c
      INNER JOIN knowledge_documents AS d ON d.id = c.document_id
      WHERE $whereClause
      ORDER BY ($rankingClause) DESC,
        d.imported_at_unix_ms DESC,
        c.ordinal ASC
      $limitClause
    ''', [...searchArgs, ...searchArgs]);

    final candidates = rows.map((row) => KnowledgeCandidate(
          documentId: row['document_id']! as String,
          title: row['title']! as String,
          fileName: row['file_name']! as String,
          chunkOrdinal: row['ordinal']! as int,
          content: row['content']! as String,
          normalizedContent: row['normalized_content']! as String,
          tokenCount: row['token_count']! as int,
        )).toList(growable: false);
    return KnowledgeRetriever.rank(
      query,
      candidates,
      limit: resultLimit,
      maxPerDocument: maxPerDocument,
    );
  }

  static String _normalizeTitle(String title, String fileName) {
    final fallback = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final normalized = (title.trim().isEmpty ? fallback : title.trim())
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) {
      return 'وثيقة بدون عنوان';
    }
    return normalized.runes.length > 80
        ? String.fromCharCodes(normalized.runes.take(80))
        : normalized;
  }

  static String _fingerprint(String value) {
    // Two small 32-bit rolling hashes identify duplicates.
    // Neither is a cryptographic integrity primitive.
    var first = 0x811c9dc5;
    var second = 0x9E3779B9;
    for (final unit in value.codeUnits) {
      first = ((first ^ unit) * 0x01000193) & 0xFFFFFFFF;
      second = ((second ^ (unit + 0x9E37)) * 0x85EBCA6B) & 0xFFFFFFFF;
    }
    return '${first.toRadixString(16).padLeft(8, '0')}'
        '${second.toRadixString(16).padLeft(8, '0')}';
  }
}
