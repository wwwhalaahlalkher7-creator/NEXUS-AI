import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/runtime/core_runtime_status.dart';

void main() {
  test('parses the Rust runtime diagnostics payload', () {
    final status = CoreRuntimeStatus.fromJson({
      'core_name': 'NEXUS AI',
      'core_version': '0.9.0',
      'stage': 'alpha-1.4-llama-native-foundation',
      'bridge_connected': true,
      'runtime_engine': 'llama.cpp-native-initialized',
      'inference_available': false,
      'model_registry': 'flutter_sqlite',
      'agent_registry': 'rust_in_memory',
      'native_engine_available': true,
      'native_engine_version': '0.9.0',
      'native_engine_message': 'native initialized',
      'model_loaded': false,
    });

    expect(status.bridgeConnected, isTrue);
    expect(status.inferenceAvailable, isFalse);
    expect(status.runtimeEngine, 'llama.cpp-native-initialized');
    expect(status.nativeEngineAvailable, isTrue);
    expect(status.nativeEngineVersion, '0.9.0');
  });

  test('unavailable status never reports an active inference engine', () {
    final status = CoreRuntimeStatus.unavailable('not supported');
    expect(status.bridgeConnected, isFalse);
    expect(status.inferenceAvailable, isFalse);
    expect(status.message, 'not supported');
  });
}
