import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_card.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_service.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_status.dart';

class _FakeRuntimeService implements CoreRuntimeService {
  const _FakeRuntimeService();

  @override
  Future<MemoryLifecycleResult> clearContextMemory() async =>
      const MemoryLifecycleResult(success: false, message: 'unavailable');

  @override
  Future<CoreRuntimeStatus> inspect() async => const CoreRuntimeStatus(
        coreName: 'NEXUS AI',
        coreVersion: '0.9.0',
        stage: 'alpha-2.7.6-explainable-placement',
        bridgeConnected: true,
        runtimeEngine: 'llama.cpp-native-unavailable',
        inferenceAvailable: false,
        modelLoaded: false,
        modelRegistry: 'flutter_sqlite',
        agentRegistry: 'rust_in_memory',
        nativeEngineAvailable: false,
        nativeEngineVersion: null,
        nativeEngineMessage: 'المحرك الأصلي غير متاح في بيئة الاختبار.',
      );
}

class _LoadedRuntimeService implements CoreRuntimeService {
  int clearCalls = 0;

  @override
  Future<MemoryLifecycleResult> clearContextMemory() async {
    clearCalls++;
    return const MemoryLifecycleResult(
      success: true,
      message: 'تم تفريغ KV Cache المؤقت.',
    );
  }

  @override
  Future<CoreRuntimeStatus> inspect() async => const CoreRuntimeStatus(
        coreName: 'NEXUS AI',
        coreVersion: '1.7.0',
        stage: 'alpha-2.7.6-explainable-placement',
        bridgeConnected: true,
        runtimeEngine: 'llama.cpp-native-initialized',
        inferenceAvailable: false,
        modelLoaded: true,
        modelRegistry: 'flutter_sqlite',
        agentRegistry: 'rust_in_memory',
        nativeEngineAvailable: true,
        nativeEngineVersion: '0.9.0',
        nativeEngineMessage: 'loaded',
        modelContextTokens: 2048,
        nativeMemoryAvailable: true,
        nativeMemoryReadable: true,
        nativeContextLoaded: true,
        nativeResidentBytes: 256 * 1024 * 1024,
        nativePeakResidentBytes: 320 * 1024 * 1024,
        nativeVirtualBytes: 512 * 1024 * 1024,
        nativeKvCacheClearCount: 7,
        nativeModelLoadCount: 2,
        nativeModelUnloadCount: 1,
      );
}

void main() {
  testWidgets(
    'shows bridge connectivity without claiming inference',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CoreRuntimeCard(service: _FakeRuntimeService()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('نواة Rust متصلة'), findsOneWidget);
      expect(find.text('غير محمل'), findsOneWidget);
      expect(
        find.text('المحرك الأصلي غير متاح في بيئة الاختبار.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'shows the actual CPU context only for a loaded model',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CoreRuntimeCard(service: _LoadedRuntimeService()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('محمل فعلياً'), findsOneWidget);
      expect(find.text('2048 رمز على CPU'), findsOneWidget);
      expect(
        find.text(
          'تم تحميل أوزان GGUF. افتح المحادثة لتجربة التوليد المحلي؛ لا يتأكد نجاح الاستدلال إلا بعد اكتمال أول استجابة.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('shows native memory metrics and clears only KV cache on confirmation', (tester) async {
    final service = _LoadedRuntimeService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CoreRuntimeCard(service: service)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ذاكرة العملية الحالية RSS'), findsOneWidget);
    expect(find.text('256.0 MiB'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);

    await tester.tap(find.text('تفريغ KV Cache المؤقت'));
    await tester.pumpAndSettle();
    expect(find.text('ستظل أوزان النموذج وسياق التشغيل محمّلين، وقد يُعاد بناء KV عند الطلب التالي. هل تريد المتابعة؟'), findsOneWidget);
    await tester.tap(find.text('تفريغ KV Cache').last);
    await tester.pumpAndSettle();

    expect(service.clearCalls, 1);
    expect(find.text('تم تفريغ KV Cache المؤقت.'), findsOneWidget);
  });
}
