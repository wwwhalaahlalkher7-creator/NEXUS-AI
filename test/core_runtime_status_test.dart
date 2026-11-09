import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_status.dart';

void main() {
  test('parses the Rust runtime diagnostics payload', () {
    final status = CoreRuntimeStatus.fromJson({
      'core_name': 'NEXUS AI',
      'core_version': '0.8.0',
      'stage': 'alpha-0.8-gguf-metadata-inspection',
      'bridge_connected': true,
      'runtime_engine': 'not_attached',
      'inference_available': false,
      'model_registry': 'flutter_sqlite',
      'agent_registry': 'rust_in_memory',
    });

    expect(status.bridgeConnected, isTrue);
    expect(status.inferenceAvailable, isFalse);
    expect(status.runtimeEngine, 'not_attached');
  });

  test('unavailable status never reports an active inference engine', () {
    final status = CoreRuntimeStatus.unavailable('not supported');
    expect(status.bridgeConnected, isFalse);
    expect(status.inferenceAvailable, isFalse);
    expect(status.message, 'not supported');
  });
}
