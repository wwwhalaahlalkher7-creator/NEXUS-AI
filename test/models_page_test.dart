import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/models/model_repository.dart';
import 'package:nexus_app/src/features/models/models_page.dart';
import 'package:nexus_app/src/features/models/model_import_service.dart';
import 'package:nexus_app/src/features/models/model_file_verifier.dart';
import 'package:nexus_app/src/features/models/rust_gguf_inspector.dart';

class _FakeModelImportService implements ModelImportService {
  @override
  Future<ImportedModelFile?> importGguf(ModelRecord model) async {
    return const ImportedModelFile(
      path: '/app/models/test.gguf',
      sizeBytes: 4096,
      inspection: GgufInspection(
        validHeader: true,
        fileName: 'test.gguf',
        sizeBytes: 4096,
        formatVersion: 3,
        tensorCount: 12,
        metadataCount: 7,
        architecture: 'llama',
        modelName: 'Test GGUF model',
        contextLength: 4096,
        blockCount: 32,
        message: 'metadata checked',
      ),
    );
  }
}


class _FakeModelFileVerifier implements ModelFileVerifier {
  const _FakeModelFileVerifier(this.result);

  final ModelFileVerification result;

  @override
  Future<ModelFileVerification> verify(ModelRecord model) async => result;
}

class _FakeModelStore implements ModelStore {
  final Map<String, ModelRecord> records = {};

  @override
  Future<void> register(ModelRecord model) async {
    if (records.containsKey(model.id)) {
      throw StateError('duplicate model id');
    }
    records[model.id] = model;
  }

  @override
  Future<List<ModelRecord>> list() async {
    return records.values.toList();
  }

  @override
  Future<void> updateInstallState(
    String id, {
    required ModelInstallStatus status,
    String? localPath,
    int? sizeBytes,
    String? architecture,
    String? ggufModelName,
    String? tokenizerModel,
    int? contextLength,
    int? blockCount,
    int? embeddingLength,
    int? fileType,
    int? parameterCount,
  }) async {
    final current = records[id]!;
    records[id] = ModelRecord(
      id: current.id,
      displayName: current.displayName,
      runtime: current.runtime,
      status: status,
      localPath: localPath,
      sizeBytes: sizeBytes,
      architecture: architecture,
      ggufModelName: ggufModelName,
      tokenizerModel: tokenizerModel,
      contextLength: contextLength,
      blockCount: blockCount,
      embeddingLength: embeddingLength,
      fileType: fileType,
      parameterCount: parameterCount,
      createdAtUnixMs: current.createdAtUnixMs,
      updatedAtUnixMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> delete(String id) async {
    records.remove(id);
  }

}

void main() {
  testWidgets('adds a model as registered metadata', (tester) async {
    final store = _FakeModelStore();
    await tester.pumpWidget(
      MaterialApp(home: ModelsPage(store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('مكتبة النماذج فارغة'), findsOneWidget);
    await tester.tap(find.text('إضافة أول نموذج'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'Qwen 2.5 3B');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(store.records, hasLength(1));
    expect(store.records.values.single.status, ModelInstallStatus.registered);
    expect(find.text('Qwen 2.5 3B'), findsOneWidget);
    expect(find.textContaining('مُسجّل فقط'), findsOneWidget);
  });

  testWidgets('deletes only the local catalog record after confirmation',
      (tester) async {
    final store = _FakeModelStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    final model = ModelRecord(
      id: 'model-test',
      displayName: 'Test model',
      runtime: ModelRuntime.llamaCpp,
      status: ModelInstallStatus.registered,
      createdAtUnixMs: now,
      updatedAtUnixMs: now,
    );
    await store.register(model);

    await tester.pumpWidget(
      MaterialApp(home: ModelsPage(store: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('حذف السجل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف السجل'));
    await tester.pumpAndSettle();

    expect(store.records, isEmpty);
    expect(find.text('مكتبة النماذج فارغة'), findsOneWidget);
  });

  testWidgets('imports a GGUF file and updates the local model state', (tester) async {
    final store = _FakeModelStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.register(ModelRecord(
      id: 'model-gguf',
      displayName: 'Small GGUF',
      runtime: ModelRuntime.llamaCpp,
      status: ModelInstallStatus.registered,
      createdAtUnixMs: now,
      updatedAtUnixMs: now,
    ));

    await tester.pumpWidget(MaterialApp(
      home: ModelsPage(
        store: store,
        importService: _FakeModelImportService(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('اختيار ملف GGUF'), findsOneWidget);
    await tester.tap(find.text('اختيار ملف GGUF'));
    await tester.pumpAndSettle();

    expect(store.records['model-gguf']!.status, ModelInstallStatus.installed);
    expect(store.records['model-gguf']!.localPath, '/app/models/test.gguf');
    expect(store.records['model-gguf']!.architecture, 'llama');
    expect(store.records['model-gguf']!.contextLength, 4096);
    expect(store.records['model-gguf']!.blockCount, 32);
    expect(find.textContaining('المعمارية: llama'), findsOneWidget);
    expect(find.textContaining('السياق: 4.1K'), findsOneWidget);
    expect(find.textContaining('ملف GGUF موجود، غير محمّل'), findsOneWidget);
    expect(find.textContaining('4.0 KB'), findsOneWidget);
  });


  testWidgets('runs a local model file verification and reports its limits', (tester) async {
    final store = _FakeModelStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.register(ModelRecord(
      id: 'model-verified',
      displayName: 'Verified model',
      runtime: ModelRuntime.llamaCpp,
      status: ModelInstallStatus.installed,
      localPath: '/app/models/verified.gguf',
      sizeBytes: 4096,
      createdAtUnixMs: now,
      updatedAtUnixMs: now,
    ));

    await tester.pumpWidget(MaterialApp(
      home: ModelsPage(
        store: store,
        fileVerifier: const _FakeModelFileVerifier(
          ModelFileVerification(
            isValid: true,
            actualSizeBytes: 4096,
            message: 'الملف اجتاز الفحص المحدود؛ لم يتم اختبار تشغيل النموذج.',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('فحص سلامة الملف'));
    await tester.pumpAndSettle();

    expect(
      find.text('الملف اجتاز الفحص المحدود؛ لم يتم اختبار تشغيل النموذج.'),
      findsOneWidget,
    );
  });

}
