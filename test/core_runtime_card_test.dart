import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_card.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_service.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_status.dart';

class _FakeRuntimeService implements CoreRuntimeService {
  const _FakeRuntimeService();

  @override
  Future<CoreRuntimeStatus> inspect() async => const CoreRuntimeStatus(
        coreName: 'NEXUS AI',
        coreVersion: '0.9.0',
        stage: 'alpha-1.4-llama-native-foundation',
        bridgeConnected: true,
        runtimeEngine: 'llama.cpp-native-unavailable',
        inferenceAvailable: false,
        modelRegistry: 'flutter_sqlite',
        agentRegistry: 'rust_in_memory',
        nativeEngineAvailable: false,
        nativeEngineVersion: null,
        nativeEngineMessage: 'المحرك الأصلي غير متاح في بيئة الاختبار.',
      );
}

void main() {
  testWidgets('shows bridge connectivity without claiming inference', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CoreRuntimeCard(service: _FakeRuntimeService()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('نواة Rust متصلة'), findsOneWidget);
    expect(
      find.text('المحرك الأصلي غير متاح في بيئة الاختبار.'),
      findsOneWidget,
    );
  });
}
