import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/dashboard/dashboard_page.dart';
import 'package:nexus_app/src/features/models/model_file_verifier.dart';
import 'package:nexus_app/src/features/models/model_record.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_service.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_status.dart';
import 'package:nexus_app/src/features/runtime/model_runtime_manager.dart';

class _FakeCoreRuntimeService implements CoreRuntimeService {
  const _FakeCoreRuntimeService();

  @override
  Future<CoreRuntimeStatus> inspect() async => const CoreRuntimeStatus(
        coreName: 'NEXUS AI',
        coreVersion: '1.9.5',
        stage: 'alpha-1.9-multi-turn-context',
        bridgeConnected: true,
        runtimeEngine: 'llama.cpp-native-unavailable',
        inferenceAvailable: false,
        modelLoaded: false,
        modelRegistry: 'flutter_sqlite',
        agentRegistry: 'rust_in_memory',
        nativeEngineAvailable: false,
        nativeEngineVersion: null,
        nativeEngineMessage: 'اختبار الواجهة',
      );
}

class _FakeVerifier implements ModelFileVerifier {
  @override
  Future<ModelFileVerification> verify(ModelRecord model) async =>
      const ModelFileVerification(
        isValid: true,
        actualSizeBytes: 1024,
        message: 'valid',
      );
}

class _FakeBackend implements ModelRuntimeBackend {
  @override
  bool get isAvailable => true;

  @override
  Future<int> load(
    ModelRecord model, {
    required int contextTokens,
    required int threads,
  }) async => contextTokens;

  @override
  Future<void> unload() async {}
}

ModelRecord _model() => ModelRecord(
      id: 'dashboard-model',
      displayName: 'نموذج لوحة المعلومات',
      runtime: ModelRuntime.llamaCpp,
      status: ModelInstallStatus.installed,
      localPath: '/models/dashboard.gguf',
      sizeBytes: 1024,
      contextLength: 2048,
      createdAtUnixMs: 1,
      updatedAtUnixMs: 1,
    );

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'dashboard reflects shared model load and unload transitions',
    (tester) async {
      final manager = ModelRuntimeManager(
        verifier: _FakeVerifier(),
        backend: _FakeBackend(),
      );
      addTearDown(manager.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardPage(
            runtimeService: const _FakeCoreRuntimeService(),
            runtimeManager: manager,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final unloadedLabel = find.text('لا يوجد نموذج محمّل');
      await _reveal(tester, unloadedLabel);
      expect(unloadedLabel, findsOneWidget);

      final model = _model();
      await manager.prepare(model);
      await manager.loadPrepared(model);
      await tester.pumpAndSettle();

      final loadedLabel = find.text('نموذج محمّل فعلياً على CPU');
      await _reveal(tester, loadedLabel);
      expect(loadedLabel, findsOneWidget);
      expect(
        find.text('السياق: 2048 رمز · افتح المحادثة لتجربة التوليد المحلي.'),
        findsOneWidget,
      );

      await manager.unload();
      await tester.pumpAndSettle();
      await _reveal(tester, unloadedLabel);
      expect(unloadedLabel, findsOneWidget);
    },
  );
}
