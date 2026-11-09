import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_card.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_service.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_status.dart';

class _FakeRuntimeService implements CoreRuntimeService {
  const _FakeRuntimeService();

  @override
  Future<CoreRuntimeStatus> inspect() async => const CoreRuntimeStatus(
        coreName: 'NEXUS AI',
        coreVersion: '0.8.0',
        stage: 'alpha-0.8-gguf-metadata-inspection',
        bridgeConnected: true,
        runtimeEngine: 'not_attached',
        inferenceAvailable: false,
        modelRegistry: 'flutter_sqlite',
        agentRegistry: 'rust_in_memory',
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
      find.text('الاتصال ناجح، لكن لا يوجد محرك استدلال موصول أو نموذج نشط.'),
      findsOneWidget,
    );
  });
}
