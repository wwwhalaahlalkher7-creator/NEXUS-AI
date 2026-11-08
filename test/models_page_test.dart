import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/models/model_repository.dart';
import 'package:nexus_app/src/features/models/models_page.dart';

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
    expect(find.textContaining('غير مثبت'), findsOneWidget);
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
}
