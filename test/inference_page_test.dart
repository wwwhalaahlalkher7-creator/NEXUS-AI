import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/inference/inference_page.dart';
import 'package:nexus_app/src/features/models/model_file_verifier.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/runtime/model_runtime_manager.dart';

class _UnusedVerifier implements ModelFileVerifier {
  @override
  Future<ModelFileVerification> verify(ModelRecord model) async =>
      const ModelFileVerification(isValid: false, message: 'unused');
}

class _UnusedBackend implements ModelRuntimeBackend {
  @override
  bool get isAvailable => false;

  @override
  Future<int> load(
    ModelRecord model, {
    required int contextTokens,
    required int threads,
  }) =>
      Future<int>.error(UnsupportedError('unused'));

  @override
  Future<void> unload() => Future<void>.error(UnsupportedError('unused'));
}

void main() {
  testWidgets(
    'explains the Android ARM64 native inference boundary on host',
    (tester) async {
      final manager = ModelRuntimeManager(
        verifier: _UnusedVerifier(),
        backend: _UnusedBackend(),
      );
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InferencePage(runtimeManager: manager)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ابدأ محادثة محلية'), findsOneWidget);
      expect(
        find.text('حمّل نموذج GGUF من صفحة النماذج للبدء'),
        findsOneWidget,
      );
      expect(
        find.text(
          'واجهة التوليد الأصلية مفعّلة في هذه المرحلة لأجهزة Android ARM64 فقط.',
        ),
        findsOneWidget,
      );
    },
  );
}
